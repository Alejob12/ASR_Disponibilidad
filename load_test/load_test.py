"""
Script de prueba de carga para el experimento ASR de Disponibilidad.
Simula usuarios concurrentes contra el ALB y registra errores, latencias
y disponibilidad percibida durante el experimento de inyeccion de fallos.

Uso:
    python load_test.py --config config.json --output results.csv
"""

import argparse
import csv
import json
import random
import threading
import time
from dataclasses import dataclass, field
from datetime import datetime
from typing import Optional

import requests

# ── Resultados thread-safe ─────────────────────────────────────────────────


@dataclass
class Stats:
    total: int = 0
    success: int = 0
    errors_5xx: int = 0
    errors_other: int = 0
    latencies: list = field(default_factory=list)
    _lock: threading.Lock = field(default_factory=threading.Lock)

    def record(self, status_code: int, latency_ms: float) -> None:
        with self._lock:
            self.total += 1
            if 200 <= status_code < 300:
                self.success += 1
            elif 500 <= status_code < 600:
                self.errors_5xx += 1
            else:
                self.errors_other += 1
            self.latencies.append(latency_ms)

    def summary(self) -> dict:
        lats = sorted(self.latencies)
        n = len(lats)
        return {
            "total_requests": self.total,
            "success": self.success,
            "errors_5xx": self.errors_5xx,
            "errors_other": self.errors_other,
            "availability_pct": round(self.success / self.total * 100, 4) if self.total else 0,
            "p50_ms": lats[int(n * 0.50)] if n else 0,
            "p95_ms": lats[int(n * 0.95)] if n else 0,
            "p99_ms": lats[int(n * 0.99)] if n else 0,
        }


# ── Logica de usuario virtual ──────────────────────────────────────────────


def _pick_endpoint(endpoints: list) -> dict:
    weights = [e["weight"] for e in endpoints]
    return random.choices(endpoints, weights=weights, k=1)[0]


def _get_token(base_url: str, timeout: float = 5) -> Optional[str]:
    try:
        r = requests.post(
            f"{base_url}/auth/login",
            json={"username": "demo", "password": "demo123"},
            timeout=timeout,
        )
        if r.ok:
            return r.json().get("token")
    except Exception:
        pass
    return None


def _virtual_user(
    base_url: str,
    endpoints: list,
    duration: float,
    stats: Stats,
    rows: list,
    rows_lock: threading.Lock,
) -> None:
    token = _get_token(base_url)
    deadline = time.monotonic() + duration

    while time.monotonic() < deadline:
        ep = _pick_endpoint(endpoints)
        url = base_url + ep["path"]
        headers = dict(ep.get("headers", {}))
        if token:
            headers.setdefault("Authorization", f"Bearer {token}")
        headers = {k: v.replace("<TOKEN>", token or "") for k, v in headers.items()}

        t0 = time.monotonic()
        try:
            resp = requests.request(
                ep["method"],
                url,
                headers=headers,
                json=ep.get("body"),
                timeout=5,
            )
            status = resp.status_code
        except requests.exceptions.Timeout:
            status = 504
        except Exception:
            status = 0

        latency = (time.monotonic() - t0) * 1000
        stats.record(status, latency)

        row = {
            "timestamp": datetime.utcnow().isoformat(),
            "endpoint": ep["name"],
            "status": status,
            "latency_ms": round(latency, 2),
        }
        with rows_lock:
            rows.append(row)

        time.sleep(random.uniform(0.1, 0.5))


# ── Main ───────────────────────────────────────────────────────────────────


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", default="config.json")
    parser.add_argument("--output", default="results.csv")
    args = parser.parse_args()

    with open(args.config) as f:
        cfg = json.load(f)

    base_url = cfg["alb_url"].rstrip("/")
    n_users = cfg["concurrent_users"]
    duration = cfg["duration_seconds"]
    ramp_up = cfg.get("ramp_up_seconds", 10)
    endpoints = cfg["endpoints"]

    stats = Stats()
    rows: list = []
    rows_lock = threading.Lock()
    threads = []

    print(f"[{datetime.utcnow().isoformat()}] Iniciando prueba – {n_users} usuarios, {duration}s")

    for i in range(n_users):
        t = threading.Thread(
            target=_virtual_user,
            args=(base_url, endpoints, duration, stats, rows, rows_lock),
            daemon=True,
        )
        threads.append(t)
        t.start()
        time.sleep(ramp_up / n_users)

    for t in threads:
        t.join()

    summary = stats.summary()
    print("\n=== RESUMEN ===")
    for k, v in summary.items():
        print(f"  {k}: {v}")

    with open(args.output, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=["timestamp", "endpoint", "status", "latency_ms"])
        writer.writeheader()
        writer.writerows(rows)

    print(f"\nResultados guardados en {args.output}")


if __name__ == "__main__":
    main()
