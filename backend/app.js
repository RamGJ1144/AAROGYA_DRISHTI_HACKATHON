const path = require('path');
const fs = require('fs');
const express = require('express');
const cors = require('cors');
require('dotenv').config({ path: path.join(__dirname, '.env') });
const db = require('./db');

const app = express();
app.use(cors({ origin: process.env.CORS_ORIGIN || 'http://localhost:3000' }));
app.use(express.json());

// Health check / DB connection test (kept from the original scaffold)
app.get('/test-db', async (req, res) => {
  try {
    const result = await db.query('SELECT NOW()');
    res.json({ message: 'Database connected successfully!', currentTime: result.rows[0].now });
  } catch (err) {
    console.error(err.message);
    res.status(500).send('Server Error');
  }
});

app.use('/api/auth', require('./routes/auth'));
app.use('/api/profile', require('./routes/profile'));
app.use('/api/records', require('./routes/records'));
app.use('/api/vitals', require('./routes/vitals'));
app.use('/api/images', require('./routes/images'));

// Serve the built React app if present (npm run build:client)
const clientBuild = path.join(__dirname, '..', 'frentened', 'build');
if (fs.existsSync(clientBuild)) {
  app.use(express.static(clientBuild));
  app.get(/^\/(?!api\/).*/, (req, res) => res.sendFile(path.join(clientBuild, 'index.html')));
}

app.use('/api', (req, res) => res.status(404).json({ error: 'Not found' }));

// Central error handler (Express 5 forwards async errors here automatically)
// eslint-disable-next-line no-unused-vars
app.use((err, req, res, next) => {
  if (err.code === 'LIMIT_FILE_SIZE') return res.status(400).json({ error: 'File too large (max 10 MB)' });
  if (err.code === '22P02' || err.code === '22007' || err.code === '22008') {
    return res.status(400).json({ error: 'Invalid input' });
  }
  if (err.status && err.status < 500) return res.status(err.status).json({ error: err.message });
  console.error(err);
  res.status(500).json({ error: 'Server error' });
});

module.exports = app;
