"""
Script de prueba de carga para el experimento ASR de Disponibilidad.
Simula usuarios concurrentes contra el ALB y registra errores, latencias
y disponibilidad percibida durante el experimento de inyeccion de fallos.

Usa asyncio + aiohttp para concurrencia real sin bloqueo por GIL.

Uso:
    python load_test.py --config config.json --output results.csv
"""

import argparse
import asyncio
import csv
import json
import random
import time
from datetime import datetime, timezone


try:
    import aiohttp
except ImportError:
    raise SystemExit("Instala aiohttp: pip install aiohttp")


# ── Resultado acumulado (solo accedido desde el event loop) ────────────────

class Stats:
    def __init__(self):
        self.total = 0
        self.success = 0
        self.errors_timeout = 0
        self.errors_5xx = 0
        self.errors_other = 0
        self.latencies: list[float] = []

    def record(self, status: int, latency_ms: float) -> None:
        self.total += 1
        if 200 <= status < 300:
            self.success += 1
        elif status == 504:
            self.errors_timeout += 1
        elif 500 <= status < 600:
            self.errors_5xx += 1
        else:
            self.errors_other += 1
        self.latencies.append(latency_ms)

    def summary(self) -> dict:
        lats = sorted(self.latencies)
        n = len(lats)
        avail = round(self.success / self.total * 100, 4) if self.total else 0
        return {
            "total_requests": self.total,
            "success": self.success,
            "errors_timeout": self.errors_timeout,
            "errors_5xx": self.errors_5xx,
            "errors_other": self.errors_other,
            "availability_pct": avail,
            "p50_ms": round(lats[int(n * 0.50)], 1) if n else 0,
            "p95_ms": round(lats[int(n * 0.95)], 1) if n else 0,
            "p99_ms": round(lats[int(n * 0.99)], 1) if n else 0,
        }


# ── Usuario virtual asíncrono ──────────────────────────────────────────────

def _pick(endpoints: list) -> dict:
    weights = [e["weight"] for e in endpoints]
    return random.choices(endpoints, weights=weights, k=1)[0]


async def _get_token(session: "aiohttp.ClientSession", base_url: str, retries: int = 3) -> str | None:
    for attempt in range(retries):
        try:
            async with session.post(
                f"{base_url}/auth/login",
                json={"username": "demo", "password": "demo123"},
                timeout=aiohttp.ClientTimeout(total=10),
            ) as r:
                if r.ok:
                    data = await r.json()
                    return data.get("token")
        except Exception:
            pass
        if attempt < retries - 1:
            await asyncio.sleep(1)
    return None


async def _virtual_user(
    session: "aiohttp.ClientSession",
    base_url: str,
    endpoints: list,
    deadline: float,
    stats: Stats,
    rows: list,
) -> None:
    token = await _get_token(session, base_url)
    timeout = aiohttp.ClientTimeout(total=10)

    while time.monotonic() < deadline:
        ep = _pick(endpoints)
        url = base_url + ep["path"]
        headers = dict(ep.get("headers", {}))
        if token:
            headers.setdefault("Authorization", f"Bearer {token}")
        headers = {k: v.replace("<TOKEN>", token or "") for k, v in headers.items()}

        t0 = time.monotonic()
        status = 0
        try:
            async with session.request(
                ep["method"],
                url,
                headers=headers,
                json=ep.get("body"),
                timeout=timeout,
            ) as resp:
                status = resp.status
                await resp.read()
                # Refresh token on 401 (instance mismatch or expiry)
                if status == 401 and ep["name"] != "login":
                    new_token = await _get_token(session, base_url)
                    if new_token:
                        token = new_token
        except asyncio.TimeoutError:
            status = 504
        except Exception:
            status = 0

        latency = (time.monotonic() - t0) * 1000
        stats.record(status, latency)
        rows.append({
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "endpoint": ep["name"],
            "status": status,
            "latency_ms": round(latency, 2),
        })

        await asyncio.sleep(random.uniform(0.1, 0.5))


# ── Main asíncrono ─────────────────────────────────────────────────────────

async def _run(cfg: dict, output: str) -> None:
    base_url = cfg["alb_url"].rstrip("/")
    n_users = cfg["concurrent_users"]
    duration = cfg["duration_seconds"]
    ramp_up = cfg.get("ramp_up_seconds", 10)
    endpoints = cfg["endpoints"]

    stats = Stats()
    rows: list = []
    deadline = time.monotonic() + duration

    connector = aiohttp.TCPConnector(limit=0, limit_per_host=0)
    async with aiohttp.ClientSession(connector=connector) as session:
        print(
            f"[{datetime.now(timezone.utc).isoformat()}] "
            f"Iniciando prueba – {n_users} usuarios, {duration}s"
        )

        tasks = []
        for i in range(n_users):
            t = asyncio.create_task(
                _virtual_user(session, base_url, endpoints, deadline, stats, rows)
            )
            tasks.append(t)
            await asyncio.sleep(ramp_up / n_users)

        await asyncio.gather(*tasks)

    summary = stats.summary()
    print("\n=== RESUMEN ===")
    for k, v in summary.items():
        print(f"  {k}: {v}")

    with open(output, "w", newline="") as f:
        writer = csv.DictWriter(
            f, fieldnames=["timestamp", "endpoint", "status", "latency_ms"]
        )
        writer.writeheader()
        writer.writerows(rows)

    print(f"\nResultados guardados en {output}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", default="config.json")
    parser.add_argument("--output", default="results.csv")
    args = parser.parse_args()

    with open(args.config) as f:
        cfg = json.load(f)

    asyncio.run(_run(cfg, args.output))


if __name__ == "__main__":
    main()
