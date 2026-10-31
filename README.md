# Aarogya Drishti (synthetic data only - NOT FOR CLINICAL USE)

FastAPI + WebSockets backend on **PostgreSQL** (your v3 schema), React frontend.

## 1. Database
1. Create a database: `createdb aarogya_drishti`
2. Copy **your schema file** to `backend/db/ALL_IN_ONE.sql` (not bundled here).
3. Edit `backend/.env`: `DATABASE_URL=postgresql+psycopg2://USER:PASSWORD@localhost:5432/aarogya_drishti` and set `JWT_SECRET`.
   The schema needs PostgreSQL 13+ and the `btree_gist` + `pgcrypto` extensions (a superuser or trusted-extension rights).

## 2. Backend (port 8000)
```bash
cd backend
python -m venv venv && source venv/bin/activate     # Windows: venv\Scripts\activate
pip install -r requirements.txt
python -m scripts.migrate         # applies db/ALL_IN_ONE.sql  (add --reset to wipe and recreate)
python -m scripts.seed_demo       # demo logins, password Demo@12345: admin, asha1, mo1, specialist1, navigator1, hospital1, district
python run.py
```
Docs: http://localhost:8000/docs  ·  Health: http://localhost:8000/api/health

## 3. Frontend (port 3000)
```bash
cd frontend && npm install && npm start
```

## How it maps to the schema
- **Sign up** -> `tbl_user_registration_requests` (PENDING). Log in as `admin` and approve in the *Approvals* tab; that creates the `tbl_users` row (role HEALTH_WORKER), facility assignment and language preference. Login works only after approval.
- **Login** -> `tbl_users` (bcrypt, 5 failed attempts = 15 min lock), `tbl_user_sessions` (revocable; logout revokes), `tbl_audit_logs`.
- **Patients / consent** -> `tbl_patients`, `tbl_patient_consents` (append-only), duplicate flags, access via `fn_user_has_patient_access`.
- **Screenings / photos** -> `tbl_screenings`, `tbl_screening_photos` (files in `backend/uploads`, SHA-256 checksum, IMAGE_CAPTURE consent enforced by the DB, views are audited).
- Business rules (consent gates, role checks, state machine) are enforced by your DB triggers; their messages are returned to the UI as errors.
- WebSocket `ws://localhost:8000/ws?token=<JWT>` pushes `{type:"update", resource, action}`; the UI refreshes live.

## Not built yet
MFA (roles flagged `mfa_required`), clinician review, AI assessment, referrals, appointments, investigations, navigation tasks, dashboards, offline sync. Tables exist; endpoints do not.
Written without a PostgreSQL server available, so it is syntax-checked only - report any first-run error.
