from fastapi import APIRouter, HTTPException
from fastapi.responses import Response
from prometheus_client import CONTENT_TYPE_LATEST, generate_latest
from pydantic import BaseModel, Field

from .config import FaultMode
from .fault import apply_fault, fault_state
from .metrics import set_fault_mode_metric

router = APIRouter()

COURSES = [
    {"id": 1, "title": "Intro to SRE", "instructor": "Ben Treynor"},
    {"id": 2, "title": "Distributed Systems", "instructor": "Leslie Lamport"},
    {"id": 3, "title": "Observability 101", "instructor": "Charity Majors"},
]


@router.get("/healthz")
def healthz():
    return {"status": "ok"}


@router.get("/readyz")
def readyz():
    # 외부 의존성(DB/캐시/큐)이 없으므로 readiness는 프로세스의 요청 수락
    # 가능 여부만 검증한다. 자세한 근거는 docs/sli_slo_design.md §2 참고.
    return {"status": "ready"}


@router.get("/api/v1/courses")
def list_courses():
    if apply_fault():
        raise HTTPException(status_code=500, detail="injected fault")
    return {"courses": COURSES}


@router.get("/api/v1/courses/{course_id}")
def get_course(course_id: int):
    if apply_fault():
        raise HTTPException(status_code=500, detail="injected fault")
    for c in COURSES:
        if c["id"] == course_id:
            return c
    raise HTTPException(status_code=404, detail="course not found")


class FaultModeRequest(BaseModel):
    mode: FaultMode
    delay_ms: int = Field(default=0, ge=0, le=60000)
    error_rate: float = Field(default=0.0, ge=0.0, le=1.0)


@router.post("/admin/fault-mode")
def set_fault_mode(req: FaultModeRequest):
    fault_state.set(mode=req.mode, delay_ms=req.delay_ms, error_rate=req.error_rate)
    set_fault_mode_metric(req.mode)
    return {
        "mode": req.mode,
        "delay_ms": req.delay_ms,
        "error_rate": req.error_rate,
    }


@router.get("/metrics")
def metrics():
    return Response(content=generate_latest(), media_type=CONTENT_TYPE_LATEST)
