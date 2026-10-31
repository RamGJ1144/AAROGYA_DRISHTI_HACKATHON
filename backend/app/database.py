from sqlalchemy import create_engine, text
from .config import DATABASE_URL

_url = DATABASE_URL.replace("postgres://", "postgresql+psycopg2://", 1)
if _url.startswith("postgresql://"):
    _url = _url.replace("postgresql://", "postgresql+psycopg2://", 1)
engine = create_engine(_url, pool_pre_ping=True)


def get_conn():
    """One connection per request. Handlers call conn.commit(); anything uncommitted rolls back."""
    conn = engine.connect()
    try:
        yield conn
    finally:
        conn.close()


def rows(conn, sql: str, **p) -> list[dict]:
    return [dict(r._mapping) for r in conn.execute(text(sql), p)]


def one(conn, sql: str, **p) -> dict | None:
    r = conn.execute(text(sql), p).first()
    return dict(r._mapping) if r else None
