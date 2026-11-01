# Arogya Drishti — Stage 2 (Hackathon)

Health-worker platform: admins manage users, health workers register patients and upload media.
Stack: Node.js + Express 5 + PostgreSQL (`backend/`), React CRA (`frentened/`).

## What changed in Stage 2
1. **Worker dashboard fixed** – patients are saved directly to PostgreSQL (`tbl_patients`) via `POST /api/patients`,
   fetched with `GET /api/patients`, and listed on the dashboard itself (plus the Patient Records page).
   Media uploads are stored in `tbl_media_files` and listed on the Media page.
2. **Register + admin approval** – Login page has a *Register* button -> `/register`. New accounts are saved as
   `PENDING`; login is blocked until an admin clicks **Approve** in *Pending Approvals*. Rejected users cannot log in.
3. **`backend/sample.js`** now sets **every** user's password to `Demo@1234`.

## How to run
Requirements: Node.js 18+, PostgreSQL (database from `backend/.env`, e.g. `Arogya_drishit`; `mst_roles` and `tbl_users` must exist, with roles `SYSTEM_ADMIN` and `HEALTH_WORKER`).

```bash
npm run install:all      # install backend + frontend deps (from project root)
npm run migrate          # adds tbl_users.status, tbl_patients, tbl_media_files (safe to re-run)
npm run reset-passwords  # optional: set ALL users' password to Demo@1234 (runs backend/sample.js)
npm start                # API on http://localhost:5000   (npm run dev = auto-restart)
npm run client           # UI  on http://localhost:3000   (second terminal)
```
Existing users become `APPROVED` automatically when you run the migration.
Test: log in as an existing user with `Demo@1234`.

## Folder structure
```
arogya_drusti/
├─ package.json              root scripts (start, dev, migrate, reset-passwords, client, install:all)
├─ stage2_hackathon.md       this file
├─ backend/
│  ├─ server.js              MAIN API: login, register, users, approvals, patients, media
│  ├─ sample.js              resets all passwords to Demo@1234
│  ├─ seed-admin.js          legacy admin seed (old `users` table; not used in Stage 2)
│  ├─ db.js                  PostgreSQL pool
│  ├─ db/migrate.js          Stage 2 migration
│  ├─ db/schema.sql          notes on schema
│  ├─ middleware/auth.js     authenticate / adminOnly (JWT)
│  ├─ uploads/               uploaded media
│  └─ app.js, routes/, services/   legacy Stage 1 scaffold (not used by server.js)
└─ frentened/src/
   ├─ App.js                 routes
   ├─ api.js                 fetch helper
   ├─ styles.css
   └─ pages/ Login.js, Register.js, AdminDashboard.js, WorkerDashboard.js
```

## API (server.js)
| Method | Path | Access |
|---|---|---|
| POST | `/api/auth/login` | public (only APPROVED users) |
| POST | `/api/auth/register` | public -> status PENDING |
| GET | `/api/users?status=PENDING` | admin |
| POST | `/api/users/register` | admin (auto-approved) |
| PATCH | `/api/users/:id/status` | admin `{status: APPROVED/REJECTED}` |
| GET / POST | `/api/patients` | logged in (workers see own; admin `?worker=id`) |
| POST / GET | `/api/media/upload`, `/api/media` | logged in |

## Project status
| Item | Status |
|---|---|
| Login (admin / health worker) | Done |
| Worker dashboard: add + list patients from DB | Done (code complete) |
| Self-registration + admin approval | Done (code complete) |
| Admin: register users, approvals, directory | Done |
| Password reset script (all users) | Done |
| Media upload | Done |

**Not yet tested end to end:** this was written without a database or network, so run the steps above and
report any errors. Known gaps: no password reset UI, no tests, `localhost:5000` URLs are hardcoded in the frontend,
uploads are served publicly under `/uploads`, `.env` holds secrets (don't commit it).
