#!/bin/bash
# Fallo C: Bloquea el trafico de salida al endpoint de API externa
# modificando el Security Group de las EC2. Restaura despues de N segundos.

set -euo pipefail

SG_ID="${EC2_SG_ID}"        # Security Group de las instancias EC2
EXTERNAL_IP="${EXTERNAL_API_IP}"  # IP del endpoint externo a bloquear (CIDR /32)
BLOCK_DURATION="${BLOCK_SECONDS:-30}"
REGION="${AWS_REGION:-us-east-1}"

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Bloqueando trafico de salida a $EXTERNAL_IP en SG $SG_ID"

aws ec2 revoke-security-group-egress \
  --group-id "$SG_ID" \
  --ip-permissions IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges="[{CidrIp=${EXTERNAL_IP}/32}]" \
  --region "$REGION" 2>/dev/null || true

aws ec2 authorize-security-group-egress \
  --group-id "$SG_ID" \
  --ip-permissions "IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=${EXTERNAL_IP}/32,Description=BLOCKED-FOR-TEST}]" \
  --region "$REGION"

FAULT_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "[${FAULT_TIME}] Trafico bloqueado. Esperando ${BLOCK_DURATION}s para restaurar..."

sleep "$BLOCK_DURATION"

aws ec2 revoke-security-group-egress \
  --group-id "$SG_ID" \
  --ip-permissions "IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=${EXTERNAL_IP}/32}]" \
  --region "$REGION"

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Trafico restaurado. Fallo C finalizado."
