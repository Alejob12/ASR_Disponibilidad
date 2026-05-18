#!/usr/bin/env bash
# =============================================================================
#  EXPERIMENTO ASR — Disponibilidad BITE.co
#  Menú interactivo para controlar cada fase del experimento
#  Uso: bash scripts/experimento.sh
# =============================================================================

set -euo pipefail

# ── Rutas ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
LOAD_TEST_DIR="$ROOT/load_test"
LOAD_SCRIPT="$LOAD_TEST_DIR/load_test.py"
LOAD_CONFIG="$LOAD_TEST_DIR/config.json"

ASG_NAME="BiteStack-AsgASGD1D7B4E2-zbuWNyOmiwka"

# ── Detectar python3 con aiohttp ──────────────────────────────────────────────
# macOS puede tener varios python3; buscamos el que tenga aiohttp instalado
_find_python() {
    for py in python3 python3.13 python3.12 python3.11 \
               /Library/Frameworks/Python.framework/Versions/*/bin/python3 \
               /usr/local/bin/python3; do
        if command -v "$py" &>/dev/null && "$py" -c "import aiohttp" 2>/dev/null; then
            echo "$py"
            return 0
        fi
    done
    return 1
}

PYTHON3=$(_find_python 2>/dev/null || true)

if [[ -z "$PYTHON3" ]]; then
    # Ningún python3 tiene aiohttp — instalar en el python3 del sistema
    PYTHON3=$(command -v python3)
    echo "Instalando aiohttp en $PYTHON3 ..."
    "$PYTHON3" -m pip install aiohttp --quiet
fi

# ── Colores ───────────────────────────────────────────────────────────────────
RESET='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
BG_BLUE='\033[44m'
BG_DARK='\033[40m'

# ── Helpers ───────────────────────────────────────────────────────────────────

# Imprime el comando en amarillo ANTES de ejecutarlo
run() {
    echo ""
    echo -e "  ${YELLOW}▶ $*${RESET}"
    echo ""
    eval "$@"
}

# Igual que run pero oculta el output (para comandos silenciosos)
run_silent() {
    echo ""
    echo -e "  ${YELLOW}▶ $*${RESET}"
    eval "$@" > /dev/null 2>&1
}

# Sección visual
section() {
    echo ""
    echo -e "${BG_BLUE}${WHITE}  $1  ${RESET}"
    echo ""
}

ok()   { echo -e "  ${GREEN}✔  $1${RESET}"; }
warn() { echo -e "  ${YELLOW}⚠  $1${RESET}"; }
err()  { echo -e "  ${RED}✘  $1${RESET}"; }
info() { echo -e "  ${CYAN}ℹ  $1${RESET}"; }

pause() {
    echo ""
    read -rp "  Presiona ENTER para continuar..." _
}

# Barra de progreso para esperas con duración fija
progress_bar() {
    local duration=$1
    local label="${2:-}"
    local width=36
    local i bar filled empty pct elapsed start
    start=$(date +%s)
    while true; do
        elapsed=$(( $(date +%s) - start ))
        [[ $elapsed -ge $duration ]] && elapsed=$duration
        pct=$(( elapsed * 100 / duration ))
        filled=$(( elapsed * width / duration ))
        empty=$(( width - filled ))
        bar=""
        for (( i=0; i<filled; i++ )); do bar+="█"; done
        for (( i=0; i<empty;  i++ )); do bar+="░"; done
        printf "\r  ${CYAN}[%s]${RESET} %3d%% ${DIM}(%ds/%ds)${RESET}  %s" \
          "$bar" "$pct" "$elapsed" "$duration" "$label"
        [[ $elapsed -ge $duration ]] && break
        sleep 1
    done
    printf "\n"
}

# Barra de progreso mientras un proceso background sigue vivo
wait_with_bar() {
    local pid=$1
    local duration=$2
    local label="${3:-Load test en progreso...}"
    local width=36
    local i bar filled empty pct elapsed start
    start=$(date +%s)
    while kill -0 "$pid" 2>/dev/null; do
        elapsed=$(( $(date +%s) - start ))
        [[ $elapsed -ge $duration ]] && elapsed=$duration
        pct=$(( elapsed * 100 / duration ))
        filled=$(( elapsed * width / duration ))
        empty=$(( width - filled ))
        bar=""
        for (( i=0; i<filled; i++ )); do bar+="█"; done
        for (( i=0; i<empty;  i++ )); do bar+="░"; done
        printf "\r  ${CYAN}[%s]${RESET} %3d%% ${DIM}(%ds/%ds)${RESET}  %s" \
          "$bar" "$pct" "$elapsed" "$duration" "$label"
        sleep 1
    done
    # Completar al 100% en verde
    elapsed=$(( $(date +%s) - start ))
    bar=""
    for (( i=0; i<width; i++ )); do bar+="█"; done
    printf "\r  ${GREEN}[%s]${RESET} 100%% ${DIM}(%ds/%ds)${RESET}  %s\n" \
      "$bar" "$elapsed" "$duration" "$label"
    wait "$pid" 2>/dev/null || true
}

# Analiza un CSV de resultados y muestra métricas
show_results() {
    local csv="$1"
    local label="${2:-Resultados}"
    echo ""
    echo -e "${BOLD}${label}${RESET}"
    $PYTHON3 - "$csv" << 'PYEOF'
import csv, sys
path = sys.argv[1]
with open(path) as f:
    rows = list(csv.DictReader(f))
total = len(rows)
if total == 0:
    print("  Sin datos en el CSV")
    sys.exit(0)
ok    = sum(1 for r in rows if 200 <= int(r['status']) < 300)
e5xx  = sum(1 for r in rows if 500 <= int(r['status']) < 600)
e504  = sum(1 for r in rows if int(r['status']) == 504)
lats  = sorted(float(r['latency_ms']) for r in rows)
n     = len(lats)
avail = ok / total * 100
p50   = lats[int(n * 0.50)]
p95   = lats[int(n * 0.95)]
p99   = lats[int(n * 0.99)]

GREEN  = '\033[0;32m'
RED    = '\033[0;31m'
YELLOW = '\033[0;33m'
CYAN   = '\033[0;36m'
RESET  = '\033[0m'
BOLD   = '\033[1m'

avail_color = GREEN if avail >= 96.5 else RED
print(f"  {'─'*44}")
print(f"  Total requests : {BOLD}{total:>10,}{RESET}")
print(f"  Éxitos (2xx)   : {GREEN}{ok:>10,}{RESET}")
print(f"  Errores 5xx    : {RED if e5xx else RESET}{e5xx:>10}{RESET}")
print(f"  Timeouts 504   : {YELLOW if e504 else RESET}{e504:>10}{RESET}")
print(f"  {'─'*44}")
print(f"  Disponibilidad : {avail_color}{BOLD}{avail:>9.2f} %{RESET}")
print(f"  {'─'*44}")
print(f"  Latencia p50   : {p50:>9.0f} ms")
print(f"  Latencia p95   : {p95:>9.0f} ms")
print(f"  Latencia p99   : {p99:>9.0f} ms")
print(f"  {'─'*44}")
PYEOF
}

# ── Credenciales ──────────────────────────────────────────────────────────────
configurar_credenciales() {
    echo ""
    echo -e "${CYAN}Pega las credenciales AWS (línea 1: Access Key, línea 2: Secret Key):${RESET}"
    echo -e "${DIM}  Cuenta personal: 2 líneas. AWS Academy: 3 líneas (+ session token).${RESET}"
    echo ""

    local key secret token
    IFS= read -r key
    IFS= read -r secret
    # Tercera línea opcional (session token Academy)
    IFS= read -t 2 -r token 2>/dev/null || token=""

    key=$(echo "$key"    | tr -d ' \r')
    secret=$(echo "$secret" | tr -d ' \r')
    token=$(echo "$token"  | tr -d ' \r')

    if [[ -z "$key" || -z "$secret" ]]; then
        err "Faltan datos. Pega Access Key en la línea 1 y Secret Key en la línea 2."
        return 1
    fi

    export AWS_ACCESS_KEY_ID="$key"
    export AWS_SECRET_ACCESS_KEY="$secret"
    export AWS_DEFAULT_REGION="us-east-1"

    if [[ -n "$token" ]]; then
        export AWS_SESSION_TOKEN="$token"
        info "Modo: AWS Academy (con session token)"
    else
        unset AWS_SESSION_TOKEN
        info "Modo: cuenta personal (sin session token)"
    fi

    echo ""
    echo -e "  ${YELLOW}▶ aws sts get-caller-identity${RESET}"
    echo ""
    if aws sts get-caller-identity --output table 2>&1; then
        ok "Credenciales válidas"
    else
        err "Credenciales rechazadas — verifica los valores pegados"
        return 1
    fi
}

# ── FASE 0: Verificar infraestructura ────────────────────────────────────────
fase_verificar() {
    section "VERIFICACIÓN DE INFRAESTRUCTURA"

    section "Estado del ASG"
    run "aws autoscaling describe-auto-scaling-groups \
      --auto-scaling-group-names '$ASG_NAME' \
      --query 'AutoScalingGroups[0].{Min:MinSize,Desired:DesiredCapacity,Max:MaxSize,Instances:Instances[*].{ID:InstanceId,State:LifecycleState,Health:HealthStatus}}' \
      --output json"

    section "Instancias en el ASG"
    run "aws autoscaling describe-auto-scaling-groups \
      --auto-scaling-group-names '$ASG_NAME' \
      --query 'AutoScalingGroups[0].Instances[*].{ID:InstanceId,Estado:LifecycleState,Salud:HealthStatus}' \
      --output table"

    section "Hosts sanos en el ALB (Target Group)"
    local TG_ARN
    TG_ARN=$(aws elbv2 describe-target-groups \
      --query 'TargetGroups[0].TargetGroupArn' --output text)
    run "aws elbv2 describe-target-health \
      --target-group-arn '$TG_ARN' \
      --query 'TargetHealthDescriptions[*].{ID:Target.Id,Puerto:Target.Port,Estado:TargetHealth.State}' \
      --output table"

    section "Verificando gunicorn --threads 25 en cada instancia"
    INSTANCE_IDS=()
    while IFS= read -r id; do [[ -n "$id" ]] && INSTANCE_IDS+=("$id"); done < <(
      aws autoscaling describe-auto-scaling-groups \
        --auto-scaling-group-names "$ASG_NAME" \
        --query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService`].InstanceId' \
        --output text | tr '\t' '\n'
    )

    info "Instancias InService: ${INSTANCE_IDS[*]}"

    local ids_arg="${INSTANCE_IDS[*]}"
    run "aws ssm send-command \
      --instance-ids $ids_arg \
      --document-name 'AWS-RunShellScript' \
      --parameters 'commands=[\"ps aux | grep gunicorn | grep -v grep | grep -o -- \\\"--threads [0-9]*\\\" | head -1\"]' \
      --query 'Command.CommandId' --output text"

    local CMD_ID
    CMD_ID=$(aws ssm send-command \
      --instance-ids ${INSTANCE_IDS[@]} \
      --document-name "AWS-RunShellScript" \
      --parameters 'commands=["ps aux | grep gunicorn | grep -v grep | grep -o -- \"--threads [0-9]*\" | head -1"]' \
      --query 'Command.CommandId' --output text)

    progress_bar 5 "Esperando resultado SSM..."

    run "aws ssm send-command \
      --instance-ids $ids_arg \
      --document-name 'AWS-RunShellScript' \
      --parameters 'commands=[\"systemctl is-active bite-app && ps aux | grep gunicorn | grep -v grep | head -1\"]' \
      --query 'Command.CommandId' --output text"

    for ID in "${INSTANCE_IDS[@]}"; do
        local out
        out=$(aws ssm get-command-invocation \
          --command-id "$CMD_ID" \
          --instance-id "$ID" \
          --query 'StandardOutputContent' --output text 2>/dev/null || echo "(pendiente)")
        if echo "$out" | grep -q "\-\-threads 25"; then
            ok "$ID → $(echo "$out" | tr -d '\n')"
        elif [[ "$out" == "(pendiente)" ]]; then
            warn "$ID → aún procesando"
        else
            warn "$ID → SIN --threads 25: $out"
        fi
    done

    pause
}

# ── Aplicar --threads 25 a todas las instancias ───────────────────────────────
aplicar_threads() {
    section "APLICANDO --threads 25 A TODAS LAS INSTANCIAS"

    INSTANCE_IDS=()
    while IFS= read -r id; do [[ -n "$id" ]] && INSTANCE_IDS+=("$id"); done < <(
      aws autoscaling describe-auto-scaling-groups \
      --auto-scaling-group-names "$ASG_NAME" \
      --query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService`].InstanceId' \
      --output text | tr '\t' '\n')

    info "Instancias: ${INSTANCE_IDS[*]}"

    run "aws ssm send-command \
      --instance-ids ${INSTANCE_IDS[*]} \
      --document-name 'AWS-RunShellScript' \
      --parameters 'commands=[
        \"grep -q -- \\\"--threads\\\" /etc/systemd/system/bite-app.service || sed -i \\\"s|-w 4 -b|-w 4 --threads 25 -b|\\\" /etc/systemd/system/bite-app.service\",
        \"systemctl daemon-reload\",
        \"systemctl restart bite-app\",
        \"sleep 3\",
        \"ps aux | grep gunicorn | grep -v grep | head -1\"
      ]' \
      --query 'Command.CommandId' --output text"

    local CMD_ID
    CMD_ID=$(aws ssm send-command \
      --instance-ids ${INSTANCE_IDS[@]} \
      --document-name "AWS-RunShellScript" \
      --parameters 'commands=[
        "grep -q -- \"--threads\" /etc/systemd/system/bite-app.service || sed -i \"s|-w 4 -b|-w 4 --threads 25 -b|\" /etc/systemd/system/bite-app.service",
        "systemctl daemon-reload",
        "systemctl restart bite-app",
        "sleep 3",
        "ps aux | grep gunicorn | grep -v grep | head -1"
      ]' \
      --query 'Command.CommandId' --output text)

    progress_bar 12 "Reiniciando gunicorn en todas las instancias..."

    for ID in "${INSTANCE_IDS[@]}"; do
        local out
        out=$(aws ssm get-command-invocation \
          --command-id "$CMD_ID" \
          --instance-id "$ID" \
          --query 'StandardOutputContent' --output text 2>/dev/null || echo "sin respuesta")
        if echo "$out" | grep -q "\-\-threads 25"; then
            ok "$ID → --threads 25 activo"
        else
            warn "$ID → $out"
        fi
    done
}

# ── FASE 2: Baseline ──────────────────────────────────────────────────────────
fase_baseline() {
    local OUT="$LOAD_TEST_DIR/results_baseline_demo.csv"
    section "FASE 2 — BASELINE (sin fallos)"
    info "75 usuarios concurrentes · 250s · sin inyección de fallos"
    echo ""

    echo -e "  ${YELLOW}▶ $PYTHON3 $LOAD_SCRIPT --config $LOAD_CONFIG --output $OUT${RESET}"
    echo ""
    $PYTHON3 "$LOAD_SCRIPT" --config "$LOAD_CONFIG" --output "$OUT" &
    local LOAD_PID=$!
    wait_with_bar "$LOAD_PID" 250 "Fase 2 — Baseline · 75 usuarios · 250s"

    show_results "$OUT" "Fase 2 — Baseline"
    pause
}

# ── FASE 3: Fallo A — 1 instancia ────────────────────────────────────────────
fase_fallo_a() {
    local OUT="$LOAD_TEST_DIR/results_fault_a_demo.csv"
    section "FASE 3 — FALLO A: 1 instancia detenida bajo carga"
    info "Load test arranca → T+30s se detiene 1 instancia → medimos disponibilidad"
    echo ""

    INSTANCE_IDS=()
    while IFS= read -r id; do [[ -n "$id" ]] && INSTANCE_IDS+=("$id"); done < <(
      aws autoscaling describe-auto-scaling-groups \
      --auto-scaling-group-names "$ASG_NAME" \
      --query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService`].InstanceId' \
      --output text | tr '\t' '\n')

    local VICTIM="${INSTANCE_IDS[0]}"
    info "Víctima seleccionada: $VICTIM"
    info "Iniciando load test en background..."
    echo ""
    echo -e "  ${YELLOW}▶ $PYTHON3 $LOAD_SCRIPT --config $LOAD_CONFIG --output $OUT &${RESET}"
    echo ""

    $PYTHON3 "$LOAD_SCRIPT" --config "$LOAD_CONFIG" --output "$OUT" &
    local LOAD_PID=$!
    info "Load test PID: $LOAD_PID"
    echo ""
    progress_bar 30 "Esperando T+30s para inyectar fallo..."

    echo ""
    echo -e "  ${RED}${BOLD}▶ aws ec2 stop-instances --instance-ids $VICTIM${RESET}"
    aws ec2 stop-instances --instance-ids "$VICTIM" --output text > /dev/null
    echo -e "  ${RED}✘  FALLO INYECTADO: $VICTIM detenida a las $(date '+%H:%M:%S')${RESET}"
    echo ""
    wait_with_bar "$LOAD_PID" 220 "Fase 3 — load test · 220s restantes"

    show_results "$OUT" "Fase 3 — Fallo A"
    pause
}

# ── FASE 4: Fallo B — 2 instancias ───────────────────────────────────────────
fase_fallo_b() {
    local OUT="$LOAD_TEST_DIR/results_fault_b_final.csv"
    section "FASE 4 — FALLO B: 2 instancias detenidas simultáneamente"
    info "Load test arranca → T+30s se detienen 2 instancias → medimos disponibilidad"
    echo ""

    INSTANCE_IDS=()
    while IFS= read -r id; do [[ -n "$id" ]] && INSTANCE_IDS+=("$id"); done < <(
      aws autoscaling describe-auto-scaling-groups \
      --auto-scaling-group-names "$ASG_NAME" \
      --query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService`].InstanceId' \
      --output text | tr '\t' '\n')

    if [[ ${#INSTANCE_IDS[@]} -lt 3 ]]; then
        err "Se necesitan al menos 3 instancias InService. Actualmente: ${#INSTANCE_IDS[@]}"
        pause
        return 1
    fi

    local V1="${INSTANCE_IDS[0]}"
    local V2="${INSTANCE_IDS[1]}"
    info "Víctimas: $V1 y $V2"
    info "Iniciando load test en background..."
    echo ""
    echo -e "  ${YELLOW}▶ $PYTHON3 $LOAD_SCRIPT --config $LOAD_CONFIG --output $OUT &${RESET}"
    echo ""

    $PYTHON3 "$LOAD_SCRIPT" --config "$LOAD_CONFIG" --output "$OUT" &
    local LOAD_PID=$!
    info "Load test PID: $LOAD_PID"
    echo ""
    progress_bar 30 "Esperando T+30s para inyectar fallo..."

    echo ""
    echo -e "  ${RED}${BOLD}▶ aws ec2 stop-instances --instance-ids $V1 $V2${RESET}"
    aws ec2 stop-instances --instance-ids "$V1" "$V2" --output text > /dev/null
    echo -e "  ${RED}✘  FALLO INYECTADO: $V1 y $V2 detenidas a las $(date '+%H:%M:%S')${RESET}"
    echo ""
    wait_with_bar "$LOAD_PID" 220 "Fase 4 — load test · 220s restantes"

    show_results "$OUT" "Fase 4 — Fallo B"
    pause
}

# ── FASE 5: Fallo API externa ─────────────────────────────────────────────────
fase_fallo_api() {
    local OUT="$LOAD_TEST_DIR/results_fault_api_final.csv"
    section "FASE 5 — FALLO DE API EXTERNA (Cost Explorer bloqueado)"
    info "Bloquea ce.us-east-1.amazonaws.com en /etc/hosts → activa el fallback → desbloquea al terminar"
    echo ""

    INSTANCE_IDS=()
    while IFS= read -r id; do [[ -n "$id" ]] && INSTANCE_IDS+=("$id"); done < <(
      aws autoscaling describe-auto-scaling-groups \
      --auto-scaling-group-names "$ASG_NAME" \
      --query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService`].InstanceId' \
      --output text | tr '\t' '\n')

    section "Bloqueando Cost Explorer en todas las instancias"
    run "aws ssm send-command \
      --instance-ids ${INSTANCE_IDS[*]} \
      --document-name 'AWS-RunShellScript' \
      --parameters 'commands=[\"grep -q ce.us-east-1.amazonaws.com /etc/hosts || echo \\\"127.0.0.1 ce.us-east-1.amazonaws.com\\\" >> /etc/hosts\", \"grep ce.us-east-1.amazonaws.com /etc/hosts\"]' \
      --query 'Command.CommandId' --output text"

    aws ssm send-command \
      --instance-ids ${INSTANCE_IDS[@]} \
      --document-name "AWS-RunShellScript" \
      --parameters 'commands=[
        "grep -q ce.us-east-1.amazonaws.com /etc/hosts || echo \"127.0.0.1 ce.us-east-1.amazonaws.com\" >> /etc/hosts",
        "grep ce.us-east-1.amazonaws.com /etc/hosts"
      ]' \
      --query 'Command.CommandId' --output text > /dev/null

    progress_bar 5 "Esperando que el bloqueo se propague..."

    section "Ejecutando load test con Cost Explorer bloqueado"
    echo -e "  ${YELLOW}▶ $PYTHON3 $LOAD_SCRIPT --config $LOAD_CONFIG --output $OUT${RESET}"
    echo ""
    $PYTHON3 "$LOAD_SCRIPT" --config "$LOAD_CONFIG" --output "$OUT" &
    local LOAD_PID=$!
    wait_with_bar "$LOAD_PID" 250 "Fase 5 — API bloqueada · 250s"

    section "Desbloqueando Cost Explorer en todas las instancias"
    run "aws ssm send-command \
      --instance-ids ${INSTANCE_IDS[*]} \
      --document-name 'AWS-RunShellScript' \
      --parameters 'commands=[\"sed -i \\\"/ce.us-east-1.amazonaws.com/d\\\" /etc/hosts\"]' \
      --query 'Command.CommandId' --output text"

    aws ssm send-command \
      --instance-ids ${INSTANCE_IDS[@]} \
      --document-name "AWS-RunShellScript" \
      --parameters 'commands=["sed -i \"/ce.us-east-1.amazonaws.com/d\" /etc/hosts"]' \
      --query 'Command.CommandId' --output text > /dev/null

    ok "Cost Explorer desbloqueado"

    show_results "$OUT" "Fase 5 — Fallo API externa"
    pause
}

# ── FASE 7: Recuperación ──────────────────────────────────────────────────────
fase_recuperacion() {
    local OUT="$LOAD_TEST_DIR/fase7_recovery.csv"
    section "FASE 7 — RECUPERACIÓN Y VALIDACIÓN DE AUTO-HEALING"
    info "Inyecta fallo a T+30s → monitorea ALB/ASG hasta restauración completa"
    echo ""

    INSTANCE_IDS=()
    while IFS= read -r id; do [[ -n "$id" ]] && INSTANCE_IDS+=("$id"); done < <(
      aws autoscaling describe-auto-scaling-groups \
      --auto-scaling-group-names "$ASG_NAME" \
      --query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService`].InstanceId' \
      --output text | tr '\t' '\n')

    local TG_ARN
    TG_ARN=$(aws elbv2 describe-target-groups \
      --query 'TargetGroups[0].TargetGroupArn' --output text)
    local VICTIM="${INSTANCE_IDS[0]}"

    info "Víctima: $VICTIM"
    info "Iniciando load test en background..."
    echo ""
    echo -e "  ${YELLOW}▶ $PYTHON3 $LOAD_SCRIPT --config $LOAD_CONFIG --output $OUT &${RESET}"
    echo ""

    $PYTHON3 "$LOAD_SCRIPT" --config "$LOAD_CONFIG" --output "$OUT" &
    local LOAD_PID=$!
    info "Load test PID: $LOAD_PID"
    echo ""
    progress_bar 30 "Esperando T+30s para inyectar fallo..."
    echo ""

    echo ""
    echo -e "  ${RED}${BOLD}▶ aws ec2 stop-instances --instance-ids $VICTIM${RESET}"
    local FAULT_TS
    FAULT_TS=$(date +%s)
    aws ec2 stop-instances --instance-ids "$VICTIM" --output text > /dev/null
    echo -e "  ${RED}✘  FALLO INYECTADO: $VICTIM a las $(date '+%H:%M:%S')${RESET}"
    echo ""

    section "Monitoreando recuperación (máx 5 min)"
    echo -e "  ${DIM}Tiempo   │ ALB Healthy │ ASG InService │ Evento${RESET}"
    echo -e "  ${DIM}─────────┼─────────────┼───────────────┼──────────────────────${RESET}"

    local RECOVERED=false
    local RECOVER_ELAPSED=""
    local DEADLINE=$(( FAULT_TS + 360 ))

    while [[ $(date +%s) -lt $DEADLINE ]]; do
        local NOW
        NOW=$(date +%s)
        local ELAPSED=$(( NOW - FAULT_TS ))

        local HEALTHY
        HEALTHY=$(aws elbv2 describe-target-health \
          --target-group-arn "$TG_ARN" \
          --query 'TargetHealthDescriptions[?TargetHealth.State==`healthy`] | length(@)' \
          --output text 2>/dev/null || echo "?")

        local ASG_COUNT
        ASG_COUNT=$(aws autoscaling describe-auto-scaling-groups \
          --auto-scaling-group-names "$ASG_NAME" \
          --query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService`] | length(@)' \
          --output text 2>/dev/null || echo "?")

        local EVENT=""
        local LINE_COLOR="$RESET"

        if [[ "$HEALTHY" == "3" ]] && [[ "$RECOVERED" == "false" ]]; then
            RECOVERED=true
            RECOVER_ELAPSED=$ELAPSED
            EVENT="${GREEN}◀ RECUPERACIÓN COMPLETA${RESET}"
            LINE_COLOR="$GREEN"
        elif [[ "$HEALTHY" == "2" ]] && [[ $ELAPSED -lt 30 ]]; then
            EVENT="${RED}✘ fallo detectado por ALB${RESET}"
        elif [[ "$ASG_COUNT" != "3" ]]; then
            EVENT="${YELLOW}⟳ ASG ajustando...${RESET}"
        fi

        printf "  ${LINE_COLOR}T+%3ds   │     %s       │       %s         │ %b${RESET}\n" \
          "$ELAPSED" "$HEALTHY" "$ASG_COUNT" "$EVENT"

        [[ "$RECOVERED" == "true" ]] && break
        sleep 5
    done

    echo ""
    if [[ "$RECOVERED" == "true" ]]; then
        ok "Recuperación completa en T+${RECOVER_ELAPSED}s"
        [[ $RECOVER_ELAPSED -lt 60 ]] \
          && ok "Objetivo <60s: CUMPLIDO" \
          || warn "Objetivo <60s: NO CUMPLIDO (${RECOVER_ELAPSED}s — cuello de botella: boot de EC2)"
    else
        warn "No se recuperó a 3 hosts sanos en el tiempo de espera"
    fi

    echo ""
    wait_with_bar "$LOAD_PID" 220 "Fase 7 — load test finalizando..."

    show_results "$OUT" "Fase 7 — Recuperación"
    pause
}

# ── Ver resultados guardados ──────────────────────────────────────────────────
ver_resultados() {
    section "RESULTADOS GUARDADOS"

    # Arrays paralelos (bash 3.2 compatible — sin declare -A)
    local LABELS=("Fase 2 – Baseline" "Fase 3 – Fallo A" "Fase 4 – Fallo B" "Fase 5 – Fallo API" "Fase 7 – Recuperación")
    local FILES=("results_baseline_demo.csv" "results_fault_a_demo.csv" "results_fault_b_final.csv" "results_fault_api_final.csv" "fase7_recovery.csv")

    local i
    for (( i=0; i<${#LABELS[@]}; i++ )); do
        local FILE="$LOAD_TEST_DIR/${FILES[$i]}"
        if [[ -f "$FILE" ]]; then
            show_results "$FILE" "${LABELS[$i]}"
        else
            warn "${LABELS[$i]} — sin datos (${FILES[$i]} no encontrado)"
        fi
    done

    echo ""
    echo -e "${BOLD}  RESUMEN COMPARATIVO${RESET}"
    echo -e "  ${DIM}Fase                │ Disponibilidad │ Objetivo   │ Estado${RESET}"
    echo -e "  ${DIM}────────────────────┼────────────────┼────────────┼──────────${RESET}"
    $PYTHON3 - "$LOAD_TEST_DIR" << 'PYEOF'
import csv, os, sys
base = sys.argv[1]
GREEN = '\033[0;32m'; RED = '\033[0;31m'; RESET = '\033[0m'; BOLD = '\033[1m'

def avail(path):
    try:
        with open(path) as f:
            rows = list(csv.DictReader(f))
        ok = sum(1 for r in rows if 200 <= int(r['status']) < 300)
        return ok / len(rows) * 100 if rows else None
    except:
        return None

phases = [
    ("Fase 2 – Baseline",    "results_baseline_demo.csv",    99.5, "≥ 99.5 %"),
    ("Fase 3 – Fallo A",     "results_fault_a_demo.csv",     96.5, "≥ 96.5%"),
    ("Fase 4 – Fallo B",     "results_fault_b_final.csv",    96.5, "≥ 96.5%"),
    ("Fase 5 – Fallo API",   "results_fault_api_final.csv",  96.5, "≥ 96.5%"),
    ("Fase 7 – Recuperación","fase7_recovery.csv",            96.5, "≥ 96.5%"),
]
for label, fname, thr, obj in phases:
    a = avail(os.path.join(base, fname))
    if a is None:
        print(f"  {label:<20}│ {'sin datos':>14} │ {obj:>10} │  —")
    else:
        color  = GREEN if a >= thr else RED
        status = f"{GREEN}✅ Cumple{RESET}" if a >= thr else f"{RED}✘ No cumple{RESET}"
        print(f"  {label:<20}│ {color}{BOLD}{a:>12.2f} %{RESET} │ {obj:>10} │  {status}")
PYEOF

    # Generar Excel y abrirlo
    local XLSX="$ROOT/docs/resultados_experimento.xlsx"
    echo ""
    info "Generando Excel con resultados por fase..."
    echo -e "  ${YELLOW}▶ python3 → $XLSX${RESET}"
    $PYTHON3 - "$LOAD_TEST_DIR" "$XLSX" << 'PYEOF'
import csv, os, sys
from openpyxl import Workbook
from openpyxl.styles import (Font, PatternFill, Alignment, Border, Side,
                              numbers)
from openpyxl.utils import get_column_letter

BASE  = sys.argv[1]
OUT   = sys.argv[2]

# ── Paleta ────────────────────────────────────────────────────────────────────
C_HEADER   = "1F4978"   # azul oscuro
C_HEADER2  = "2E74B5"   # azul medio
C_OK       = "C6EFCE"   # verde claro
C_OK_F     = "276221"
C_WARN     = "FFEB9C"   # amarillo
C_WARN_F   = "9C5700"
C_ERR      = "FFC7CE"   # rojo claro
C_ERR_F    = "9C0006"
C_ALT      = "DEEAF1"   # azul muy claro (fila alterna)
C_TITLE    = "F2F7FB"

def hdr_fill(color): return PatternFill("solid", fgColor=color)
def thin_border():
    s = Side(style="thin", color="AAAAAA")
    return Border(left=s, right=s, top=s, bottom=s)
def bold(size=11, color="000000", white=False):
    return Font(bold=True, size=size, color="FFFFFF" if white else color)
def center(): return Alignment(horizontal="center", vertical="center", wrap_text=True)
def left():   return Alignment(horizontal="left",   vertical="center", wrap_text=True)

def style_cell(cell, fill=None, font=None, align=None, border=True):
    if fill:   cell.fill   = fill
    if font:   cell.font   = font
    if align:  cell.alignment = align
    if border: cell.border = thin_border()

def analyze(path):
    try:
        with open(path) as f:
            rows = list(csv.DictReader(f))
        if not rows: return None
        total = len(rows)
        ok    = sum(1 for r in rows if 200 <= int(r["status"]) < 300)
        e5xx  = sum(1 for r in rows if 500 <= int(r["status"]) < 600)
        e504  = sum(1 for r in rows if int(r["status"]) == 504)
        lats  = sorted(float(r["latency_ms"]) for r in rows)
        n     = len(lats)
        return {
            "total": total, "ok": ok, "e5xx": e5xx, "e504": e504,
            "avail": ok / total * 100,
            "p50": lats[int(n*0.50)], "p95": lats[int(n*0.95)], "p99": lats[int(n*0.99)],
            "rows": rows,
        }
    except Exception as e:
        return None

phases = [
    ("Fase 2 – Baseline",     "results_baseline_demo.csv",    99.5, "≥ 99.5 %"),
    ("Fase 3 – Fallo A",      "results_fault_a_demo.csv",     96.5, "≥ 96.5 %"),
    ("Fase 4 – Fallo B",      "results_fault_b_final.csv",    96.5, "≥ 96.5 %"),
    ("Fase 5 – Fallo API",    "results_fault_api_final.csv",  96.5, "≥ 96.5 %"),
    ("Fase 7 – Recuperación", "fase7_recovery.csv",            96.5, "≥ 96.5 %"),
]

wb = Workbook()
wb.remove(wb.active)   # quitar hoja vacía default

# ══════════════════════════════════════════════════════════════════════════════
# HOJA 1: RESUMEN
# ══════════════════════════════════════════════════════════════════════════════
ws = wb.create_sheet("Resumen")
ws.sheet_view.showGridLines = False

# Título
ws.merge_cells("A1:I1")
t = ws["A1"]
t.value = "Experimento ASR — Disponibilidad BITE.co"
style_cell(t, fill=hdr_fill(C_HEADER), font=bold(14, white=True), align=center(), border=False)
ws.row_dimensions[1].height = 32

ws.merge_cells("A2:I2")
t2 = ws["A2"]
t2.value = "AWS Academy · us-east-1 · Universidad de los Andes"
style_cell(t2, fill=hdr_fill("2E74B5"), font=Font(italic=True, color="FFFFFF", size=10),
           align=center(), border=False)
ws.row_dimensions[2].height = 18

ws.append([])   # fila 3 vacía

# Encabezados tabla resumen
headers = ["Fase", "Descripción", "Requests", "Éxitos", "Errores 5xx",
           "Timeouts", "Disponibilidad", "Objetivo", "Estado"]
ws.append(headers)
for col, _ in enumerate(headers, 1):
    c = ws.cell(row=4, column=col)
    style_cell(c, fill=hdr_fill(C_HEADER2), font=bold(10, white=True), align=center())
ws.row_dimensions[4].height = 20

# Filas de datos
for i, (label, fname, thr, obj) in enumerate(phases):
    d = analyze(os.path.join(BASE, fname))
    row_n = 5 + i
    if d:
        avail_ok = d["avail"] >= thr
        estado   = "✅ Cumple" if avail_ok else "✘ No cumple"
        row = [label, fname.replace(".csv",""), d["total"], d["ok"],
               d["e5xx"], d["e504"], round(d["avail"], 2), obj, estado]
    else:
        row = [label, fname.replace(".csv",""), "—","—","—","—","—", obj, "sin datos"]
        avail_ok = None

    ws.append(row)
    fill_row = hdr_fill(C_ALT) if i % 2 else PatternFill()

    for col in range(1, 10):
        c = ws.cell(row=row_n, column=col)
        style_cell(c, fill=fill_row, align=center() if col > 1 else left())

    # Colorear disponibilidad
    avail_cell  = ws.cell(row=row_n, column=7)
    estado_cell = ws.cell(row=row_n, column=9)
    if avail_ok is True:
        avail_cell.fill  = hdr_fill(C_OK);  avail_cell.font  = Font(color=C_OK_F, bold=True)
        estado_cell.fill = hdr_fill(C_OK);  estado_cell.font = Font(color=C_OK_F, bold=True)
    elif avail_ok is False:
        avail_cell.fill  = hdr_fill(C_ERR); avail_cell.font  = Font(color=C_ERR_F, bold=True)
        estado_cell.fill = hdr_fill(C_ERR); estado_cell.font = Font(color=C_ERR_F, bold=True)

ws.row_dimensions[row_n].height = 18

# Anchos columnas resumen
for col, w in zip("ABCDEFGHI", [22, 28, 12, 12, 12, 12, 16, 12, 14]):
    ws.column_dimensions[col].width = w

# ══════════════════════════════════════════════════════════════════════════════
# HOJAS POR FASE
# ══════════════════════════════════════════════════════════════════════════════
for label, fname, thr, obj in phases:
    d = analyze(os.path.join(BASE, fname))
    short = label.split("–")[0].strip()   # "Fase 2 ", "Fase 3 "…
    ws2 = wb.create_sheet(short.strip())
    ws2.sheet_view.showGridLines = False

    # ── Cabecera ──────────────────────────────────────────────────────────────
    ws2.merge_cells("A1:F1")
    h = ws2["A1"]
    h.value = label
    style_cell(h, fill=hdr_fill(C_HEADER), font=bold(13, white=True),
               align=center(), border=False)
    ws2.row_dimensions[1].height = 28

    if d is None:
        ws2["A3"].value = "Sin datos — ejecuta esta fase primero."
        ws2["A3"].font  = Font(italic=True, color="888888")
        continue

    # ── Métricas resumen ──────────────────────────────────────────────────────
    metrics = [
        ("Total requests",   f"{d['total']:,}",        None),
        ("Éxitos (2xx)",     f"{d['ok']:,}",            C_OK),
        ("Errores 5xx",      str(d["e5xx"]),            C_ERR if d["e5xx"] else None),
        ("Timeouts (504)",   str(d["e504"]),            C_WARN if d["e504"] else None),
        ("Disponibilidad",   f"{d['avail']:.2f} %",    C_OK if d["avail"] >= thr else C_ERR),
        ("Objetivo",         obj,                       None),
        ("Latencia p50",     f"{d['p50']:.0f} ms",     None),
        ("Latencia p95",     f"{d['p95']:.0f} ms",     None),
        ("Latencia p99",     f"{d['p99']:.0f} ms",     None),
    ]
    ws2.append([])  # row 2
    ws2.merge_cells("A2:B2")
    ws2["A2"].value = "Métricas de la prueba"
    style_cell(ws2["A2"], fill=hdr_fill(C_HEADER2), font=bold(10, white=True), align=center())
    ws2.merge_cells("C2:F2")

    for j, (key, val, color) in enumerate(metrics):
        r = 3 + j
        kc = ws2.cell(row=r, column=1, value=key)
        vc = ws2.cell(row=r, column=2, value=val)
        style_cell(kc, fill=hdr_fill("E9EFF7"), font=Font(bold=True, size=10), align=left())
        fill = hdr_fill(color) if color else PatternFill()
        style_cell(vc, fill=fill, align=center())
        ws2.row_dimensions[r].height = 16

    # ── Separador ──────────────────────────────────────────────────────────────
    sep_row = 3 + len(metrics) + 1
    ws2.merge_cells(f"A{sep_row}:F{sep_row}")
    sep = ws2[f"A{sep_row}"]
    sep.value = "Detalle de solicitudes (muestra 2000 filas)"
    style_cell(sep, fill=hdr_fill(C_HEADER2), font=bold(10, white=True), align=center())
    ws2.row_dimensions[sep_row].height = 18

    # ── Encabezados CSV ────────────────────────────────────────────────────────
    csv_hdr_row = sep_row + 1
    for ci, col_name in enumerate(["Timestamp", "Endpoint", "Status", "Latencia (ms)"], 1):
        c = ws2.cell(row=csv_hdr_row, column=ci, value=col_name)
        style_cell(c, fill=hdr_fill("4472C4"), font=bold(9, white=True), align=center())
    ws2.row_dimensions[csv_hdr_row].height = 16

    # ── Datos (máx 2000 filas para no inflar el archivo) ──────────────────────
    sample = d["rows"][:2000]
    for ri, row in enumerate(sample):
        r = csv_hdr_row + 1 + ri
        status = int(row["status"])
        fill_r = hdr_fill(C_ALT) if ri % 2 else PatternFill()
        if 200 <= status < 300:
            s_fill = hdr_fill(C_OK)
        elif status in (504, 0):
            s_fill = hdr_fill(C_WARN)
        else:
            s_fill = hdr_fill(C_ERR)

        vals = [row["timestamp"], row["endpoint"], status, float(row["latency_ms"])]
        for ci, val in enumerate(vals, 1):
            c = ws2.cell(row=r, column=ci, value=val)
            c.fill   = s_fill if ci == 3 else fill_r
            c.border = thin_border()
            c.alignment = center() if ci in (2,3,4) else left()
            c.font = Font(size=9)

    # Anchos columnas fase
    for col, w in zip("ABCDEF", [26, 18, 10, 16]):
        ws2.column_dimensions[col].width = w

wb.save(OUT)
print(f"Excel guardado: {OUT}")
PYEOF

    if [[ -f "$XLSX" ]]; then
        ok "Excel generado: $(basename "$XLSX")"
        echo -e "  ${YELLOW}▶ open \"$XLSX\"${RESET}"
        open "$XLSX"
    else
        warn "No se pudo generar el Excel"
    fi

    pause
}

# ════════════════════════════════════════════════════════════════════════════
# MENÚ PRINCIPAL
# ════════════════════════════════════════════════════════════════════════════
header() {
    clear
    echo ""
    echo -e "${BG_DARK}${WHITE}${BOLD}"
    echo "  ╔══════════════════════════════════════════════════════════╗"
    echo "  ║       EXPERIMENTO ASR — DISPONIBILIDAD BITE.co           ║"
    echo "  ║       AWS Academy · us-east-1 · Universidad de los Andes ║"
    echo "  ╚══════════════════════════════════════════════════════════╝"
    echo -e "${RESET}"

    if [[ -n "${AWS_ACCESS_KEY_ID:-}" ]]; then
        echo -e "  ${GREEN}● Credenciales AWS configuradas${RESET}"
    else
        echo -e "  ${RED}● Sin credenciales AWS — selecciona opción 0 primero${RESET}"
    fi
    echo ""
    echo -e "  ${BOLD}Selecciona una fase:${RESET}"
    echo ""
    echo -e "  ${CYAN}[0]${RESET} Configurar credenciales AWS Academy"
    echo -e "  ${CYAN}[1]${RESET} Verificar infraestructura (instancias, ALB, threads)"
    echo -e "  ${CYAN}[t]${RESET} Aplicar --threads 25 a todas las instancias"
    echo -e "  ${CYAN}[2]${RESET} Fase 2 — Baseline (sin fallos)"
    echo -e "  ${CYAN}[3]${RESET} Fase 3 — Fallo A: 1 instancia detenida"
    echo -e "  ${CYAN}[4]${RESET} Fase 4 — Fallo B: 2 instancias detenidas"
    echo -e "  ${CYAN}[5]${RESET} Fase 5 — Fallo API externa (Cost Explorer)"
    echo -e "  ${CYAN}[7]${RESET} Fase 7 — Recuperación y auto-healing"
    echo -e "  ${CYAN}[r]${RESET} Ver todos los resultados guardados"
    echo -e "  ${CYAN}[q]${RESET} Salir"
    echo ""
    echo -n "  Opción: "
}

main() {
    while true; do
        header
        read -r OPT

        case "$OPT" in
            0) configurar_credenciales ;;
            1) fase_verificar ;;
            t) aplicar_threads; pause ;;
            2) fase_baseline ;;
            3) fase_fallo_a ;;
            4) fase_fallo_b ;;
            5) fase_fallo_api ;;
            7) fase_recuperacion ;;
            r) ver_resultados ;;
            q|Q)
                echo ""
                echo -e "  ${CYAN}Hasta luego.${RESET}"
                echo ""
                exit 0
                ;;
            *)
                warn "Opción no reconocida: '$OPT'"
                sleep 1
                ;;
        esac
    done
}

main
