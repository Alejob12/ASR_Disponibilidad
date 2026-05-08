"""
Calcula la disponibilidad del experimento a partir de los resultados del
script de carga (CSV) y las metricas de CloudWatch (JSON).

Uso:
    python calculate_availability.py --results load_test/results.csv \
        --unhealthy monitoring/metrics/unhealthy_hosts.json \
        --errors monitoring/metrics/5xx_errors.json
"""

import argparse
import csv
import json
from datetime import datetime, timezone


# ── Helpers ────────────────────────────────────────────────────────────────

def load_csv(path: str) -> list[dict]:
    with open(path, newline="") as f:
        return list(csv.DictReader(f))


def load_json_datapoints(path: str) -> list[dict]:
    with open(path) as f:
        data = json.load(f)
    return sorted(data.get("Datapoints", []), key=lambda d: d["Timestamp"])


def parse_ts(ts_str: str) -> datetime:
    return datetime.fromisoformat(ts_str.replace("Z", "+00:00"))


# ── Analisis desde el CSV de prueba de carga ───────────────────────────────

def analyze_load_results(rows: list[dict]) -> dict:
    total = len(rows)
    if total == 0:
        return {}

    success = sum(1 for r in rows if 200 <= int(r["status"]) < 300)
    errors_5xx = sum(1 for r in rows if 500 <= int(r["status"]) < 600)
    timeout_or_unreachable = sum(1 for r in rows if int(r["status"]) in (0, 504))
    latencies = [float(r["latency_ms"]) for r in rows]
    latencies.sort()

    n = len(latencies)
    availability_pct = success / total * 100

    timestamps = [parse_ts(r["timestamp"]) for r in rows]
    test_duration_s = (max(timestamps) - min(timestamps)).total_seconds()
    downtime_s = (total - success) / total * test_duration_s if total else 0

    return {
        "total_requests": total,
        "success": success,
        "errors_5xx": errors_5xx,
        "timeout_or_unreachable": timeout_or_unreachable,
        "availability_pct": round(availability_pct, 4),
        "meets_sla_995": availability_pct >= 99.5,
        "test_duration_seconds": round(test_duration_s, 1),
        "estimated_downtime_seconds": round(downtime_s, 2),
        "p50_latency_ms": round(latencies[int(n * 0.50)], 2) if n else 0,
        "p95_latency_ms": round(latencies[int(n * 0.95)], 2) if n else 0,
        "p99_latency_ms": round(latencies[int(n * 0.99)], 2) if n else 0,
    }


# ── Analisis desde CloudWatch: tiempo de instancia unhealthy ───────────────

def analyze_unhealthy_window(datapoints: list[dict], period_seconds: int = 5) -> dict:
    unhealthy_periods = [d for d in datapoints if d.get("Maximum", 0) > 0]
    total_unhealthy_s = len(unhealthy_periods) * period_seconds

    if unhealthy_periods:
        first = parse_ts(unhealthy_periods[0]["Timestamp"])
        last = parse_ts(unhealthy_periods[-1]["Timestamp"])
        window_s = (last - first).total_seconds() + period_seconds
    else:
        window_s = 0

    return {
        "unhealthy_datapoints": len(unhealthy_periods),
        "estimated_unhealthy_seconds": total_unhealthy_s,
        "fault_window_seconds": round(window_s, 1),
        "meets_rto_60s": window_s <= 60,
    }


# ── Main ───────────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--results", required=True, help="CSV de la prueba de carga")
    parser.add_argument("--unhealthy", required=True, help="JSON de UnHealthyHostCount")
    parser.add_argument("--errors", help="JSON de HTTPCode_Target_5XX_Count")
    args = parser.parse_args()

    rows = load_csv(args.results)
    load_stats = analyze_load_results(rows)

    unhealthy_dps = load_json_datapoints(args.unhealthy)
    recovery_stats = analyze_unhealthy_window(unhealthy_dps)

    print("\n=== DISPONIBILIDAD (desde prueba de carga) ===")
    for k, v in load_stats.items():
        flag = " <<< NO CUMPLE SLA" if k == "meets_sla_995" and not v else ""
        print(f"  {k}: {v}{flag}")

    print("\n=== TIEMPO DE RECUPERACION (desde CloudWatch) ===")
    for k, v in recovery_stats.items():
        flag = " <<< SUPERA RTO" if k == "meets_rto_60s" and not v else ""
        print(f"  {k}: {v}{flag}")

    # Disponibilidad mensual proyectada
    if load_stats.get("test_duration_seconds", 0) > 0:
        monthly_s = 30 * 24 * 3600
        downtime_ratio = load_stats["estimated_downtime_seconds"] / load_stats["test_duration_seconds"]
        projected_monthly_downtime = downtime_ratio * monthly_s
        projected_availability = (1 - downtime_ratio) * 100
        print(f"\n=== PROYECCION MENSUAL ===")
        print(f"  Inactividad mensual proyectada: {round(projected_monthly_downtime / 3600, 2)} horas")
        print(f"  Disponibilidad mensual proyectada: {round(projected_availability, 4)}%")
        print(f"  Cumple 99.5% SLA: {projected_availability >= 99.5}")


if __name__ == "__main__":
    main()
