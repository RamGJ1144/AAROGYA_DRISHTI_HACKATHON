from fastapi import APIRouter, Depends
from ..database import get_conn, rows

router = APIRouter(prefix="/api/masters", tags=["masters"])
DESIGNATIONS = ["ASHA", "ANM", "CHO", "OTHER"]


@router.get("")
def masters(conn=Depends(get_conn)):
    """Public lookup data (no patient data) used by the sign-up and registration forms."""
    return {
        "designations": DESIGNATIONS,
        "languages": rows(conn, "SELECT id, code, name_en, native_name FROM mst_languages WHERE is_active ORDER BY id"),
        "facilities": rows(conn, "SELECT id, code, name_en, facility_type FROM mst_facilities WHERE is_active ORDER BY name_en"),
        "villages": rows(conn, "SELECT id, code, name_en FROM mst_villages WHERE is_active ORDER BY name_en"),
        "consent_purposes": rows(conn, "SELECT code, name_en, text_en, version, is_required FROM mst_consent_purposes WHERE is_active ORDER BY id"),
    }
