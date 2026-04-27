from contextlib import asynccontextmanager

from fastapi import FastAPI

from .db import close_pool, open_pool
from .metrics import observe_requests
from .routes import router


@asynccontextmanager
async def lifespan(app: FastAPI):
    # startup: DB pool 오픈 + 준비될 때까지 대기 (db.py에서 timeout 10s).
    # docker-compose의 depends_on: service_healthy가 1차 보호망이지만,
    # depends_on은 startup ordering일 뿐 운영 중 장애를 막지는 않는다.
    open_pool()
    yield
    close_pool()


app = FastAPI(
    title="Elice SRE Mini Project API",
    version="0.2.0",
    lifespan=lifespan,
)

app.middleware("http")(observe_requests)
app.include_router(router)
