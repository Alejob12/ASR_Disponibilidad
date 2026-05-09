#!/bin/bash
# Despliegue completo del experimento ASR Disponibilidad en AWS Academy
#
# Este script:
#   1. Verifica las credenciales de la sesion activa
#   2. Instala las dependencias de CDK en un virtualenv local
#   3. Hace bootstrap de CDK en la cuenta/region de Academy
#   4. Despliega el BiteStack (ALB + ASG + RDS + S3 + CloudWatch)
#   5. Actualiza load_test/config.json con la URL del ALB
#
# Uso:
#   bash scripts/full-deploy.sh
#
# Requisitos previos:
#   - Python 3.8+
#   - Node.js 18+ (requerido por CDK CLI)
#   - AWS CLI configurado con credenciales de Academy
#     (ejecutar scripts/set-academy-credentials.sh si no esta configurado)

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CDK_DIR="$ROOT_DIR/infra/cdk"
VENV_DIR="$CDK_DIR/.venv"
OUTPUTS_FILE="$ROOT_DIR/deploy-outputs.json"

echo "========================================================"
echo "  BITE.co – Despliegue ASR Disponibilidad"
echo "========================================================"

# ── 1. Verificar credenciales ──────────────────────────────────────────────
echo ""
echo "[1/5] Verificando credenciales AWS..."
if ! aws sts get-caller-identity --output table; then
    echo ""
    echo "ERROR: No hay credenciales validas."
    echo "Ejecuta primero: bash scripts/set-academy-credentials.sh"
    exit 1
fi

# ── 2. Verificar Node.js (CDK CLI lo requiere) ─────────────────────────────
echo ""
echo "[2/5] Verificando dependencias..."
if ! command -v node &>/dev/null; then
    echo "ERROR: Node.js no encontrado. Instala Node.js 18+ desde https://nodejs.org"
    exit 1
fi
NODE_VER=$(node --version | sed 's/v//' | cut -d. -f1)
if [ "$NODE_VER" -lt 18 ]; then
    echo "ERROR: Se requiere Node.js >= 18 (actual: $(node --version))"
    exit 1
fi

# Instalar CDK CLI si no esta instalado
if ! command -v cdk &>/dev/null; then
    echo "Instalando AWS CDK CLI..."
    npm install -g aws-cdk --quiet
fi
echo "  CDK version: $(cdk --version)"
echo "  Node.js    : $(node --version)"

# ── 3. Entorno virtual Python + dependencias CDK ───────────────────────────
echo ""
echo "[3/5] Instalando dependencias Python de CDK..."
cd "$CDK_DIR"

if [ ! -d "$VENV_DIR" ]; then
    python3 -m venv "$VENV_DIR"
fi
source "$VENV_DIR/bin/activate"
pip install --quiet --upgrade pip
pip install --quiet -r requirements.txt
echo "  Dependencias instaladas."

# ── 4. Bootstrap CDK ───────────────────────────────────────────────────────
echo ""
echo "[4/5] Ejecutando CDK bootstrap..."
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGION=$(python3 -c "import json; print(json.load(open('config.json'))['region'])")
cdk bootstrap "aws://$ACCOUNT/$REGION" --quiet
echo "  Bootstrap completado en cuenta $ACCOUNT, region $REGION."

# ── 5. Deploy ─────────────────────────────────────────────────────────────
echo ""
echo "[5/5] Desplegando BiteStack (puede tardar 10-15 minutos)..."
cdk deploy --require-approval never --outputs-file "$OUTPUTS_FILE"

# ── Post-deploy: actualizar config del load test ───────────────────────────
echo ""
echo "========================================================"
echo "  Despliegue completado"
echo "========================================================"
echo ""
cat "$OUTPUTS_FILE"

ALB_URL=$(python3 - <<'PYEOF'
import json, sys
try:
    outputs = json.load(open(sys.argv[1]))
    stack = outputs.get("BiteStack", {})
    for v in stack.values():
        if v.startswith("http://"):
            print(v)
            break
except Exception:
    pass
PYEOF
"$OUTPUTS_FILE" || true)

if [ -n "$ALB_URL" ]; then
    echo "Actualizando load_test/config.json con $ALB_URL..."
    python3 - "$ROOT_DIR/load_test/config.json" "$ALB_URL" <<'PYEOF'
import json, sys
path, url = sys.argv[1], sys.argv[2]
cfg = json.load(open(path))
cfg["alb_url"] = url
json.dump(cfg, open(path, "w"), indent=2)
print("  load_test/config.json actualizado.")
PYEOF
fi

echo ""
echo "Proximos pasos:"
echo "  1. Confirma la suscripcion de alarmas SNS (email de AWS)"
echo "  2. cd load_test && python load_test.py --config config.json"
echo "  3. En otra terminal: bash fault_injection/inject_fault_a.sh"
echo ""
echo "Para destruir toda la infraestructura:"
echo "  bash scripts/full-destroy.sh"
