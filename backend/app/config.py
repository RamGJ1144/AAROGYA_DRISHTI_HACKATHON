import os
from pathlib import Path
from dotenv import load_dotenv

BASE_DIR = Path(__file__).resolve().parent.parent
load_dotenv(BASE_DIR / ".env")

DATABASE_URL = os.getenv("DATABASE_URL", "postgresql+psycopg2://postgres:postgres@localhost:5432/aarogya_drishti")
JWT_SECRET = os.getenv("JWT_SECRET", "dev-insecure-secret-change-me")
JWT_EXPIRE_DAYS = 7
CORS_ORIGINS = [o.strip() for o in os.getenv("CORS_ORIGINS", "http://localhost:3000").split(",")]
UPLOAD_DIR = BASE_DIR / "uploads"
UPLOAD_DIR.mkdir(exist_ok=True)
MAX_UPLOAD_BYTES = 10 * 1024 * 1024
MAX_FAILED_LOGINS = 5
LOCK_MINUTES = 15
