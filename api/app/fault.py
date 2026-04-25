import random
import time
from dataclasses import dataclass, field
from threading import Lock

from .config import FaultMode


@dataclass
class FaultState:
    mode: FaultMode = "normal"
    delay_ms: int = 0
    error_rate: float = 0.0
    _lock: Lock = field(default_factory=Lock)

    def set(self, mode: FaultMode, delay_ms: int = 0, error_rate: float = 0.0) -> None:
        with self._lock:
            self.mode = mode
            self.delay_ms = delay_ms
            self.error_rate = error_rate

    def snapshot(self) -> tuple[FaultMode, int, float]:
        with self._lock:
            return self.mode, self.delay_ms, self.error_rate


# 단일 인스턴스 in-memory 상태. 멀티 인스턴스 환경에서는 노드 간 모드가
# 어긋날 수 있어 외부 저장소(예: Redis)로 옮겨야 한다 — 본 과제 범위 밖.
fault_state = FaultState()


def apply_fault() -> bool:
    """현재 fault mode를 적용한다. 요청을 5xx로 떨어뜨려야 하면 True."""
    mode, delay_ms, error_rate = fault_state.snapshot()

    if mode == "normal":
        return False

    if mode in ("slow", "flaky") and delay_ms > 0:
        time.sleep(delay_ms / 1000.0)

    if mode in ("error", "flaky") and error_rate > 0:
        if random.random() < error_rate:
            return True

    return False
