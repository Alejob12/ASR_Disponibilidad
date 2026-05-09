#!/bin/bash
# Configura las credenciales temporales de AWS Academy en ~/.aws/credentials
#
# Uso:
#   bash scripts/set-academy-credentials.sh
#
# Donde obtener las credenciales:
#   AWS Academy Learner Lab → boton "AWS Details" → "AWS CLI" → copiar bloque

set -e

echo "========================================================"
echo "  Configurador de credenciales – AWS Academy"
echo "========================================================"
echo ""
echo "1. Abre tu Learner Lab en AWS Academy"
echo "2. Haz clic en 'AWS Details'"
echo "3. Expande 'AWS CLI' y copia el bloque completo"
echo "   (incluye [default], aws_access_key_id, etc.)"
echo ""
echo "Pega el bloque aqui y presiona ENTER dos veces cuando termines:"
echo "--------------------------------------------------------"

lines=()
while IFS= read -r line; do
    [ -z "$line" ] && break
    lines+=("$line")
done

if [ ${#lines[@]} -eq 0 ]; then
    echo "No se pegaron credenciales. Saliendo."
    exit 1
fi

mkdir -p ~/.aws

# Reemplazar o crear la seccion [default]
CREDS_BLOCK=$(printf '%s\n' "${lines[@]}")

python3 - <<PYEOF
import re, os

creds_path = os.path.expanduser("~/.aws/credentials")
new_block = """${CREDS_BLOCK}"""

if os.path.exists(creds_path):
    content = open(creds_path).read()
    # Eliminar seccion [default] existente
    content = re.sub(r'\[default\][^\[]*', '', content, flags=re.DOTALL).strip()
    content = content + "\n\n" + new_block + "\n"
else:
    content = new_block + "\n"

open(creds_path, "w").write(content)
print("Archivo ~/.aws/credentials actualizado.")
PYEOF

echo ""
echo "Verificando credenciales..."
if aws sts get-caller-identity --output table 2>/dev/null; then
    echo ""
    echo "Credenciales validas. Puedes ejecutar el despliegue:"
    echo "  bash scripts/full-deploy.sh"
else
    echo ""
    echo "ERROR: Las credenciales no son validas."
    echo "Asegurate de que el Learner Lab este INICIADO (estado verde) antes de copiar."
    exit 1
fi
