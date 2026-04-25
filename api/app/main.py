from fastapi import FastAPI

from .metrics import observe_requests
from .routes import router

app = FastAPI(title="Elice SRE Mini Project API", version="0.1.0")

app.middleware("http")(observe_requests)
app.include_router(router)
