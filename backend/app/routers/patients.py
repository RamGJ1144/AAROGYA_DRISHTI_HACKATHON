import hashlib
from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, Request
from pydantic import BaseModel
from sqlalchemy import text
from ..database import get_conn, one, rows
from ..security import current_user, require_roles, audit, client_ip
from ..ws import manager

router = APIRouter(prefix="/api/patients", tags=["patients"])
SEX = {"FEMALE", "MALE", "OTHER", "UNDISCLOSED"}


class PatientIn(BaseModel):
    full_name: str = ""
    sex: str = "UNDISCLOSED"
    date_of_birth: str | None = None
    age_years: int | None = None
    village_id: int | None = None
    habitation: str | None = None
    address_line: str | None = None
    contact_phone: str | None = None
    preferred_language_id: int | None = None
    idempotency_key: str | None = None


class ConsentIn(BaseModel):
    purpose_code: str
    granted: bool = True
    method: str = "CHECKBOX"
    language_id: int | None = None
    witness_name: str | None = None


class ScreeningIn(BaseModel):
    tobacco_current: bool | None = None
    chief_complaint: str | None = None
    notes: str | None = None
    screening_site_id: int | None = None


def ensure_access(conn, user, pid, request=None):
    ok = one(conn, "SELECT fn_user_has_patient_access(:u, :p) AS ok", u=user["id"], p=pid)
    if not ok or not ok["ok"]:
        audit(conn, user, "ACCESS_DENIED", "patient", pid, patient_id=pid, outcome="DENIED",
              ip=client_ip(request) if request else None)
        conn.commit()
        raise HTTPException(404, "Patient not found")


@router.get("")
def list_patients(user=Depends(current_user), conn=Depends(get_conn)):
    return rows(conn, """
        SELECT p.id, p.patient_code, p.full_name, p.sex, p.date_of_birth, p.age_years, p.contact_phone,
               v.name_en AS village, p.created_at,
               (SELECT COALESCE(json_object_agg(c.purpose_code, c.granted), '{}'::json)
                  FROM vw_patient_current_consents c WHERE c.patient_id = p.id) AS consents
          FROM tbl_patients p LEFT JOIN mst_villages v ON v.id = p.village_id
         WHERE p.deleted_at IS NULL AND fn_user_has_patient_access(:u, p.id)
         ORDER BY p.created_at DESC LIMIT 200""", u=user["id"])


@router.post("", status_code=201)
def create_patient(body: PatientIn, bg: BackgroundTasks, request: Request,
                   user=Depends(require_roles("HEALTH_WORKER")), conn=Depends(get_conn)):
    name = body.full_name.strip()
    if not name:
        raise HTTPException(400, "Patient name is required")
    if body.sex not in SEX:
        raise HTTPException(400, "Invalid sex")
    if not body.date_of_birth and body.age_years is None:
        raise HTTPException(400, "Enter date of birth or age")
    if not user["facility_id"]:
        raise HTTPException(400, "Your account has no facility assignment")
    if body.idempotency_key:
        dup = one(conn, "SELECT id, patient_code FROM tbl_patients WHERE registered_by=:u AND idempotency_key=:k",
                  u=user["id"], k=body.idempotency_key)
        if dup:
            return {**dup, "duplicate_warnings": []}
    hint = hashlib.sha256(f"{name.lower()}|{body.date_of_birth or body.age_years}|{body.village_id}".encode()).hexdigest()
    p = one(conn, """
        INSERT INTO tbl_patients (full_name, sex, date_of_birth, age_years, village_id, habitation, address_line,
               contact_phone, preferred_language_id, phc_id, registered_facility_id, registered_by, duplicate_hint, idempotency_key)
        VALUES (:n, CAST(:sex AS sex_type), CAST(:dob AS date), :age, :v, :h, :a, :ph, :l,
                (SELECT phc_id FROM mst_facilities WHERE id = :f), :f, :u, :hint, :k)
        RETURNING id, patient_code""",
        n=name, sex=body.sex, dob=body.date_of_birth or None, age=body.age_years, v=body.village_id,
        h=body.habitation, a=body.address_line, ph=body.contact_phone, l=body.preferred_language_id,
        f=user["facility_id"], u=user["id"], hint=hint, k=body.idempotency_key)
    dups = rows(conn, "SELECT id, patient_code, full_name FROM tbl_patients WHERE duplicate_hint=:h AND id<>:i",
                h=hint, i=p["id"])
    for d in dups:
        conn.execute(text("""INSERT INTO tbl_patient_duplicate_flags (patient_id, candidate_id, match_reason)
                             VALUES (:a,:b,'same name / age or DOB / village') ON CONFLICT DO NOTHING"""),
                     {"a": p["id"], "b": d["id"]})
    audit(conn, user, "PATIENT_REGISTERED", "patient", p["id"], patient_id=p["id"], ip=client_ip(request))
    conn.commit()
    bg.add_task(manager.notify, user["id"], "patients", "created", {"id": str(p["id"])})
    return {**p, "duplicate_warnings": dups}


@router.post("/{pid}/consents", status_code=201)
def record_consent(pid: str, body: ConsentIn, bg: BackgroundTasks, request: Request,
                   user=Depends(require_roles("HEALTH_WORKER")), conn=Depends(get_conn)):
    ensure_access(conn, user, pid, request)
    purpose = one(conn, "SELECT id, version FROM mst_consent_purposes WHERE code=:c AND is_active", c=body.purpose_code)
    if not purpose:
        raise HTTPException(400, "Unknown consent purpose")
    lang = body.language_id or (one(conn, "SELECT id FROM mst_languages WHERE code='en'") or {}).get("id")
    c = one(conn, """
        INSERT INTO tbl_patient_consents (patient_id, purpose_id, language_id, consent_version, method, granted, captured_by, witness_name)
        VALUES (:p, :pu, :l, :v, CAST(:m AS consent_method), :g, :u, :w) RETURNING id, granted, captured_at""",
        p=pid, pu=purpose["id"], l=lang, v=purpose["version"], m=body.method, g=body.granted, u=user["id"], w=body.witness_name)
    audit(conn, user, "CONSENT_GRANTED" if body.granted else "CONSENT_WITHDRAWN", "consent", c["id"],
          patient_id=pid, ip=client_ip(request), purpose=body.purpose_code)
    conn.commit()
    bg.add_task(manager.notify, user["id"], "patients", "updated", {"id": pid})
    return c


@router.post("/{pid}/screenings", status_code=201)
def create_screening(pid: str, body: ScreeningIn, bg: BackgroundTasks, request: Request,
                     user=Depends(require_roles("HEALTH_WORKER", "MEDICAL_OFFICER")), conn=Depends(get_conn)):
    ensure_access(conn, user, pid, request)
    c = one(conn, """SELECT consent_id FROM vw_patient_current_consents WHERE patient_id=:p AND purpose_code='SCREENING' AND granted""", p=pid)
    if not c:
        raise HTTPException(400, "Record the patient's SCREENING consent first")
    s = one(conn, """
        INSERT INTO tbl_screenings (patient_id, examiner_id, facility_id, screening_site_id, case_state, consent_id,
                                    tobacco_current, chief_complaint, notes)
        VALUES (:p, :u, :f, :site, 'CONSENTED', :c, :t, :cc, :n) RETURNING id, case_state, screening_date""",
        p=pid, u=user["id"], f=user["facility_id"], site=body.screening_site_id, c=c["consent_id"],
        t=body.tobacco_current, cc=body.chief_complaint, n=body.notes)
    audit(conn, user, "SCREENING_CREATED", "screening", s["id"], patient_id=pid, ip=client_ip(request))
    conn.commit()
    bg.add_task(manager.notify, user["id"], "screenings", "created", {"id": str(s["id"])})
    return s
