#!/bin/bash
# Fallo B: Detiene DOS instancias EC2 simultaneamente para evaluar alta concurrencia de fallos.

set -euo pipefail

ASG_NAME="${ASG_NAME:-bite-asg}"
REGION="${AWS_REGION:-us-east-1}"

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] === INICIO INYECCION FALLO B (2 instancias) ==="

INSTANCE_IDS=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$ASG_NAME" \
  --region "$REGION" \
  --query "AutoScalingGroups[0].Instances[?LifecycleState=='InService'].InstanceId" \
  --output text | tr '\t' ' ')

COUNT=$(echo $INSTANCE_IDS | wc -w | tr -d ' ')
if [ "$COUNT" -lt 2 ]; then
  echo "ERROR: Se necesitan al menos 2 instancias InService (actual: $COUNT)"
  exit 1
fi

IDS_TO_STOP=$(echo $INSTANCE_IDS | awk '{print $1, $2}')
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Deteniendo instancias: $IDS_TO_STOP"
FAULT_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)

aws ec2 stop-instances \
  --instance-ids $IDS_TO_STOP \
  --region "$REGION" \
  --output text > /dev/null

echo "[${FAULT_TIME}] Instancias detenidas. Monitoreando recuperacion..."

DESIRED=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$ASG_NAME" \
  --region "$REGION" \
  --query "AutoScalingGroups[0].DesiredCapacity" \
  --output text)

TIMEOUT=180
ELAPSED=0
while [ $ELAPSED -lt $TIMEOUT ]; do
  IN_SERVICE=$(aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$ASG_NAME" \
    --region "$REGION" \
    --query "length(AutoScalingGroups[0].Instances[?LifecycleState=='InService'])" \
    --output text)

  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Instancias InService: $IN_SERVICE / $DESIRED"

  if [ "$IN_SERVICE" -ge "$DESIRED" ]; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] RECUPERACION COMPLETA"
    break
  fi

  sleep 5
  ELAPSED=$((ELAPSED + 5))
done

if [ $ELAPSED -ge $TIMEOUT ]; then
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] TIMEOUT: El ASG no recupero en ${TIMEOUT}s"
  exit 2
fi

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] === FIN INYECCION FALLO B ==="
