# ASR Disponibilidad — BITE.co | AWS Academy

> Arquitectura de Software · Universidad de los Andes

Experimento de validación de disponibilidad del **99,5 %** y recuperación en menos de **60 segundos** ante fallo de instancia EC2, usando EC2 + ALB + Auto Scaling Group en AWS Academy.

---

## Tabla de contenidos / Table of Contents

- [Español](#español)
- [English](#english)

---

# Español

## Descripción general

Este proyecto implementa y valida el ASR (Architecturally Significant Requirement) de disponibilidad de la plataforma BITE.co. El experimento despliega una aplicación Python sobre instancias EC2 detrás de un Application Load Balancer y un Auto Scaling Group, inyecta fallos controlados y mide si la arquitectura cumple el SLA definido.

**Métricas objetivo:**

| Métrica | Valor esperado |
|---|---|
| Disponibilidad mensual | ≥ 99,5 % |
| Tiempo de recuperación (RTO) | < 60 segundos |
| Detección de fallo por ALB | < 15 segundos |
| Solicitudes perdidas durante el fallo | Mínimas |
| Degradación perceptible para el usuario | Ninguna mientras existan instancias sanas |
| Fallback ante fallo de API externa | Respuesta en < 5 segundos |

---

## Estructura del proyecto

```
ASR_Disponibilidad/
├── app/                          ← Aplicación Python (Flask) en EC2
│   ├── main.py
│   ├── requirements.txt
│   ├── routes/
│   │   ├── health.py             ← GET /health  (usado por el ALB Health Check)
│   │   ├── auth.py               ← POST /auth/login · GET /auth/validate
│   │   └── costs.py              ← GET /costs/summary · POST /costs/report
│   ├── services/
│   │   ├── cloud_connector.py    ← Integración con AWS Cost Explorer + fallback
│   │   └── report_service.py     ← Generación de reportes async → S3 → SES
│   └── utils/
│       └── fallback.py           ← call_with_fallback(fn, fallback, timeout)
├── infra/
│   ├── cloudformation/
│   │   ├── ec2_asg_alb.yaml      ← ALB + ASG (mín 2, máx 4) + Health Check 5 s
│   │   ├── rds.yaml              ← RDS PostgreSQL db.t2.micro
│   │   └── s3_cloudwatch.yaml    ← Bucket S3 + alarmas CloudWatch (CPU/5xx/unhealthy)
│   └── scripts/
│       ├── deploy.sh             ← Despliega las 3 stacks en orden
│       └── user_data.sh          ← Bootstrap de EC2: instala dependencias e inicia gunicorn
├── load_test/
│   ├── config.json               ← URL del ALB, endpoints, usuarios concurrentes
│   └── load_test.py              ← Simula 50-100 usuarios · guarda resultados en CSV
├── fault_injection/
│   ├── inject_fault_a.sh         ← Fallo A: detiene 1 instancia EC2
│   ├── inject_fault_b.sh         ← Fallo B: detiene 2 instancias simultáneas
│   └── block_external_api.sh     ← Fallo C: bloquea API externa vía Security Group
├── monitoring/
│   ├── collect_metrics.sh        ← Exporta métricas de CloudWatch a JSON
│   ├── analyze_logs.py           ← Analiza actividades del ASG y mide RTO real
│   └── calculate_availability.py ← Calcula disponibilidad % y proyección mensual
└── .env.example                  ← Variables de entorno requeridas
```

---

## Descripción de cada carpeta

### `app/`
La aplicación Python que corre en cada instancia EC2. Es el corazón del experimento: recibe las peticiones HTTP de los usuarios y es lo que el ALB balancea y monitorea con health checks.

- **routes/** — Los endpoints HTTP: login, validación de token, consulta de costos y el `/health` que usa el ALB para saber si la instancia está viva.
- **services/** — La lógica de negocio: conectarse a AWS para obtener costos, generar reportes en segundo plano (async) y subirlos a S3.
- **utils/** — El mecanismo de `fallback` que evita que un timeout de API externa bloquee al usuario.

### `infra/`
Todo lo necesario para levantar la infraestructura en AWS Academy desde cero.

- **cloudformation/** — Las plantillas YAML que crean los recursos AWS: ALB + ASG + EC2, la base de datos RDS y el bucket S3 con las alarmas de CloudWatch.
- **scripts/** — El script de despliegue que lanza las tres plantillas en orden, y el `user_data.sh` que se ejecuta automáticamente cada vez que una EC2 arranca.

### `load_test/`
Simula los usuarios concurrentes durante el experimento. Se ejecuta desde tu máquina (o una EC2 auxiliar) mientras se hace la inyección de fallos, para medir cuántas peticiones fallan y calcular disponibilidad real.

- **config.json** — Define la URL del ALB, cuántos usuarios simular y qué endpoints atacar con qué frecuencia.
- **load_test.py** — Lanza los usuarios en paralelo y guarda cada respuesta (status code, latencia, timestamp) en un CSV.

### `fault_injection/`
Scripts que provocan los fallos controlados del experimento usando AWS CLI. Cada uno corresponde a un escenario del diseño del experimento:

- **inject_fault_a.sh** — Detiene 1 instancia EC2 y espera a que el ASG la reponga (Fallo A).
- **inject_fault_b.sh** — Detiene 2 instancias simultáneamente (Fallo B, escenario más crítico).
- **block_external_api.sh** — Bloquea el tráfico de salida a una IP externa vía Security Group para probar el comportamiento de fallback (Fallo C).

### `monitoring/`
Scripts de observación y análisis: recolectan datos del experimento y calculan si se cumplen los criterios del ASR.

- **collect_metrics.sh** — Descarga métricas de CloudWatch (CPU, hosts unhealthy, errores 5xx, requests) a archivos JSON.
- **analyze_logs.py** — Lee el historial de actividades del ASG para identificar el momento exacto de detección del fallo y lanzamiento del reemplazo (RTO real).
- **calculate_availability.py** — Cruza el CSV del load test con las métricas de CloudWatch y calcula el porcentaje de disponibilidad y la proyección mensual.

---

## Componentes externos requeridos (paso a paso)

1. **VPC y subredes** — Una VPC con al menos 2 subredes públicas en zonas de disponibilidad distintas (el ALB las requiere). Anotar `VPC_ID` y `SUBNET_IDS`.

2. **Key Pair EC2** — Crear un Key Pair en la consola de AWS Academy → EC2 → Key Pairs. Guardar el archivo `.pem` para acceso SSH de diagnóstico.

3. **AMI personalizada** — Lanzar una EC2 base (Amazon Linux 2023), ejecutar `user_data.sh` para instalar la app, y crear una AMI desde esa instancia. Ese `AMI_ID` va en el Launch Template.

4. **RDS PostgreSQL db.t2.micro** — Desplegado con `rds.yaml`. Elegir una contraseña segura (`DB_PASSWORD`) y anotar el endpoint resultante.

5. **ALB + ASG** — Desplegado con `ec2_asg_alb.yaml`. Health Check cada 5 s con umbral de 2 fallos consecutivos (detección < 15 s).

6. **Bucket S3** — Creado automáticamente con `s3_cloudwatch.yaml`. Verificar que la IAM Role de las EC2 tenga permiso `s3:PutObject` sobre ese bucket.

7. **Alarmas CloudWatch** — La misma stack crea alarmas de CPU alta, hosts unhealthy y errores 5xx con notificación por email vía SNS. Confirmar la suscripción al email que llega de AWS.

8. **SES (Simple Email Service)** — Verificar la dirección remitente (`SES_SENDER`) en SES → Verified identities. En Academy (sandbox) también verificar el email destino.

9. **IAM Role para EC2** — Crear un Instance Profile con permisos mínimos: `ce:GetCostAndUsage`, `s3:PutObject` sobre el bucket de reportes, y `ses:SendEmail`. Adjuntarlo al Launch Template.

10. **AWS CLI local** — Instalar y configurar con credenciales de AWS Academy (se renuevan cada sesión). Requerido para los scripts de inyección de fallos y exportación de métricas.

---

## Pasos del experimento

| Paso | Acción |
|---|---|
| 1 | Completar `.env.example` → `.env` y desplegar con `infra/scripts/deploy.sh` |
| 2 | Actualizar `load_test/config.json` con la URL del ALB |
| 3 | Ejecutar `load_test/load_test.py` (carga base, 10 min de estabilización) |
| 4 | Con la carga activa, ejecutar `inject_fault_a.sh` (Fallo A) |
| 5 | Ejecutar `inject_fault_b.sh` (Fallo B — 2 instancias simultáneas) |
| 6 | Ejecutar `block_external_api.sh` (Fallo C — API externa) |
| 7 | Exportar métricas con `monitoring/collect_metrics.sh` |
| 8 | Analizar RTO con `monitoring/analyze_logs.py` |
| 9 | Calcular disponibilidad con `monitoring/calculate_availability.py` |

---

---

# English

## Overview

This project implements and validates the Availability ASR (Architecturally Significant Requirement) for the BITE.co platform. The experiment deploys a Python application on EC2 instances behind an Application Load Balancer and Auto Scaling Group, injects controlled failures, and measures whether the architecture meets the defined SLA.

**Target metrics:**

| Metric | Expected value |
|---|---|
| Monthly availability | ≥ 99.5% |
| Recovery time (RTO) | < 60 seconds |
| ALB failure detection | < 15 seconds |
| Requests lost during failure | Minimal |
| User-perceivable degradation | None while healthy instances exist |
| Fallback on external API failure | Response in < 5 seconds |

---

## Project structure

```
ASR_Disponibilidad/
├── app/                          ← Python (Flask) application running on EC2
│   ├── main.py
│   ├── requirements.txt
│   ├── routes/
│   │   ├── health.py             ← GET /health  (used by ALB Health Check)
│   │   ├── auth.py               ← POST /auth/login · GET /auth/validate
│   │   └── costs.py              ← GET /costs/summary · POST /costs/report
│   ├── services/
│   │   ├── cloud_connector.py    ← AWS Cost Explorer integration + fallback
│   │   └── report_service.py     ← Async report generation → S3 → SES
│   └── utils/
│       └── fallback.py           ← call_with_fallback(fn, fallback, timeout)
├── infra/
│   ├── cloudformation/
│   │   ├── ec2_asg_alb.yaml      ← ALB + ASG (min 2, max 4) + 5 s Health Check
│   │   ├── rds.yaml              ← RDS PostgreSQL db.t2.micro
│   │   └── s3_cloudwatch.yaml    ← S3 bucket + CloudWatch alarms (CPU/5xx/unhealthy)
│   └── scripts/
│       ├── deploy.sh             ← Deploys the 3 stacks in order
│       └── user_data.sh          ← EC2 bootstrap: installs dependencies and starts gunicorn
├── load_test/
│   ├── config.json               ← ALB URL, endpoints, concurrent users
│   └── load_test.py              ← Simulates 50-100 users · saves results to CSV
├── fault_injection/
│   ├── inject_fault_a.sh         ← Failure A: stops 1 EC2 instance
│   ├── inject_fault_b.sh         ← Failure B: stops 2 instances simultaneously
│   └── block_external_api.sh     ← Failure C: blocks external API via Security Group
├── monitoring/
│   ├── collect_metrics.sh        ← Exports CloudWatch metrics to JSON
│   ├── analyze_logs.py           ← Parses ASG activity log and measures real RTO
│   └── calculate_availability.py ← Calculates availability % and monthly projection
└── .env.example                  ← Required environment variables
```

---

## Folder descriptions

### `app/`
The Python application running on each EC2 instance. It is the core of the experiment: it handles user HTTP requests and is what the ALB load-balances and monitors via health checks.

- **routes/** — HTTP endpoints: login, token validation, cost queries, and the `/health` endpoint the ALB uses to determine if an instance is alive.
- **services/** — Business logic: fetching costs from AWS, generating reports asynchronously in the background, and uploading them to S3.
- **utils/** — The `fallback` mechanism that prevents an external API timeout from blocking the user.

### `infra/`
Everything needed to provision the infrastructure on AWS Academy from scratch.

- **cloudformation/** — YAML templates that create the AWS resources: ALB + ASG + EC2, the RDS database, and the S3 bucket with CloudWatch alarms.
- **scripts/** — The deploy script that launches the three stacks in order, and `user_data.sh` which runs automatically every time an EC2 starts.

### `load_test/`
Simulates concurrent users during the experiment. Runs from your local machine (or an auxiliary EC2) while fault injection is happening, to measure how many requests fail and calculate real availability.

- **config.json** — Defines the ALB URL, number of users to simulate, and which endpoints to hit and at what rate.
- **load_test.py** — Spawns users in parallel threads and saves each response (status code, latency, timestamp) to a CSV.

### `fault_injection/`
Scripts that trigger controlled failures using the AWS CLI. Each one corresponds to a scenario from the experiment design:

- **inject_fault_a.sh** — Stops 1 EC2 instance and waits for the ASG to replace it (Failure A).
- **inject_fault_b.sh** — Stops 2 instances simultaneously (Failure B, more critical scenario).
- **block_external_api.sh** — Blocks outbound traffic to an external IP via Security Group to test fallback behavior (Failure C).

### `monitoring/`
Observation and analysis scripts: collect experiment data and verify whether the ASR criteria are met.

- **collect_metrics.sh** — Downloads CloudWatch metrics (CPU, unhealthy hosts, 5xx errors, request count) to JSON files.
- **analyze_logs.py** — Reads the ASG activity history to identify the exact moment of failure detection and replacement launch (real RTO).
- **calculate_availability.py** — Combines the load test CSV with CloudWatch metrics to compute availability percentage and monthly projection.

---

## External components required (step by step)

1. **VPC and subnets** — A VPC with at least 2 public subnets in different availability zones (required by the ALB). Note the `VPC_ID` and `SUBNET_IDS`.

2. **EC2 Key Pair** — Create a Key Pair in the AWS Academy console → EC2 → Key Pairs. Save the `.pem` file for diagnostic SSH access.

3. **Custom AMI** — Launch a base EC2 (Amazon Linux 2023), run `user_data.sh` to install the app, then create an AMI from that instance. That `AMI_ID` goes in the Launch Template.

4. **RDS PostgreSQL db.t2.micro** — Deployed with `rds.yaml`. Choose a secure password (`DB_PASSWORD`) and note the resulting endpoint.

5. **ALB + ASG** — Deployed with `ec2_asg_alb.yaml`. Health Check every 5 s with a threshold of 2 consecutive failures (detection < 15 s).

6. **S3 Bucket** — Created automatically with `s3_cloudwatch.yaml`. Verify that the EC2 IAM Role has `s3:PutObject` permission on that bucket.

7. **CloudWatch alarms** — The same stack creates alarms for high CPU, unhealthy hosts, and 5xx errors with email notification via SNS. Confirm the subscription from the email AWS sends.

8. **SES (Simple Email Service)** — Verify the sender address (`SES_SENDER`) in SES → Verified identities. In Academy (sandbox mode), also verify the destination email.

9. **IAM Role for EC2** — Create an Instance Profile with minimum permissions: `ce:GetCostAndUsage`, `s3:PutObject` on the reports bucket, and `ses:SendEmail`. Attach it to the Launch Template.

10. **Local AWS CLI** — Install and configure with AWS Academy credentials (they refresh each session). Required for fault injection scripts and metrics export.

---

## Experiment steps

| Step | Action |
|---|---|
| 1 | Fill in `.env.example` → `.env` and deploy with `infra/scripts/deploy.sh` |
| 2 | Update `load_test/config.json` with the ALB URL |
| 3 | Run `load_test/load_test.py` (baseline load, 10 min stabilization) |
| 4 | With load active, run `inject_fault_a.sh` (Failure A) |
| 5 | Run `inject_fault_b.sh` (Failure B — 2 simultaneous instances) |
| 6 | Run `block_external_api.sh` (Failure C — external API) |
| 7 | Export metrics with `monitoring/collect_metrics.sh` |
| 8 | Analyze RTO with `monitoring/analyze_logs.py` |
| 9 | Calculate availability with `monitoring/calculate_availability.py` |
