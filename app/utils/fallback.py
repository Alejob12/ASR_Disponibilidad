import concurrent.futures
from typing import Callable, Any


def call_with_fallback(fn: Callable, fallback: Any, timeout: float = 5) -> Any:
    """Calls fn with a timeout. Returns fallback value if timeout or exception occurs."""
    executor = concurrent.futures.ThreadPoolExecutor(max_workers=1)
    future = executor.submit(fn)
    try:
        result = future.result(timeout=timeout)
        executor.shutdown(wait=False)
        return result
    except (concurrent.futures.TimeoutError, Exception):
        executor.shutdown(wait=False)
        return fallback
