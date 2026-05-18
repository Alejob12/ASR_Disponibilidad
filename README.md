# ASR Disponibilidad — BITE.co en AWS

> **Arquitectura de Software · Universidad de los Andes**  
> Validación experimental del atributo de calidad **Disponibilidad** sobre una plataforma SaaS en AWS

---

## Descripción

Este proyecto valida el ASR (Architecturally Significant Requirement) de disponibilidad de **BITE.co**, una plataforma ficticia de gestión de gastos corporativos. Se despliega infraestructura real en AWS, se inyectan fallos controlados bajo carga activa y se mide si la arquitectura cumple el SLA definido.

### ASR definido

| Campo | Valor |
|-------|-------|
| Fuente de estímulo | Fallo de instancia EC2 en producción |
| Estímulo | Caída de 1 o 2 nodos bajo carga activa (75 usuarios concurrentes) |
| Artefacto | Clúster de aplicación BITE.co |
| Entorno | Operación normal / estrés |
| Respuesta | El sistema redirige tráfico automáticamente y repone instancias |
| **Medida de respuesta** | **Disponibilidad ≥ 96.5 % durante la ventana de fallo** |

### Táctica arquitectónica

**Redundancia activa con detección pasiva (ALB + ASG)**

- Application Load Balancer distribuye tráfico entre 3 instancias EC2 (min 2, max 4)
- Health check cada 5 s, umbral 2 ciclos → detección de fallo en ≈ 10 s
- Auto Scaling Group repone instancias caídas automáticamente
- Gunicorn `-w 4 --threads 25` → 100 conexiones concurrentes por instancia
- Patrón **Fallback** en llamadas a AWS Cost Explorer con timeout 5 s

---

## Resultados del experimento

| Escenario | Disponibilidad medida | Objetivo | Estado |
|-----------|----------------------|----------|--------|
| Baseline (sin fallos) | **100.00 %** | ≥ 96.5 % | ✅ |
| Fallo 1 instancia (33 % capacidad perdida) | **96.44 %** | ≥ 96.5 % | ✅ |
| Fallo 2 instancias (66 % capacidad perdida) | **97.14 %** | ≥ 96.5 % | ✅ |
| Fallo API externa (Cost Explorer) | **100.00 %** | ≥ 96.5 % | ✅ |
| Durante recuperación auto-healing | **98.82 %** | ≥ 96.5 % | ✅ |
| Tiempo restauración completa | 240 s | < 60 s | ⚠️ |

> El cuello de botella en tiempo de recuperación es el cold start de EC2 con UserData (git clone + pip install). No es un fallo del mecanismo ALB/ASG.

---

## Infraestructura

```
Internet
    │
    ▼
[ALB] — health check /health cada 5s
    │
    ├── EC2 t3.micro #1 → Gunicorn + Flask
    ├── EC2 t3.micro #2 → Gunicorn + Flask  →  [RDS PostgreSQL]
    └── EC2 t3.micro #3 → Gunicorn + Flask
                                    │
                                    └── [AWS Cost Explorer] (con Fallback)

[ASG] — vigila instancias, repone automáticamente
[CloudWatch + SNS] — alarmas y notificaciones
```

Desplegada con **AWS CDK (Python)** en `us-east-1`.

| Componente | Configuración |
|------------|---------------|
| ALB | internet-facing, health check /health interval=5s threshold=2 |
| ASG | min=2 desired=3 max=4, ELB health check, grace=60s |
| EC2 | t3.micro, Amazon Linux 2023, Gunicorn -w 4 --threads 25 |
| RDS | PostgreSQL 15, t3.micro, single-AZ |
| S3 | Bucket de reportes, lifecycle 90 días |
| CloudWatch | CPU > 80 %, UnhealthyHosts > 0, HTTP 5xx > 5 |

---

## Estructura del proyecto

```
ASR_Disponibilidad/
│
├── app/                          ← Aplicación Flask que corre en cada EC2
│   ├── main.py                   ← Punto de entrada, registra blueprints
│   ├── requirements.txt
│   ├── routes/
│   │   ├── health.py             ← GET /health (usado por el ALB)
│   │   ├── auth.py               ← POST /auth/login · GET /auth/validate
│   │   └── costs.py              ← GET /costs/summary · POST /costs/report
│   ├── services/
│   │   ├── cloud_connector.py    ← Llama a AWS Cost Explorer con fallback
│   │   └── report_service.py     ← Genera reporte async → S3 → SES
│   └── utils/
│       └── fallback.py           ← Patrón Fallback con timeout configurable
│
├── infra/
│   └── cdk/
│       ├── app.py                ← Punto de entrada CDK, auto-descubre VPC
│       ├── bite_stack.py         ← Stack completo: ALB+ASG+EC2+RDS+S3+CW+SNS
│       ├── config.json           ← Parámetros: región, VPC, subnets, instancia
│       └── requirements.txt
│
├── load_test/
│   ├── load_test.py              ← 75 usuarios async (asyncio + aiohttp)
│   ├── config.json               ← URL del ALB + endpoints + pesos
│   └── results_*.csv             ← Resultados de cada fase del experimento
│
├── scripts/
│   └── experimento.sh            ← Menú interactivo: configura, despliega,
│                                    inyecta fallos, monitorea, genera Excel
│
└── docs/
    ├── informe_asr_disponibilidad.md    ← Informe completo del experimento
    ├── informe_asr_disponibilidad.docx  ← Mismo informe en Word
    └── resultados_experimento.xlsx      ← Resultados por fase con formato
```

---

## Prerrequisitos

- Python 3.11+
- Node.js 18+ (para AWS CDK)
- AWS CLI v2
- AWS CDK CLI: `npm install -g aws-cdk`
- Cuenta AWS con credenciales configuradas

```bash
pip install -r infra/cdk/requirements.txt
pip install aiohttp  # para el load test
```

---

## Despliegue

### 1. Configurar credenciales AWS

```bash
aws configure
# o exportar variables:
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export AWS_DEFAULT_REGION=us-east-1
```

### 2. Bootstrap CDK (primera vez por cuenta/región)

```bash
cd infra/cdk
cdk bootstrap
```

### 3. Desplegar el stack (~10 min)

```bash
cdk deploy --require-approval never
```

Al terminar muestra los outputs:
```
BiteStack.AlbUrl      = http://...us-east-1.elb.amazonaws.com
BiteStack.AsgName     = BiteStack-AsgASGD1D7B4E2-XXXXX
BiteStack.DbSecretArn = arn:aws:secretsmanager:...
```

### 4. Actualizar config del load test

Editar `load_test/config.json` con la URL del ALB del paso anterior.

### 5. Destruir (para no generar costos)

```bash
cdk destroy
```

---

## Script de experimento (recomendado)

El script `scripts/experimento.sh` orquesta todo el experimento con un menú interactivo:

```bash
bash scripts/experimento.sh
```

| Opción | Acción |
|--------|--------|
| `[0]` | Configurar credenciales AWS |
| `[1]` | Verificar infraestructura (instancias, ALB, threads) |
| `[t]` | Aplicar `--threads 25` a Gunicorn via SSM |
| `[2]` | Fase 2 — Baseline (75 usuarios · 250 s · sin fallos) |
| `[3]` | Fase 3 — Fallo A: 1 instancia detenida bajo carga |
| `[4]` | Fase 4 — Fallo B: 2 instancias detenidas simultáneamente |
| `[5]` | Fase 5 — Fallo API externa (Cost Explorer bloqueado) |
| `[7]` | Fase 7 — Recuperación y validación de auto-healing |
| `[r]` | Ver resultados guardados + generar Excel |
| `[q]` | Salir |

Cada fase muestra los comandos AWS que ejecuta en tiempo real y una barra de progreso durante la carga.

---

## Flujo del experimento

```
[0] Credenciales → autenticar sesión AWS
[1] Verificar    → confirmar 3 instancias InService
[t] Threads      → aplicar --threads 25 via SSM (sin SSH)
[2] Baseline     → medir disponibilidad base (debe ser ~100%)
[3] Fallo A      → detener 1 EC2 a T+30s · ALB detecta en ~10s
[4] Fallo B      → detener 2 EC2 simultáneamente · 1 nodo restante
[5] Fallo API    → bloquear Cost Explorer · Fallback absorbe el fallo
[7] Recuperación → monitorear ASG hasta restaurar 3 hosts sanos
[r] Resultados   → Excel con métricas por fase
```

---

## Por qué 250 segundos por prueba

La disponibilidad se calcula como `requests_exitosos / requests_totales`. El fallo del ALB dura **≈10 s fijos** independientemente de la duración total. Con 250 s y 75 usuarios se generan ~15,000 requests — la ventana de fallo representa solo el 4 % del tiempo, proporcional a producción real. Con 60 s, esa misma ventana representaría el 17 % y distorsionaría el resultado.

---

## Documentación

- [Informe completo del experimento](docs/informe_asr_disponibilidad.md)
- [Resultados en Excel](docs/resultados_experimento.xlsx)

---

## Autor

**Alejandro Bernal** — Universidad de los Andes  
Curso: Arquitectura de Software
