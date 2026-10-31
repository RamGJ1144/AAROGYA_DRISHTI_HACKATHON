import re
from datetime import datetime, timedelta, timezone
from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, Request
from pydantic import BaseModel
from sqlalchemy import text
from ..config import MAX_FAILED_LOGINS, LOCK_MINUTES
from ..database import get_conn, one, rows
from ..security import (hash_password, verify_password, create_token, session_expiry, new_refresh_token,
                        current_user, require_roles, client_ip, audit)
from ..ws import manager

router = APIRouter(prefix="/api/auth", tags=["auth"])
USERNAME_RE = re.compile(r"^[A-Za-z0-9_.-]{3,40}$")
DESIGNATIONS = {"ASHA", "ANM", "CHO", "OTHER"}


class RegisterIn(BaseModel):
    full_name: str = ""
    username: str = ""
    phone: str = ""
    email: str | None = None
    designation: str = ""
    employee_ref: str | None = None
    facility_id: int | None = None
    language_id: int | None = None
    password: str = ""
    terms_accepted: bool = False


class LoginIn(BaseModel):
    username: str = ""
    password: str = ""


class RejectIn(BaseModel):
    reason: str = ""


@router.post("/register", status_code=201)
def register(body: RegisterIn, bg: BackgroundTasks, request: Request, conn=Depends(get_conn)):
    """Self-registration creates a PENDING request only. A SYSTEM_ADMIN must approve it before login works."""
    name, uname = body.full_name.strip(), body.username.strip()
    if not name or not body.phone.strip() or not body.password:
        raise HTTPException(400, "name, username, phone and password are required")
    if not USERNAME_RE.match(uname):
        raise HTTPException(400, "Username must be 3-40 characters: letters, digits, . _ -")
    if body.designation not in DESIGNATIONS:
        raise HTTPException(400, "Choose a valid designation")
    if len(body.password) < 8:
        raise HTTPException(400, "Password must be at least 8 characters")
    if not body.terms_accepted:
        raise HTTPException(400, "You must accept the terms")
    if not body.facility_id or not one(conn, "SELECT 1 AS x FROM mst_facilities WHERE id=:i AND is_active", i=body.facility_id):
        raise HTTPException(400, "Choose a valid facility")
    if not body.language_id or not one(conn, "SELECT 1 AS x FROM mst_languages WHERE id=:i AND is_active", i=body.language_id):
        raise HTTPException(400, "Choose a valid language")
    if one(conn, "SELECT 1 AS x FROM tbl_users WHERE lower(username)=lower(:u)", u=uname):
        raise HTTPException(409, "Username already taken")
    # the partial unique index uq_reg_pending_username raises 23505 -> 409 via the global handler
    req = one(conn, """
        INSERT INTO tbl_user_registration_requests
          (full_name, username, phone, email, designation, employee_ref, facility_id, language_id, password_hash, terms_accepted_at)
        VALUES (:n, :u, :p, :e, :d, :er, :f, :l, :h, now()) RETURNING id""",
        n=name, u=uname, p=body.phone.strip(), e=body.email or None, d=body.designation,
        er=body.employee_ref or None, f=body.facility_id, l=body.language_id, h=hash_password(body.password))
    audit(conn, None, "REGISTRATION_REQUESTED", "registration_request", req["id"], ip=client_ip(request))
    admins = [a["id"] for a in rows(conn, """SELECT u.id FROM tbl_users u JOIN mst_roles r ON r.id=u.role_id
                                             WHERE r.code='SYSTEM_ADMIN' AND u.status='ACTIVE'""")]
    conn.commit()
    bg.add_task(manager.notify, admins, "registrations", "created")
    return {"status": "PENDING", "message": "Request submitted. A system administrator must approve it before you can log in."}


@router.post("/login")
def login(body: LoginIn, request: Request, conn=Depends(get_conn)):
    uname = body.username.strip()
    if not uname or not body.password:
        raise HTTPException(400, "username and password are required")
    ip = client_ip(request)
    u = one(conn, """SELECT u.*, r.code AS role FROM tbl_users u JOIN mst_roles r ON r.id=u.role_id
                      WHERE lower(u.username)=lower(:u) AND u.deleted_at IS NULL""", u=uname)
    if not u:
        pend = one(conn, """SELECT password_hash FROM tbl_user_registration_requests
                             WHERE lower(username)=lower(:u) AND status='PENDING'""", u=uname)
        if pend and verify_password(body.password, pend["password_hash"]):
            raise HTTPException(403, "Your registration is awaiting administrator approval")
        raise HTTPException(401, "Invalid username or password")
    if u["locked_until"] and u["locked_until"] > datetime.now(timezone.utc):
        raise HTTPException(429, "Account temporarily locked after too many failed attempts. Try again later.")
    if not verify_password(body.password, u["password_hash"]):
        locked = u["failed_login_count"] + 1 >= MAX_FAILED_LOGINS
        conn.execute(text("""UPDATE tbl_users SET failed_login_count = failed_login_count + 1,
                             locked_until = CASE WHEN :lk THEN now() + make_interval(mins => :m) ELSE locked_until END
                             WHERE id=:i"""), {"lk": locked, "m": LOCK_MINUTES, "i": u["id"]})
        audit(conn, {"id": u["id"], "role": u["role"]}, "LOGIN", "user", u["id"], outcome="DENIED", ip=ip)
        conn.commit()
        raise HTTPException(401, "Invalid username or password")
    if u["status"] != "ACTIVE":
        raise HTTPException(403, f"Account is {u['status'].lower()}")
    expires = session_expiry()
    _, token_hash = new_refresh_token()
    s = one(conn, """INSERT INTO tbl_user_sessions (user_id, refresh_token_hash, ip_address, user_agent, expires_at)
                     VALUES (:u, :h, CAST(:ip AS inet), :ua, :e) RETURNING id""",
            u=u["id"], h=token_hash, ip=ip, ua=request.headers.get("user-agent", "")[:300], e=expires)
    conn.execute(text("UPDATE tbl_users SET failed_login_count=0, locked_until=NULL, last_login_at=now() WHERE id=:i"), {"i": u["id"]})
    audit(conn, {"id": u["id"], "role": u["role"]}, "LOGIN", "user", u["id"], ip=ip)
    conn.commit()
    return {"token": create_token(u["id"], s["id"], expires),
            "user": {"id": u["id"], "name": u["full_name"], "username": u["username"], "role": u["role"]}}


@router.get("/me")
def me(user: dict = Depends(current_user)):
    return {"id": user["id"], "name": user["full_name"], "username": user["username"],
            "role": user["role"], "facility_id": user["facility_id"]}


@router.post("/logout", status_code=204)
def logout(user: dict = Depends(current_user), conn=Depends(get_conn)):
    conn.execute(text("UPDATE tbl_user_sessions SET revoked_at=now(), revoke_reason='logout' WHERE id=:i"), {"i": user["session_id"]})
    conn.commit()


# ---- SYSTEM_ADMIN: approve / reject health-worker registrations ----
@router.get("/registrations")
def list_requests(status: str = "PENDING", admin=Depends(require_roles("SYSTEM_ADMIN")), conn=Depends(get_conn)):
    return rows(conn, """
        SELECT q.id, q.full_name, q.username, q.phone, q.designation, q.employee_ref, q.status,
               q.created_at, f.name_en AS facility, q.rejection_reason
          FROM tbl_user_registration_requests q JOIN mst_facilities f ON f.id = q.facility_id
         WHERE q.status = CAST(:s AS registration_status) ORDER BY q.created_at""", s=status.upper())


@router.post("/registrations/{rid}/approve")
def approve(rid: str, bg: BackgroundTasks, admin=Depends(require_roles("SYSTEM_ADMIN")), conn=Depends(get_conn)):
    q = one(conn, "SELECT * FROM tbl_user_registration_requests WHERE id=:i FOR UPDATE", i=rid)
    if not q:
        raise HTTPException(404, "Request not found")
    if q["status"] != "PENDING":
        raise HTTPException(409, "Request already reviewed")
    if one(conn, "SELECT 1 AS x FROM tbl_users WHERE lower(username)=lower(:u)", u=q["username"]):
        raise HTTPException(409, "Username already exists")
    u = one(conn, """
        INSERT INTO tbl_users (username, password_hash, full_name, phone, email, designation, employee_ref, role_id, password_changed_at)
        VALUES (:u, :h, :n, :p, :e, :d, :er, (SELECT id FROM mst_roles WHERE code='HEALTH_WORKER'), now()) RETURNING id""",
        u=q["username"], h=q["password_hash"], n=q["full_name"], p=q["phone"], e=q["email"], d=q["designation"], er=q["employee_ref"])
    conn.execute(text("INSERT INTO tbl_user_facility_assignments (user_id, facility_id, is_primary) VALUES (:u,:f,TRUE)"),
                 {"u": u["id"], "f": q["facility_id"]})
    conn.execute(text("INSERT INTO tbl_user_language_preferences (user_id, language_id) VALUES (:u,:l)"),
                 {"u": u["id"], "l": q["language_id"]})
    conn.execute(text("""UPDATE tbl_user_registration_requests SET status='APPROVED', reviewed_by=:a, reviewed_at=now(),
                         created_user_id=:u WHERE id=:i"""), {"a": admin["id"], "u": u["id"], "i": rid})
    audit(conn, admin, "REGISTRATION_APPROVED", "registration_request", rid)
    conn.commit()
    bg.add_task(manager.notify, admin["id"], "registrations", "updated")
    return {"ok": True}


@router.post("/registrations/{rid}/reject")
def reject(rid: str, body: RejectIn, bg: BackgroundTasks, admin=Depends(require_roles("SYSTEM_ADMIN")), conn=Depends(get_conn)):
    if not body.reason.strip():
        raise HTTPException(400, "A rejection reason is required")
    q = one(conn, "SELECT status FROM tbl_user_registration_requests WHERE id=:i FOR UPDATE", i=rid)
    if not q:
        raise HTTPException(404, "Request not found")
    if q["status"] != "PENDING":
        raise HTTPException(409, "Request already reviewed")
    conn.execute(text("""UPDATE tbl_user_registration_requests SET status='REJECTED', reviewed_by=:a, reviewed_at=now(),
                         rejection_reason=:r WHERE id=:i"""), {"a": admin["id"], "r": body.reason.strip(), "i": rid})
    audit(conn, admin, "REGISTRATION_REJECTED", "registration_request", rid)
    conn.commit()
    bg.add_task(manager.notify, admin["id"], "registrations", "updated")
    return {"ok": True}
