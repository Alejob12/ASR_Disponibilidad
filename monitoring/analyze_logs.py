"""
Analiza el historial de actividades del ASG exportado por collect_metrics.sh
para identificar tiempos exactos de deteccion y recuperacion de fallos.

Uso:
    python analyze_logs.py --asg-activities monitoring/metrics/asg_activities.json
"""

import argparse
import json
from datetime import datetime


def parse_ts(ts_str: str) -> datetime:
    return datetime.fromisoformat(ts_str.replace("Z", "+00:00"))


def analyze_asg_activities(path: str) -> None:
    with open(path) as f:
        data = json.load(f)

    activities = sorted(
        data.get("Activities", []),
        key=lambda a: a["StartTime"],
    )

    print(f"Total actividades ASG: {len(activities)}\n")
    print(f"{'Inicio':<30} {'Fin':<30} {'Duracion':>12}  Descripcion")
    print("-" * 110)

    for act in activities:
        start = parse_ts(act["StartTime"])
        end_str = act.get("EndTime", "")
        end = parse_ts(end_str) if end_str else None
        duration = f"{(end - start).total_seconds():.0f}s" if end else "en curso"
        desc = act.get("Description", "")[:60]
        status = act.get("StatusCode", "")
        print(f"{act['StartTime']:<30} {end_str or '-':<30} {duration:>12}  [{status}] {desc}")

    # Detectar lanzamientos de reemplazo (recuperacion)
    launches = [a for a in activities if "Launching" in a.get("Description", "")]
    terminations = [a for a in activities if "Terminating" in a.get("Description", "")]

    if launches:
        print(f"\nLanzamientos de reemplazo detectados: {len(launches)}")
        for l in launches:
            end_str = l.get("EndTime", "")
            if end_str:
                duration = (parse_ts(end_str) - parse_ts(l["StartTime"])).total_seconds()
                print(f"  {l['StartTime']} -> {end_str}  ({duration:.0f}s)  {l['Description'][:60]}")

    if terminations:
        print(f"\nTerminaciones detectadas: {len(terminations)}")
        for t in terminations:
            print(f"  {t['StartTime']}  {t['Description'][:60]}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--asg-activities", required=True)
    args = parser.parse_args()
    analyze_asg_activities(args.asg_activities)


if __name__ == "__main__":
    main()
