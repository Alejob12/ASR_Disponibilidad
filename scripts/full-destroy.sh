#!/bin/bash
# Destruye toda la infraestructura del experimento.
# Usar al terminar la sesion de Academy para liberar recursos.

set -euo pipefail

CDK_DIR="$(cd "$(dirname "$0")/../infra/cdk" && pwd)"
VENV_DIR="$CDK_DIR/.venv"

echo "ADVERTENCIA: Esto eliminara todos los recursos AWS del experimento."
read -r -p "¿Continuar? (escribe 'si' para confirmar): " confirm
[ "$confirm" != "si" ] && echo "Cancelado." && exit 0

cd "$CDK_DIR"
source "$VENV_DIR/bin/activate"

cdk destroy --force
echo "Infraestructura eliminada."
