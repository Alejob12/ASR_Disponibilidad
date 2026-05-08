import concurrent.futures
from typing import Callable, Any


def call_with_fallback(fn: Callable, fallback: Any, timeout: float = 5) -> Any:
    """Calls fn with a timeout. Returns fallback value if timeout or exception occurs."""
    with concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
        future = executor.submit(fn)
        try:
            return future.result(timeout=timeout)
        except (concurrent.futures.TimeoutError, Exception):
            return fallback
