import hashlib
import uuid
from fastapi import APIRouter, BackgroundTasks, Depends, File, Form, HTTPException, Request, UploadFile
from fastapi.responses import FileResponse
from ..config import UPLOAD_DIR, MAX_UPLOAD_BYTES
from ..database import get_conn, one, rows
from ..security import current_user, require_roles, audit, client_ip
from ..ws import manager

router = APIRouter(prefix="/api", tags=["screenings"])
EXT = {"image/jpeg": ".jpg", "image/png": ".png", "image/webp": ".webp"}
VIEWS = {"CHEEK_LINING", "TONGUE", "PALATE", "GUMS", "FLOOR_OF_MOUTH", "OTHER"}


def _own_screening(conn, user, sid, request=None):
    s = one(conn, "SELECT id, patient_id FROM tbl_screenings WHERE id=:i", i=sid)
    if not s:
        raise HTTPException(404, "Screening not found")
    ok = one(conn, "SELECT fn_user_has_patient_access(:u,:p) AS ok", u=user["id"], p=s["patient_id"])
    if not ok["ok"]:
        audit(conn, user, "ACCESS_DENIED", "screening", sid, patient_id=s["patient_id"], outcome="DENIED",
              ip=client_ip(request) if request else None)
        conn.commit()
        raise HTTPException(404, "Screening not found")
    return s


@router.get("/screenings")
def list_screenings(user=Depends(current_user), conn=Depends(get_conn)):
    return rows(conn, """
        SELECT s.id, s.patient_id, p.patient_code, p.full_name AS patient_name, s.screening_date, s.case_state,
               s.chief_complaint, s.tobacco_current, s.created_at,
               (SELECT COUNT(*) FROM tbl_screening_photos ph WHERE ph.screening_id = s.id) AS photo_count
          FROM tbl_screenings s JOIN tbl_patients p ON p.id = s.patient_id
         WHERE p.deleted_at IS NULL AND fn_user_has_patient_access(:u, s.patient_id)
         ORDER BY s.created_at DESC LIMIT 200""", u=user["id"])


@router.get("/screenings/{sid}/photos")
def list_photos(sid: str, request: Request, user=Depends(current_user), conn=Depends(get_conn)):
    _own_screening(conn, user, sid, request)
    return rows(conn, """SELECT id, view_type, status, mime_type, size_bytes, captured_at
                           FROM tbl_screening_photos WHERE screening_id=:s ORDER BY captured_at DESC""", s=sid)


@router.post("/screenings/{sid}/photos", status_code=201)
async def upload_photo(sid: str, bg: BackgroundTasks, request: Request, image: UploadFile = File(...),
                       view_type: str = Form("OTHER"), annotation_site: str | None = Form(None),
                       user=Depends(require_roles("HEALTH_WORKER")), conn=Depends(get_conn)):
    s = _own_screening(conn, user, sid, request)
    if image.content_type not in EXT:
        raise HTTPException(400, "Only JPEG, PNG or WebP images are allowed")
    if view_type not in VIEWS:
        raise HTTPException(400, "Invalid view type")
    data = await image.read(MAX_UPLOAD_BYTES + 1)
    if not data or len(data) > MAX_UPLOAD_BYTES:
        raise HTTPException(400, "File is empty or larger than 10 MB")
    key = f"{sid}/{uuid.uuid4().hex}{EXT[image.content_type]}"
    # IMAGE_CAPTURE consent + duplicate-checksum rules are enforced by the database (triggers / unique keys)
    ph = one(conn, """
        INSERT INTO tbl_screening_photos (screening_id, patient_id, view_type, annotation_site, private_key,
                                          checksum_sha256, mime_type, size_bytes, captured_by)
        VALUES (:s, :p, CAST(:v AS oral_view), :a, :k, :c, :m, :z, :u) RETURNING id, view_type, status""",
        s=sid, p=s["patient_id"], v=view_type, a=annotation_site, k=key, c=hashlib.sha256(data).hexdigest(),
        m=image.content_type, z=len(data), u=user["id"])
    path = UPLOAD_DIR / key
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    audit(conn, user, "IMAGE_UPLOADED", "photo", ph["id"], patient_id=s["patient_id"], ip=client_ip(request))
    conn.commit()
    bg.add_task(manager.notify, user["id"], "screenings", "updated", {"id": sid})
    return ph


@router.get("/photos/{phid}/file")
def photo_file(phid: str, request: Request, user=Depends(require_roles("HEALTH_WORKER", "MEDICAL_OFFICER", "SPECIALIST")),
               conn=Depends(get_conn)):
    ph = one(conn, "SELECT id, screening_id, patient_id, private_key, mime_type FROM tbl_screening_photos WHERE id=:i", i=phid)
    if not ph:
        raise HTTPException(404, "Photo not found")
    _own_screening(conn, user, ph["screening_id"], request)
    audit(conn, user, "IMAGE_VIEW", "photo", phid, patient_id=ph["patient_id"], ip=client_ip(request))
    conn.commit()
    path = UPLOAD_DIR / ph["private_key"]
    if not path.is_file():
        raise HTTPException(404, "Photo file missing")
    return FileResponse(path, media_type=ph["mime_type"])
