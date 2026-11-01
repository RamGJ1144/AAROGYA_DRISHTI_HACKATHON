const express = require('express');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const multer = require('multer');
const db = require('../db');
const { requireAuth } = require('../middleware/auth');
const imageAnalysis = require('../services/imageAnalysis');

const router = express.Router();
router.use(requireAuth);

const UPLOAD_DIR = path.join(__dirname, '..', 'uploads');
fs.mkdirSync(UPLOAD_DIR, { recursive: true });

const EXT = { 'image/jpeg': '.jpg', 'image/png': '.png', 'image/webp': '.webp' };

const upload = multer({
  storage: multer.diskStorage({
    destination: UPLOAD_DIR,
    // Random server-side name; the user's filename is never used on disk.
    filename: (req, file, cb) => cb(null, crypto.randomUUID() + (EXT[file.mimetype] || '')),
  }),
  limits: { fileSize: 10 * 1024 * 1024 },
  fileFilter: (req, file, cb) => {
    if (EXT[file.mimetype]) return cb(null, true);
    cb(Object.assign(new Error('Only JPEG, PNG or WebP images are allowed'), { status: 400 }));
  },
});

router.get('/', async (req, res) => {
  const { rows } = await db.query(
    `SELECT id, original_name, mime_type, size_bytes, description, analysis_status, analysis_result, created_at
       FROM images WHERE user_id = $1 ORDER BY created_at DESC`,
    [req.userId]
  );
  res.json(rows);
});

router.post('/', upload.single('image'), async (req, res) => {
  if (!req.file) return res.status(400).json({ error: 'Attach an image in the "image" field' });
  const { rows } = await db.query(
    `INSERT INTO images (user_id, filename, original_name, mime_type, size_bytes, description)
     VALUES ($1,$2,$3,$4,$5,$6)
     RETURNING id, original_name, mime_type, size_bytes, description, analysis_status, created_at`,
    [req.userId, req.file.filename, req.file.originalname, req.file.mimetype, req.file.size, req.body.description || null]
  );
  res.status(201).json(rows[0]);
});

async function findOwn(req) {
  const { rows } = await db.query('SELECT * FROM images WHERE id = $1 AND user_id = $2', [req.params.id, req.userId]);
  return rows[0];
}

// Authenticated file download (uploads are not served statically).
router.get('/:id/file', async (req, res) => {
  const img = await findOwn(req);
  if (!img) return res.status(404).json({ error: 'Image not found' });
  res.type(img.mime_type).sendFile(path.join(UPLOAD_DIR, img.filename));
});

// Placeholder hook for AI analysis. Returns 501 until services/imageAnalysis.js is implemented.
router.post('/:id/analyze', async (req, res) => {
  const img = await findOwn(req);
  if (!img) return res.status(404).json({ error: 'Image not found' });
  if (!imageAnalysis.available) {
    return res.status(501).json({ error: 'AI image analysis is not available yet' });
  }
  try {
    const result = await imageAnalysis.analyze({
      filePath: path.join(UPLOAD_DIR, img.filename), mimeType: img.mime_type, description: img.description,
    });
    const { rows } = await db.query(
      `UPDATE images SET analysis_status='done', analysis_result=$1 WHERE id=$2 RETURNING analysis_status, analysis_result`,
      [JSON.stringify(result), img.id]
    );
    res.json(rows[0]);
  } catch (err) {
    await db.query(`UPDATE images SET analysis_status='failed' WHERE id=$1`, [img.id]);
    throw err;
  }
});

router.delete('/:id', async (req, res) => {
  const img = await findOwn(req);
  if (!img) return res.status(404).json({ error: 'Image not found' });
  await db.query('DELETE FROM images WHERE id = $1', [img.id]);
  fs.unlink(path.join(UPLOAD_DIR, img.filename), () => {});
  res.status(204).end();
});

module.exports = router;
