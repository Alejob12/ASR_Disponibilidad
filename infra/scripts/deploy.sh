#!/bin/bash
# Despliega las tres stacks de CloudFormation en orden.
# Requiere: AWS CLI configurado con credenciales de AWS Academy.

set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
VPC_ID="${VPC_ID}"
SUBNET_IDS="${SUBNET_IDS}"      # "subnet-aaa,subnet-bbb"
AMI_ID="${AMI_ID}"
KEY_NAME="${KEY_NAME}"
DB_PASSWORD="${DB_PASSWORD}"
ALARM_EMAIL="${ALARM_EMAIL}"

echo "=== 1/3 Desplegando EC2 + ASG + ALB ==="
aws cloudformation deploy \
  --template-file infra/cloudformation/ec2_asg_alb.yaml \
  --stack-name bite-ec2-asg-alb \
  --capabilities CAPABILITY_IAM \
  --region "$REGION" \
  --parameter-overrides \
    VpcId="$VPC_ID" \
    SubnetIds="$SUBNET_IDS" \
    AMIId="$AMI_ID" \
    KeyName="$KEY_NAME"

ALB_DNS=$(aws cloudformation describe-stacks \
  --stack-name bite-ec2-asg-alb \
  --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='ALBDNSName'].OutputValue" \
  --output text)

EC2_SG=$(aws cloudformation describe-stack-resources \
  --stack-name bite-ec2-asg-alb \
  --region "$REGION" \
  --query "StackResources[?LogicalResourceId=='EC2SecurityGroup'].PhysicalResourceId" \
  --output text)

echo "ALB DNS: $ALB_DNS"

echo "=== 2/3 Desplegando RDS ==="
aws cloudformation deploy \
  --template-file infra/cloudformation/rds.yaml \
  --stack-name bite-rds \
  --region "$REGION" \
  --parameter-overrides \
    VpcId="$VPC_ID" \
    SubnetIds="$SUBNET_IDS" \
    EC2SecurityGroupId="$EC2_SG" \
    DBPassword="$DB_PASSWORD"

echo "=== 3/3 Desplegando S3 + CloudWatch ==="
# Obtener nombres completos de ALB y TG para las metricas
ALB_ARN=$(aws elbv2 describe-load-balancers \
  --names bite-alb \
  --region "$REGION" \
  --query "LoadBalancers[0].LoadBalancerArn" \
  --output text)
ALB_FULL=$(echo "$ALB_ARN" | sed 's|.*:loadbalancer/||')

TG_ARN=$(aws elbv2 describe-target-groups \
  --names bite-tg \
  --region "$REGION" \
  --query "TargetGroups[0].TargetGroupArn" \
  --output text)
TG_FULL=$(echo "$TG_ARN" | sed 's|.*::||')

aws cloudformation deploy \
  --template-file infra/cloudformation/s3_cloudwatch.yaml \
  --stack-name bite-s3-cloudwatch \
  --region "$REGION" \
  --parameter-overrides \
    ASGName=bite-asg \
    ALBFullName="$ALB_FULL" \
    TargetGroupFullName="$TG_FULL" \
    AlarmEmail="$ALARM_EMAIL"

echo ""
echo "=== DESPLIEGUE COMPLETADO ==="
echo "ALB URL: http://$ALB_DNS"
echo "Actualizar load_test/config.json con la URL del ALB antes de ejecutar la prueba."
