"""python -m scripts.seed_demo   Creates one DEMO login per role (password: Demo@12345). Delete before real use."""
import psycopg2
from app.config import DATABASE_URL
from app.security import hash_password

PASSWORD = "Demo@12345"
USERS = [  # username, full name, role, facility code, designation
    ("admin", "Demo System Admin", "SYSTEM_ADMIN", "FAC_DISTRICT_OFFICE", None),
    ("district", "Demo District Admin", "DISTRICT_ADMIN", "FAC_DISTRICT_OFFICE", None),
    ("asha1", "Demo ASHA Worker", "HEALTH_WORKER", "FAC_PHC_GM", "ASHA"),
    ("mo1", "Demo Medical Officer", "MEDICAL_OFFICER", "FAC_PHC_GM", None),
    ("specialist1", "Demo Specialist", "SPECIALIST", "FAC_RCC_DEMO", None),
    ("navigator1", "Demo Navigator", "NAVIGATOR", "FAC_AH_PADERU_DEMO", None),
    ("hospital1", "Demo Hospital Staff", "HOSPITAL_STAFF", "FAC_AH_PADERU_DEMO", None),
]

conn = psycopg2.connect(DATABASE_URL.replace("postgresql+psycopg2://", "postgresql://", 1))
cur = conn.cursor()
h = hash_password(PASSWORD)
for uname, name, role, fac, desig in USERS:
    cur.execute("SELECT 1 FROM tbl_users WHERE lower(username)=%s", (uname,))
    if cur.fetchone():
        continue
    cur.execute("""INSERT INTO tbl_users (username, password_hash, full_name, designation, role_id, password_changed_at)
                   VALUES (%s,%s,%s,%s,(SELECT id FROM mst_roles WHERE code=%s), now()) RETURNING id""",
                (uname, h, name, desig, role))
    uid = cur.fetchone()[0]
    cur.execute("INSERT INTO tbl_user_facility_assignments (user_id, facility_id, is_primary) "
                "SELECT %s, id, TRUE FROM mst_facilities WHERE code=%s", (uid, fac))
conn.commit()
print("Demo users ready (password %s): %s" % (PASSWORD, ", ".join(u[0] for u in USERS)))
