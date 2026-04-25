import time

from fastapi import Request
from prometheus_client import Counter, Gauge, Histogram

from .config import FAULT_MODES, LATENCY_BUCKETS_SECONDS

http_requests_total = Counter(
    "http_requests_total",
    "Total HTTP requests",
    ["method", "route", "status"],
)

http_request_duration_seconds = Histogram(
    "http_request_duration_seconds",
    "HTTP request duration in seconds",
    ["method", "route"],
    buckets=LATENCY_BUCKETS_SECONDS,
)

# 현재 fault mode를 gauge로 노출. Grafana annotation/state timeline에
# 활용하면 incident 시각이 dashboard에 자동 표시되어 RCA가 쉬워진다.
api_fault_mode = Gauge(
    "api_fault_mode",
    "Active fault injection mode (1 = active, 0 = inactive)",
    ["mode"],
)


def set_fault_mode_metric(active_mode: str) -> None:
    for m in FAULT_MODES:
        api_fault_mode.labels(mode=m).set(1 if m == active_mode else 0)


set_fault_mode_metric("normal")


async def observe_requests(request: Request, call_next):
    start = time.perf_counter()
    response = await call_next(request)
    elapsed = time.perf_counter() - start

    # route template(예: /api/v1/courses/{course_id})으로 라벨링하여
    # 라벨 cardinality를 묶는다. unmatched는 별도 버킷으로 모은다.
    route_obj = request.scope.get("route")
    route_path = route_obj.path if route_obj else "__unmatched__"

    http_requests_total.labels(
        method=request.method,
        route=route_path,
        status=str(response.status_code),
    ).inc()
    http_request_duration_seconds.labels(
        method=request.method,
        route=route_path,
    ).observe(elapsed)

    return response
