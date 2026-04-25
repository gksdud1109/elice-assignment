from typing import Literal

FaultMode = Literal["normal", "slow", "error", "flaky"]
FAULT_MODES: tuple[FaultMode, ...] = ("normal", "slow", "error", "flaky")

# bucket 경계는 SLO 임계값(p95 300ms 목표, 500ms alert) 근처에 정밀도를
# 확보하기 위해 직접 지정한다. prometheus_client 기본 bucket은 250ms~1s
# 구간 해상도가 부족해 p95가 부정확해진다.
LATENCY_BUCKETS_SECONDS: tuple[float, ...] = (
    0.05, 0.1, 0.2, 0.3, 0.5, 1.0, 2.0, 5.0,
)
