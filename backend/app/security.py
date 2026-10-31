import hashlib
import ipaddress
import secrets
from datetime import datetime, timedelta, timezone
import bcrypt
import jwt
from fastapi import Depends, Header, HTTPException, Request
from sqlalchemy import text
from .config import JWT_SECRET, JWT_EXPIRE_DAYS
from .database import get_conn, one


def hash_password(pw: str) -> str:
    return bcrypt.hashpw(pw.encode()[:72], bcrypt.gensalt()).decode()


def verify_password(pw: str, hashed: str) -> bool:
    try:
        return bcrypt.checkpw(pw.encode()[:72], hashed.encode())
    except ValueError:
        return False


def new_refresh_token() -> tuple[str, str]:
    t = secrets.token_urlsafe(32)
    return t, hashlib.sha256(t.encode()).hexdigest()


def create_token(user_id, session_id, expires: datetime) -> str:
    return jwt.encode({"sub": str(user_id), "sid": str(session_id), "exp": expires}, JWT_SECRET, algorithm="HS256")


def session_expiry() -> datetime:
    return datetime.now(timezone.utc) + timedelta(days=JWT_EXPIRE_DAYS)


def load_session_user(conn, token: str) -> dict:
    """Validates JWT + server-side session (expiry / revocation) + ACTIVE user. Raises on any failure."""
    claims = jwt.decode(token, JWT_SECRET, algorithms=["HS256"])
    u = one(conn, """
        SELECT u.id, u.full_name, u.username, r.code AS role,
               (SELECT ufa.facility_id FROM tbl_user_facility_assignments ufa
                 WHERE ufa.user_id = u.id AND ufa.valid_from <= CURRENT_DATE
                   AND (ufa.valid_to IS NULL OR ufa.valid_to >= CURRENT_DATE)
                 ORDER BY ufa.is_primary DESC, ufa.valid_from DESC LIMIT 1) AS facility_id,
               s.id AS session_id
          FROM tbl_user_sessions s
          JOIN tbl_users u ON u.id = s.user_id
          JOIN mst_roles r ON r.id = u.role_id
         WHERE s.id = :sid AND u.id = :uid AND s.revoked_at IS NULL AND s.expires_at > now()
           AND u.status = 'ACTIVE' AND u.deleted_at IS NULL""",
        sid=claims["sid"], uid=claims["sub"])
    if not u:
        raise ValueError("session invalid")
    return u


def current_user(authorization: str = Header(default=""), conn=Depends(get_conn)) -> dict:
    if not authorization.startswith("Bearer "):
        raise HTTPException(401, "Authentication required")
    try:
        user = load_session_user(conn, authorization[7:])
    except Exception:
        raise HTTPException(401, "Invalid or expired session")
    conn.execute(text("UPDATE tbl_user_sessions SET last_seen_at = now() WHERE id = :i"), {"i": user["session_id"]})
    conn.commit()
    return user


def require_roles(*codes: str):
    def dep(user: dict = Depends(current_user)) -> dict:
        if user["role"] not in codes:
            raise HTTPException(403, "Your role is not allowed to do this")
        return user
    return dep


def client_ip(request: Request) -> str | None:
    try:
        return str(ipaddress.ip_address(request.client.host))
    except Exception:
        return None


def audit(conn, user: dict | None, event: str, resource_type: str, resource_id=None, patient_id=None,
          outcome: str = "SUCCESS", ip: str | None = None, **meta):
    import json
    conn.execute(text("""
        INSERT INTO tbl_audit_logs (actor_id, actor_role, event, outcome, resource_type, resource_id, patient_id, ip_address, metadata)
        VALUES (:a, :r, :e, :o, :rt, :rid, :pid, CAST(:ip AS inet), CAST(:m AS jsonb))"""),
        {"a": user["id"] if user else None, "r": user["role"] if user else None, "e": event, "o": outcome,
         "rt": resource_type, "rid": str(resource_id) if resource_id else None,
         "pid": str(patient_id) if patient_id else None, "ip": ip, "m": json.dumps(meta)})
