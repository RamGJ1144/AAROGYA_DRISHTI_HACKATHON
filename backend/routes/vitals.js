const express = require('express');
const db = require('../db');
const { requireAuth } = require('../middleware/auth');

const router = express.Router();
router.use(requireAuth);

const FIELDS = ['systolic', 'diastolic', 'heart_rate', 'blood_sugar', 'weight_kg'];

function parseVitals(body) {
  const out = {};
  for (const f of FIELDS) {
    const v = body[f];
    if (v === undefined || v === null || v === '') { out[f] = null; continue; }
    const n = Number(v);
    if (!Number.isFinite(n) || n <= 0) return { error: `${f} must be a positive number` };
    out[f] = n;
  }
  if (FIELDS.every((f) => out[f] === null)) return { error: 'Enter at least one measurement' };
  if ((out.systolic === null) !== (out.diastolic === null)) {
    return { error: 'Enter both systolic and diastolic blood pressure' };
  }
  return { values: out };
}

router.get('/', async (req, res) => {
  const { rows } = await db.query(
    'SELECT * FROM vitals WHERE user_id = $1 ORDER BY measured_at DESC LIMIT 200',
    [req.userId]
  );
  res.json(rows);
});

router.post('/', async (req, res) => {
  const { values, error } = parseVitals(req.body || {});
  if (error) return res.status(400).json({ error });
  const { rows } = await db.query(
    `INSERT INTO vitals (user_id, measured_at, systolic, diastolic, heart_rate, blood_sugar, weight_kg, notes)
     VALUES ($1, COALESCE($2, NOW()), $3,$4,$5,$6,$7,$8) RETURNING *`,
    [req.userId, req.body.measured_at || null, values.systolic, values.diastolic,
     values.heart_rate, values.blood_sugar, values.weight_kg, req.body.notes || null]
  );
  res.status(201).json(rows[0]);
});

router.delete('/:id', async (req, res) => {
  const { rowCount } = await db.query('DELETE FROM vitals WHERE id = $1 AND user_id = $2', [req.params.id, req.userId]);
  if (!rowCount) return res.status(404).json({ error: 'Entry not found' });
  res.status(204).end();
});

module.exports = router;
