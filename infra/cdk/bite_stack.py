"""
Stack unico con toda la infraestructura del experimento ASR Disponibilidad:
  ALB + ASG (EC2) + RDS PostgreSQL + S3 + CloudWatch Alarms + SNS
"""
from __future__ import annotations

from aws_cdk import (
    CfnOutput,
    Duration,
    RemovalPolicy,
    Stack,
    aws_autoscaling as asg_lib,
    aws_cloudwatch as cw,
    aws_cloudwatch_actions as cw_actions,
    aws_ec2 as ec2,
    aws_elasticloadbalancingv2 as elbv2,
    aws_iam as iam,  # solo from_role_arn
    aws_rds as rds,
    aws_s3 as s3,
    aws_sns as sns,
    aws_sns_subscriptions as subs,
)
from constructs import Construct


class BiteStack(Stack):
    def __init__(
        self,
        scope: Construct,
        construct_id: str,
        *,
        config: dict,
        **kwargs,
    ) -> None:
        super().__init__(scope, construct_id, **kwargs)

        subnet_ids: list[str] = config["subnet_ids"]
        azs: list[str] = config["availability_zones"]
        region: str = config["region"]

        # ── VPC importada (auto-descubierta en app.py) ─────────────────────
        vpc = ec2.Vpc.from_vpc_attributes(
            self, "Vpc",
            vpc_id=config["vpc_id"],
            availability_zones=azs,
            public_subnet_ids=subnet_ids,
        )

        # Subredes con AZ conocida para constructs que lo requieren
        subnets = [
            ec2.Subnet.from_subnet_attributes(
                self, f"Sub{i}",
                subnet_id=sid,
                availability_zone=az,
            )
            for i, (sid, az) in enumerate(zip(subnet_ids, azs))
        ]

        # ── Security Groups ────────────────────────────────────────────────
        alb_sg = ec2.SecurityGroup(
            self, "AlbSg", vpc=vpc,
            description="ALB - inbound HTTP desde internet",
            allow_all_outbound=True,
        )
        alb_sg.add_ingress_rule(ec2.Peer.any_ipv4(), ec2.Port.tcp(80))

        app_sg = ec2.SecurityGroup(
            self, "AppSg", vpc=vpc,
            description="EC2 - trafico desde ALB",
            allow_all_outbound=True,
        )
        app_sg.add_ingress_rule(alb_sg, ec2.Port.tcp(config["app_port"]))

        db_sg = ec2.SecurityGroup(
            self, "DbSg", vpc=vpc,
            description="RDS - trafico desde EC2",
            allow_all_outbound=False,
        )
        db_sg.add_ingress_rule(app_sg, ec2.Port.tcp(5432))

        # ── IAM Role para EC2 ──────────────────────────────────────────────
        # AWS Academy no permite crear roles IAM nuevos.
        # Se usa el LabRole pre-existente que tiene AdministratorAccess.
        ec2_role = iam.Role.from_role_arn(
            self, "LabRole",
            role_arn=f"arn:aws:iam::{config['account_id']}:role/LabRole",
            mutable=False,
        )

        # ── RDS PostgreSQL ─────────────────────────────────────────────────
        db_subnet_group = rds.SubnetGroup(
            self, "DbSubnetGroup",
            vpc=vpc,
            description="BITE RDS - subnets",
            vpc_subnets=ec2.SubnetSelection(subnets=subnets[:2]),
            removal_policy=RemovalPolicy.DESTROY,
        )

        db = rds.DatabaseInstance(
            self, "Db",
            engine=rds.DatabaseInstanceEngine.postgres(
                version=rds.PostgresEngineVersion.VER_15
            ),
            instance_type=ec2.InstanceType.of(
                ec2.InstanceClass.BURSTABLE3, ec2.InstanceSize.MICRO
            ),
            vpc=vpc,
            vpc_subnets=ec2.SubnetSelection(subnets=subnets[:2]),
            subnet_group=db_subnet_group,
            security_groups=[db_sg],
            database_name=config["db_name"],
            credentials=rds.Credentials.from_generated_secret(config["db_username"]),
            multi_az=False,
            allocated_storage=20,
            removal_policy=RemovalPolicy.DESTROY,
            deletion_protection=False,
            publicly_accessible=False,
        )

        assert db.secret is not None

        # ── S3 Bucket para reportes ────────────────────────────────────────
        # auto_delete_objects requiere Lambda/IAM — no disponible en Academy.
        bucket = s3.Bucket(
            self, "Reports",
            removal_policy=RemovalPolicy.DESTROY,
            lifecycle_rules=[
                s3.LifecycleRule(
                    expiration=Duration.days(config["s3_reports_expiry_days"])
                )
            ],
        )

        # ── User Data (bootstrap de la EC2 al arrancar) ────────────────────
        ud = ec2.UserData.for_linux()
        ud.add_commands(
            "set -e",
            "yum update -y",
            "yum install -y python3 python3-pip git jq",
            # Clonar repo
            f"git clone {config['github_repo']} /home/ec2-user/app",
            # Instalar dependencias Python
            "python3 -m venv /home/ec2-user/app/app/venv",
            "source /home/ec2-user/app/app/venv/bin/activate",
            "pip install --quiet -r /home/ec2-user/app/app/requirements.txt",
            # Obtener credenciales de DB desde Secrets Manager
            f"SECRET=$(aws secretsmanager get-secret-value "
            f"--secret-id {db.secret.secret_arn} "
            f"--region {region} --query SecretString --output text)",
            "DB_HOST=$(echo $SECRET | jq -r '.host')",
            "DB_PASS=$(echo $SECRET | jq -r '.password')",
            # Escribir .env
            "cat > /home/ec2-user/app/.env <<ENVEOF",
            "DB_HOST=$DB_HOST",
            f"DB_NAME={config['db_name']}",
            f"DB_USER={config['db_username']}",
            "DB_PASSWORD=$DB_PASS",
            f"JWT_SECRET={config['jwt_secret']}",
            f"S3_REPORTS_BUCKET={bucket.bucket_name}",
            f"AWS_REGION={region}",
            "SES_SENDER=noreply@example.com",
            "ENVEOF",
            # Servicio systemd
            "cat > /etc/systemd/system/bite-app.service <<'SVCEOF'",
            "[Unit]",
            "Description=BITE.co App",
            "After=network.target",
            "[Service]",
            "User=ec2-user",
            "WorkingDirectory=/home/ec2-user/app/app",
            "EnvironmentFile=/home/ec2-user/app/.env",
            f"ExecStart=/home/ec2-user/app/app/venv/bin/gunicorn "
            f"-w 4 -b 0.0.0.0:{config['app_port']} main:app",
            "Restart=always",
            "[Install]",
            "WantedBy=multi-user.target",
            "SVCEOF",
            "systemctl daemon-reload",
            "systemctl enable bite-app",
            "systemctl start bite-app",
        )

        # ── Launch Template ────────────────────────────────────────────────
        lt = ec2.LaunchTemplate(
            self, "LT",
            instance_type=ec2.InstanceType(config["instance_type"]),
            machine_image=ec2.MachineImage.latest_amazon_linux2023(),
            security_group=app_sg,
            user_data=ud,
            role=ec2_role,
        )

        # ── Application Load Balancer ──────────────────────────────────────
        alb = elbv2.ApplicationLoadBalancer(
            self, "Alb",
            vpc=vpc,
            internet_facing=True,
            security_group=alb_sg,
            vpc_subnets=ec2.SubnetSelection(subnets=subnets),
        )

        tg = elbv2.ApplicationTargetGroup(
            self, "Tg",
            vpc=vpc,
            port=config["app_port"],
            protocol=elbv2.ApplicationProtocol.HTTP,
            target_type=elbv2.TargetType.INSTANCE,
            health_check=elbv2.HealthCheck(
                path="/health",
                interval=Duration.seconds(config["health_check_interval_seconds"]),
                timeout=Duration.seconds(3),
                healthy_threshold_count=config["health_check_threshold"],
                unhealthy_threshold_count=config["health_check_threshold"],
                healthy_http_codes="200",
            ),
        )

        alb.add_listener("Http", port=80, default_target_groups=[tg])

        # ── Auto Scaling Group ─────────────────────────────────────────────
        asg = asg_lib.AutoScalingGroup(
            self, "Asg",
            vpc=vpc,
            launch_template=lt,
            min_capacity=config["min_instances"],
            max_capacity=config["max_instances"],
            desired_capacity=config["desired_instances"],
            health_check=asg_lib.HealthCheck.elb(grace=Duration.seconds(60)),
            vpc_subnets=ec2.SubnetSelection(subnets=subnets),
        )
        asg.attach_to_application_target_group(tg)

        # ── SNS + Alarmas CloudWatch ───────────────────────────────────────
        topic = sns.Topic(self, "Alarms", topic_name="bite-alarms")
        topic.add_subscription(subs.EmailSubscription(config["alarm_email"]))
        alarm_action = cw_actions.SnsAction(topic)

        cw.Alarm(
            self, "CpuAlarm",
            alarm_name="bite-high-cpu",
            metric=cw.Metric(
                namespace="AWS/EC2",
                metric_name="CPUUtilization",
                dimensions_map={"AutoScalingGroupName": asg.auto_scaling_group_name},
                period=Duration.seconds(60),
                statistic="Average",
            ),
            threshold=config["cpu_alarm_threshold"],
            evaluation_periods=2,
            comparison_operator=cw.ComparisonOperator.GREATER_THAN_THRESHOLD,
        ).add_alarm_action(alarm_action)

        cw.Alarm(
            self, "UnhealthyAlarm",
            alarm_name="bite-unhealthy-hosts",
            metric=tg.metric_unhealthy_host_count(period=Duration.seconds(10)),
            threshold=0,
            evaluation_periods=1,
            comparison_operator=cw.ComparisonOperator.GREATER_THAN_THRESHOLD,
        ).add_alarm_action(alarm_action)

        cw.Alarm(
            self, "Http5xxAlarm",
            alarm_name="bite-5xx-errors",
            metric=alb.metric_http_code_target(
                code=elbv2.HttpCodeTarget.TARGET_5XX_COUNT,
                period=Duration.seconds(60),
            ),
            threshold=config["http_5xx_alarm_threshold"],
            evaluation_periods=1,
            comparison_operator=cw.ComparisonOperator.GREATER_THAN_THRESHOLD,
            treat_missing_data=cw.TreatMissingData.NOT_BREACHING,
        ).add_alarm_action(alarm_action)

        # ── Outputs ────────────────────────────────────────────────────────
        CfnOutput(self, "AlbUrl",
                  value=f"http://{alb.load_balancer_dns_name}",
                  description="URL publica del ALB")
        CfnOutput(self, "ReportsBucket",
                  value=bucket.bucket_name,
                  description="Bucket S3 para reportes mensuales")
        CfnOutput(self, "DbSecretArn",
                  value=db.secret.secret_arn,
                  description="ARN del secreto de base de datos en Secrets Manager")
        CfnOutput(self, "AsgName",
                  value=asg.auto_scaling_group_name,
                  description="Nombre del Auto Scaling Group (para scripts de fallo)")
