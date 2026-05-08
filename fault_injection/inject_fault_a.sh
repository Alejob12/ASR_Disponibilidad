#!/bin/bash
# Fallo A: Detiene UNA instancia EC2 del ASG para simular caida simple.
# Registra timestamp exacto y espera a que el ASG reponga la instancia.

set -euo pipefail

ASG_NAME="${ASG_NAME:-bite-asg}"
REGION="${AWS_REGION:-us-east-1}"

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] === INICIO INYECCION FALLO A ==="

# Obtener una instancia activa del ASG
INSTANCE_ID=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$ASG_NAME" \
  --region "$REGION" \
  --query "AutoScalingGroups[0].Instances[?LifecycleState=='InService'].InstanceId | [0]" \
  --output text)

if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" = "None" ]; then
  echo "ERROR: No se encontraron instancias InService en $ASG_NAME"
  exit 1
fi

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Deteniendo instancia: $INSTANCE_ID"
FAULT_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)

aws ec2 stop-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$REGION" \
  --output text > /dev/null

echo "[${FAULT_TIME}] Instancia $INSTANCE_ID detenida. Monitoreando recuperacion..."

# Esperar hasta que el ASG tenga de vuelta el numero deseado de instancias InService
TIMEOUT=120
ELAPSED=0
while [ $ELAPSED -lt $TIMEOUT ]; do
  IN_SERVICE=$(aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$ASG_NAME" \
    --region "$REGION" \
    --query "length(AutoScalingGroups[0].Instances[?LifecycleState=='InService'])" \
    --output text)

  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Instancias InService: $IN_SERVICE"

  DESIRED=$(aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$ASG_NAME" \
    --region "$REGION" \
    --query "AutoScalingGroups[0].DesiredCapacity" \
    --output text)

  if [ "$IN_SERVICE" -ge "$DESIRED" ]; then
    RECOVERY_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    echo "[${RECOVERY_TIME}] RECUPERACION COMPLETA. Instancias InService: $IN_SERVICE / $DESIRED"
    break
  fi

  sleep 5
  ELAPSED=$((ELAPSED + 5))
done

if [ $ELAPSED -ge $TIMEOUT ]; then
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] TIMEOUT: El ASG no recupero las instancias en ${TIMEOUT}s"
  exit 2
fi

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] === FIN INYECCION FALLO A ==="
