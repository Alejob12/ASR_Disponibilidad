#!/bin/bash
# Exporta metricas de CloudWatch relevantes al experimento de disponibilidad.
# Genera archivos JSON en ./metrics/ para analisis posterior.

set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
ASG_NAME="${ASG_NAME:-bite-asg}"
ALB_FULL_NAME="${ALB_FULL_NAME}"         # ej: app/bite-alb/xxxxxxxxxxxx
TG_FULL_NAME="${TG_FULL_NAME}"           # ej: targetgroup/bite-tg/xxxxxxxxxxxx
START_TIME="${START_TIME:-$(date -u -v-1H +%Y-%m-%dT%H:%M:%SZ)}"
END_TIME="${END_TIME:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
OUT_DIR="./metrics"

mkdir -p "$OUT_DIR"

echo "Exportando metricas de $START_TIME a $END_TIME"

# CPU de las EC2 del ASG
aws cloudwatch get-metric-statistics \
  --namespace AWS/EC2 \
  --metric-name CPUUtilization \
  --dimensions Name=AutoScalingGroupName,Value="$ASG_NAME" \
  --start-time "$START_TIME" --end-time "$END_TIME" \
  --period 10 --statistics Average \
  --region "$REGION" \
  --output json > "$OUT_DIR/cpu_utilization.json"

# Hosts no saludables en el Target Group
aws cloudwatch get-metric-statistics \
  --namespace AWS/ApplicationELB \
  --metric-name UnHealthyHostCount \
  --dimensions Name=LoadBalancer,Value="$ALB_FULL_NAME" Name=TargetGroup,Value="$TG_FULL_NAME" \
  --start-time "$START_TIME" --end-time "$END_TIME" \
  --period 5 --statistics Maximum \
  --region "$REGION" \
  --output json > "$OUT_DIR/unhealthy_hosts.json"

# Errores 5xx del ALB
aws cloudwatch get-metric-statistics \
  --namespace AWS/ApplicationELB \
  --metric-name HTTPCode_Target_5XX_Count \
  --dimensions Name=LoadBalancer,Value="$ALB_FULL_NAME" \
  --start-time "$START_TIME" --end-time "$END_TIME" \
  --period 10 --statistics Sum \
  --region "$REGION" \
  --output json > "$OUT_DIR/5xx_errors.json"

# Request count total
aws cloudwatch get-metric-statistics \
  --namespace AWS/ApplicationELB \
  --metric-name RequestCount \
  --dimensions Name=LoadBalancer,Value="$ALB_FULL_NAME" \
  --start-time "$START_TIME" --end-time "$END_TIME" \
  --period 10 --statistics Sum \
  --region "$REGION" \
  --output json > "$OUT_DIR/request_count.json"

# Historial de actividades del ASG
aws autoscaling describe-scaling-activities \
  --auto-scaling-group-name "$ASG_NAME" \
  --region "$REGION" \
  --output json > "$OUT_DIR/asg_activities.json"

echo "Metricas guardadas en $OUT_DIR/"
