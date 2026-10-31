import logging
from fastapi import FastAPI, Request, WebSocket, WebSocketDisconnect
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from sqlalchemy import text
from sqlalchemy.exc import DBAPIError
from starlette.exceptions import HTTPException as StarletteHTTPException

from .config import CORS_ORIGINS
from .database import engine
from .routers import auth, masters, patients, screenings
from .security import load_session_user
from .ws import manager

log = logging.getLogger("uvicorn.error")
app = FastAPI(title="Aarogya Drishti API")
app.add_middleware(CORSMiddleware, allow_origins=CORS_ORIGINS, allow_credentials=True,
                   allow_methods=["*"], allow_headers=["*"])
for r in (auth, masters, patients, screenings):
    app.include_router(r.router)


@app.on_event("startup")
def check_schema():
    try:
        with engine.connect() as c:
            ok = c.execute(text("SELECT to_regclass('public.tbl_users') IS NOT NULL")).scalar()
        if not ok:
            log.warning("Database reachable but schema missing. Run:  python -m scripts.migrate")
    except Exception as e:
        log.error("Cannot connect to PostgreSQL: %s", e)


@app.exception_handler(StarletteHTTPException)
async def http_err(_: Request, exc: StarletteHTTPException):
    return JSONResponse({"error": exc.detail}, status_code=exc.status_code)


@app.exception_handler(RequestValidationError)
async def validation_err(_: Request, exc: RequestValidationError):
    return JSONResponse({"error": "Invalid input"}, status_code=400)


# Business rules live in PostgreSQL triggers/constraints; surface their messages as clean API errors.
PG_STATUS = {"23505": 409, "40001": 409, "42501": 403, "23514": 400, "23503": 400, "23502": 400,
             "22P02": 400, "22007": 400, "22008": 400, "23000": 400}


@app.exception_handler(DBAPIError)
async def db_err(_: Request, exc: DBAPIError):
    code = getattr(exc.orig, "pgcode", None)
    status = PG_STATUS.get(code)
    if status is None:
        log.exception("database error")
        return JSONResponse({"error": "Server error"}, status_code=500)
    msg = getattr(getattr(exc.orig, "diag", None), "message_primary", None) or "Request rejected by database rules"
    if code == "23505":
        msg = "A record with these details already exists"
    elif code == "23503":
        msg = "Referenced record does not exist"
    return JSONResponse({"error": msg}, status_code=status)


@app.get("/api/health")
def health():
    with engine.connect() as c:
        c.execute(text("SELECT 1"))
    return {"status": "ok", "database": "connected"}


@app.websocket("/ws")
async def websocket_endpoint(ws: WebSocket, token: str = ""):
    """ws://host:8000/ws?token=<JWT>. Server pushes {type:'update', resource, action}."""
    try:
        with engine.connect() as c:
            uid = load_session_user(c, token)["id"]
    except Exception:
        await ws.close(code=4401)
        return
    await manager.connect(uid, ws)
    try:
        while True:
            if await ws.receive_text() == "ping":
                await ws.send_json({"type": "pong"})
    except WebSocketDisconnect:
        pass
    finally:
        manager.disconnect(uid, ws)
