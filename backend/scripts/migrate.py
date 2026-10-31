"""python -m scripts.migrate [--reset]   Applies backend/db/ALL_IN_ONE.sql to the PostgreSQL database."""
import sys
import psycopg2
from app.config import BASE_DIR, DATABASE_URL

SQL = BASE_DIR / "db" / "ALL_IN_ONE.sql"


def main():
    if not SQL.exists():
        sys.exit(f"Missing {SQL}\nCopy your schema file there first.")
    dsn = DATABASE_URL.replace("postgresql+psycopg2://", "postgresql://", 1)
    conn = psycopg2.connect(dsn)
    conn.autocommit = True  # the SQL file has its own BEGIN/COMMIT
    cur = conn.cursor()
    cur.execute("SELECT to_regclass('public.tbl_users') IS NOT NULL")
    exists = cur.fetchone()[0]
    if exists and "--reset" not in sys.argv:
        sys.exit("Schema already exists. Use --reset to DROP everything and recreate (destroys all data).")
    if exists:
        if input("This DROPS the public schema and all data. Type 'yes': ").strip() != "yes":
            sys.exit("Aborted.")
        cur.execute("DROP SCHEMA public CASCADE; CREATE SCHEMA public;")
    cur.execute(SQL.read_text(encoding="utf-8"))
    print("Schema applied.")


if __name__ == "__main__":
    main()
