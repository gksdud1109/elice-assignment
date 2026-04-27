import os
import time
from contextlib import contextmanager
from typing import Iterator

from psycopg_pool import ConnectionPool

from .metrics import db_errors_total, db_query_duration_seconds

DB_DSN = os.getenv(
    "DATABASE_URL",
    "postgresql://elice:elice@postgres:5432/elice",
)

# Connection pool. uvicorn single worker + sync route handler가 thread
# pool에서 실행되므로 동시 connection 수요가 thread 수만큼 생길 수 있다.
# max_size=10으로 데모 부하(5 VU 수준)에 여유를 둔다.
# - timeout: 풀에서 connection을 받아오는 최대 대기. 초과시 PoolTimeout.
# - max_lifetime: 오래된 connection을 주기적으로 재생성하여 stale 회피.
# - open=False: lifespan event에서 명시적으로 열고 닫는다.
pool: ConnectionPool = ConnectionPool(
    DB_DSN,
    min_size=1,
    max_size=10,
    timeout=2.0,
    max_lifetime=300,
    open=False,
)


def open_pool() -> None:
    """FastAPI lifespan startup에서 호출. DB 준비될 때까지 최대 10초 대기."""
    pool.open()
    pool.wait(timeout=10.0)


def close_pool() -> None:
    pool.close()


@contextmanager
def _timed_query(operation: str) -> Iterator[None]:
    """DB call을 감싸 latency Histogram과 error Counter를 기록."""
    start = time.perf_counter()
    try:
        yield
    except Exception:
        db_errors_total.labels(operation=operation).inc()
        raise
    finally:
        db_query_duration_seconds.labels(operation=operation).observe(
            time.perf_counter() - start
        )


def check_ready() -> bool:
    """SELECT 1로 readiness 확인. 1초 안에 응답하지 못하면 not ready."""
    try:
        with _timed_query("readiness"):
            with pool.connection(timeout=1.0) as conn:
                with conn.cursor() as cur:
                    cur.execute("SELECT 1")
                    cur.fetchone()
        return True
    except Exception:
        return False


def fetch_courses() -> list[dict]:
    with _timed_query("list_courses"):
        with pool.connection() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT id, title, instructor FROM courses ORDER BY id"
                )
                rows = cur.fetchall()
    return [{"id": r[0], "title": r[1], "instructor": r[2]} for r in rows]


def fetch_course_by_id(course_id: int) -> dict | None:
    with _timed_query("get_course"):
        with pool.connection() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT id, title, instructor FROM courses WHERE id = %s",
                    (course_id,),
                )
                row = cur.fetchone()
    if row is None:
        return None
    return {"id": row[0], "title": row[1], "instructor": row[2]}
