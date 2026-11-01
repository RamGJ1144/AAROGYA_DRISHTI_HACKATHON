const express = require('express');
const db = require('../db');
const { requireAuth } = require('../middleware/auth');

const router = express.Router();
router.use(requireAuth);

const TYPES = ['checkup', 'prescription', 'lab', 'vaccination', 'surgery', 'other'];

router.get('/', async (req, res) => {
  const { rows } = await db.query(
    'SELECT * FROM health_records WHERE user_id = $1 ORDER BY record_date DESC, id DESC',
    [req.userId]
  );
  res.json(rows);
});

router.post('/', async (req, res) => {
  const { title, record_type = 'other', record_date, notes } = req.body || {};
  if (!title || !String(title).trim()) return res.status(400).json({ error: 'title is required' });
  if (!TYPES.includes(record_type)) return res.status(400).json({ error: `record_type must be one of: ${TYPES.join(', ')}` });
  const { rows } = await db.query(
    `INSERT INTO health_records (user_id, title, record_type, record_date, notes)
     VALUES ($1,$2,$3,COALESCE($4, CURRENT_DATE),$5) RETURNING *`,
    [req.userId, String(title).trim(), record_type, record_date || null, notes || null]
  );
  res.status(201).json(rows[0]);
});

router.put('/:id', async (req, res) => {
  const { title, record_type, record_date, notes } = req.body || {};
  if (record_type && !TYPES.includes(record_type)) return res.status(400).json({ error: 'Invalid record_type' });
  if (title !== undefined && !String(title).trim()) return res.status(400).json({ error: 'title cannot be empty' });
  const { rows } = await db.query(
    `UPDATE health_records SET
       title = COALESCE($3, title), record_type = COALESCE($4, record_type),
       record_date = COALESCE($5, record_date), notes = COALESCE($6, notes)
     WHERE id = $1 AND user_id = $2 RETURNING *`,
    [req.params.id, req.userId, title ? String(title).trim() : null, record_type || null, record_date || null, notes ?? null]
  );
  if (!rows[0]) return res.status(404).json({ error: 'Record not found' });
  res.json(rows[0]);
});

router.delete('/:id', async (req, res) => {
  const { rowCount } = await db.query('DELETE FROM health_records WHERE id = $1 AND user_id = $2', [req.params.id, req.userId]);
  if (!rowCount) return res.status(404).json({ error: 'Record not found' });
  res.status(204).end();
});

module.exports = router;
