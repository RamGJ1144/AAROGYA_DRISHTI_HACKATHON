// Usage: npm run migrate
// Safe to re-run. Adds only what is missing; never drops data.
require('dotenv').config({ path: require('path').join(__dirname, '..', '.env') });
const pool = require('../db');

(async () => {
  try {
    await pool.query(`ALTER TABLE tbl_users ADD COLUMN IF NOT EXISTS status VARCHAR(20) NOT NULL DEFAULT 'APPROVED'`);
    await pool.query(`ALTER TABLE tbl_users ADD COLUMN IF NOT EXISTS is_active BOOLEAN DEFAULT TRUE`);
    await pool.query(`ALTER TABLE tbl_users ADD COLUMN IF NOT EXISTS created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP`);

    // Match the id type used by tbl_users (uuid / integer / bigint)
    const t = await pool.query(
      `SELECT format_type(atttypid, atttypmod) AS type
         FROM pg_attribute WHERE attrelid = 'tbl_users'::regclass AND attname = 'id'`
    );
    const idType = t.rows[0].type;
    const pk = idType === 'uuid' ? 'UUID PRIMARY KEY DEFAULT gen_random_uuid()' : 'SERIAL PRIMARY KEY';

    await pool.query(`
      CREATE TABLE IF NOT EXISTS tbl_patients (
        id ${pk},
        worker_id ${idType} NOT NULL REFERENCES tbl_users(id),
        full_name VARCHAR(150) NOT NULL,
        age INTEGER,
        gender VARCHAR(20),
        phone VARCHAR(20),
        village VARCHAR(150),
        health_condition TEXT,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      )`);
    await pool.query(`
      CREATE TABLE IF NOT EXISTS tbl_media_files (
        id ${pk},
        worker_id ${idType} NOT NULL REFERENCES tbl_users(id),
        file_name TEXT NOT NULL,
        file_type VARCHAR(100),
        file_path TEXT NOT NULL,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      )`);
    await pool.query(`CREATE INDEX IF NOT EXISTS idx_patients_worker ON tbl_patients(worker_id)`);
    await pool.query(`CREATE INDEX IF NOT EXISTS idx_media_worker ON tbl_media_files(worker_id)`);
    console.log('Migration complete (tbl_users.status, tbl_patients, tbl_media_files ready).');
  } catch (err) {
    console.error('Migration failed:', err.message);
    process.exitCode = 1;
  } finally {
    await pool.end();
  }
})();
