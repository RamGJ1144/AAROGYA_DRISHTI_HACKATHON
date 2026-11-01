const express = require('express');
const db = require('../db');
const { requireAuth } = require('../middleware/auth');

const router = express.Router();
router.use(requireAuth);

const emptyToNull = (v) => (v === undefined || v === null || v === '' ? null : v);

router.get('/', async (req, res) => {
  const { rows } = await db.query(
    `SELECT u.name, u.email, p.date_of_birth, p.gender, p.blood_group, p.phone, p.emergency_contact
       FROM users u LEFT JOIN profiles p ON p.user_id = u.id WHERE u.id = $1`,
    [req.userId]
  );
  res.json(rows[0] || {});
});

router.put('/', async (req, res) => {
  const b = req.body || {};
  if (b.name !== undefined && !String(b.name).trim()) {
    return res.status(400).json({ error: 'name cannot be empty' });
  }
  if (b.name) await db.query('UPDATE users SET name = $1 WHERE id = $2', [String(b.name).trim(), req.userId]);
  await db.query(
    `INSERT INTO profiles (user_id, date_of_birth, gender, blood_group, phone, emergency_contact, updated_at)
     VALUES ($1,$2,$3,$4,$5,$6,NOW())
     ON CONFLICT (user_id) DO UPDATE SET
       date_of_birth=$2, gender=$3, blood_group=$4, phone=$5, emergency_contact=$6, updated_at=NOW()`,
    [req.userId, emptyToNull(b.date_of_birth), emptyToNull(b.gender), emptyToNull(b.blood_group),
     emptyToNull(b.phone), emptyToNull(b.emergency_contact)]
  );
  res.json({ ok: true });
});

module.exports = router;
