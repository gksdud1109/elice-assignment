from fastapi import APIRouter, HTTPException
from fastapi.responses import JSONResponse, Response
from prometheus_client import CONTENT_TYPE_LATEST, generate_latest
from pydantic import BaseModel, Field

from .config import FaultMode
from .db import check_ready, fetch_course_by_id, fetch_courses
from .fault import apply_fault, fault_state
from .metrics import set_fault_mode_metric

router = APIRouter()


@router.get("/healthz")
def healthz():
    # liveness probe — 프로세스 생존만 확인. DB 상태는 보지 않는다.
    return {"status": "ok"}


@router.get("/readyz")
def readyz():
    # readiness probe — DB에 SELECT 1을 수행한다. 실패시 503.
    # 운영 환경에서는 K8s readiness probe 또는 LB health check가 503을 보고
    # 트래픽을 차단하지만, 본 docker-compose 환경에는 routing 계층이 없으므로
    # 503이 자동 트래픽 차단으로 이어지지는 않는다 — sli_slo_design.md §2.
    if check_ready():
        return {"status": "ready"}
    return JSONResponse(status_code=503, content={"status": "not_ready"})


@router.get("/api/v1/courses")
def list_courses():
    if apply_fault():
        raise HTTPException(status_code=500, detail="injected fault")
    try:
        courses = fetch_courses()
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"db error: {e.__class__.__name__}")
    return {"courses": courses}


@router.get("/api/v1/courses/{course_id}")
def get_course(course_id: int):
    if apply_fault():
        raise HTTPException(status_code=500, detail="injected fault")
    try:
        course = fetch_course_by_id(course_id)
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"db error: {e.__class__.__name__}")
    if course is None:
        raise HTTPException(status_code=404, detail="course not found")
    return course


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
