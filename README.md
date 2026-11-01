# Arogya Drusti

A personal health manager: keep your health records, log vitals (BP, heart rate, sugar, weight)
and store medical images, all behind a login. **AI image analysis is intentionally not built yet**,
but the hook for it is in place (see below).

- **Backend:** Node.js, Express 5, PostgreSQL (`backened/`)
- **Frontend:** React (Create React App), plain CSS (`frentened/`)
- Folder names `backened` / `frentened` are kept as in the original project.

---

## Project status

| Area | Status |
|---|---|
| Register / login (bcrypt + JWT, 7-day token) | Done |
| User profile (DOB, gender, blood group, phone, emergency contact) | Done |
| Health records: add / list / edit (API) / delete | Done |
| Vitals log: add / list / delete | Done |
| Medical image upload, protected download, delete | Done |
| Database schema + migration script | Done |
| Minimal React UI (login, 4 tabs) | Done |
| **AI image analysis** | **Not implemented** (stub + `POST /api/images/:id/analyze` returns 501) |
| Automated tests | Only one placeholder frontend test; no backend tests |
| Rich UI / charts / mobile polish | Not started (UI is deliberately minimal) |

**Verification note:** this code was written in an offline environment with no PostgreSQL, so it has been
syntax-checked but **not run end to end**. Do a first run using the steps below and expect to fix small
issues. Please report anything that breaks.

---

## Setup

Requirements: Node.js 18+, PostgreSQL running locally.

1. **Create the database** named in `backened/.env` (`DB_NAME`), e.g. in psql:
   `CREATE DATABASE "Arogya_drishit";`
2. **Check `backened/.env`.** Required keys are listed in `backened/.env.example`.
   `JWT_SECRET` was added for you with a random value. Set a new one for any real deployment.
3. **Install dependencies** (from the project root):
   ```
   npm run install:all
   ```
4. **Create the tables:**
   ```
   npm run migrate
   ```
5. **Run the API** (terminal 1): `npm start` (or `npm run dev` to auto-restart). Runs on port 5000.
6. **Run the UI** (terminal 2): `npm run client`. Opens http://localhost:3000 and proxies `/api` to port 5000.

Quick check: http://localhost:5000/test-db should report a successful DB connection.

**Single-server mode:** `npm run build:client`, then `npm start`. The API serves the built React app on port 5000.

---

## Project layout

```
backened/
  server.js            starts the server
  app.js               Express app, routes, error handler
  db.js                PostgreSQL pool
  db/schema.sql        tables (idempotent)
  db/migrate.js        runs schema.sql
  middleware/auth.js   JWT sign / verify
  routes/              auth, profile, records, vitals, images
  services/imageAnalysis.js   <-- AI analysis plug-in point (stub)
  uploads/             stored images (git-ignored)
frentened/src/
  api.js               fetch wrapper + token handling
  App.js / App.css     shell, tabs, minimal styles
  components/          Auth, Records, Vitals, Images, Profile
```

## API summary

All routes except register/login need `Authorization: Bearer <token>`. Every query is scoped to the logged-in user.

| Method | Path | Purpose |
|---|---|---|
| POST | `/api/auth/register`, `/api/auth/login` | returns `{ token, user }` |
| GET | `/api/auth/me` | current user |
| GET / PUT | `/api/profile` | read / update profile |
| GET / POST | `/api/records` | list / create |
| PUT / DELETE | `/api/records/:id` | update / delete |
| GET / POST | `/api/vitals` | list (latest 200) / create |
| DELETE | `/api/vitals/:id` | delete |
| GET / POST | `/api/images` | list / upload (multipart field `image`, optional `description`) |
| GET | `/api/images/:id/file` | download (auth required) |
| POST | `/api/images/:id/analyze` | 501 until analysis is implemented |
| DELETE | `/api/images/:id` | delete |

Uploads: JPEG/PNG/WebP only, max 10 MB, stored under random names and never served statically.

---

## Adding AI image analysis later

1. Implement `analyze({ filePath, mimeType, description })` in `backened/services/imageAnalysis.js`
   and return a JSON-serialisable object.
2. Set `available = true` in that file.

The route already saves the result to `images.analysis_result`, updates `analysis_status`, and the
Images tab already has an **Analyze** button and displays the result. Add any provider API key to `.env`.
Since this is health data, plan for a clear "not medical advice" notice in the UI.

## Improving the UI later

The UI is intentionally plain. All styling is in `frentened/src/App.css` and uses class names, and all
API access goes through `src/api.js`, so you can restyle or adopt a component library without touching the
backend. Ideas: vitals charts, record editing in the UI, record attachments, responsive navigation.

## Known gaps / next steps

- Run and fix-test the full flow against a real database; add backend tests.
- Records can be edited via the API but the UI only supports add and delete.
- No password reset, email verification, or rate limiting on login.
- Images are stored on local disk (fine for development; use object storage in production).
- Set `CORS_ORIGIN` and a strong `JWT_SECRET` before deploying; use HTTPS.
- `.env` contains database credentials: do not commit it (it is in `.gitignore`).