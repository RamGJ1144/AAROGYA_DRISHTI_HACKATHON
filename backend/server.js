const express = require("express");
const cors = require("cors");
const bcrypt = require("bcryptjs");
const jwt = require("jsonwebtoken");
const multer = require("multer");
const path = require("path");
const fs = require("fs");
require("dotenv").config();

const pool = require("./db");
const { authenticate, adminOnly } = require("./middleware/auth");

const app = express();

app.use(cors({
  origin: "http://localhost:3000"
}));

app.use(express.json());

if (!fs.existsSync("uploads")) {
  fs.mkdirSync("uploads");
}

app.use("/uploads", express.static("uploads"));

const storage = multer.diskStorage({
  destination: "uploads/",
  filename: (req, file, cb) => {
    cb(null, Date.now() + path.extname(file.originalname));
  },
});

const upload = multer({
  storage,
  limits: { fileSize: 50 * 1024 * 1024 },
  fileFilter: (req, file, cb) => {
    const allowed = /jpeg|jpg|png|gif|mp4|webm|mov/;
    const valid = allowed.test(
      path.extname(file.originalname).toLowerCase()
    );

    cb(valid ? null : new Error("Unsupported file type"), valid);
  },
});

// ADMIN AND HEALTH WORKER LOGIN ROUTE
app.post("/api/auth/login", async (req, res) => {
  try {
    const { username, password, role } = req.body || {};

    if (!username || !password || !role) {
      return res.status(400).json({
        message: "Username, password and role are required"
      });
    }

    // Convert frontend role into database role code
    const selectedRole = String(role)
      .trim()
      .toUpperCase()
      .replace(/[\s-]+/g, "_");

    const roleMap = {
      "ADMIN": "SYSTEM_ADMIN",
      "SYSTEM_ADMIN": "SYSTEM_ADMIN",
      "SYSTEM ADMIN": "SYSTEM_ADMIN",
      "HEALTH_WORKER": "HEALTH_WORKER",
      "HEALTH WORKER": "HEALTH_WORKER"
    };

    const roleCode = roleMap[selectedRole];

    if (!roleCode) {
      return res.status(400).json({
        message: "Invalid selected role"
      });
    }

    // Get user from tbl_users and role from mst_roles
    const result = await pool.query(
      `SELECT
          u.id,
          u.username,
          u.full_name,
          u.password_hash,
          u.phone,
          u.email,
          u.designation,
          u.employee_ref,
          u.role_id,
          u.status,
          r.code AS role
       FROM tbl_users u
       INNER JOIN mst_roles r
          ON r.id = u.role_id
       WHERE LOWER(u.username) = LOWER($1)
         AND r.code = $2
         AND r.is_active = TRUE`,
      [String(username).trim(), roleCode]
    );

    if (result.rows.length === 0) {
      return res.status(401).json({
        message: "Invalid username or role"
      });
    }

    const user = result.rows[0];

    // Verify password
    const validPassword = await bcrypt.compare(
      String(password),
      user.password_hash
    );

    if (!validPassword) {
      return res.status(401).json({
        message: "Incorrect password"
      });
    }

    // Only admin-approved accounts may log in
    if (user.status === "PENDING") {
      return res.status(403).json({
        message: "Your registration is pending admin approval. / మీ నమోదు Admin ఆమోదం కోసం వేచి ఉంది."
      });
    }
    if (user.status === "REJECTED") {
      return res.status(403).json({
        message: "Your registration was rejected by the admin. / మీ నమోదు తిరస్కరించబడింది."
      });
    }

    // Frontend + middleware use "ADMIN" / "HEALTH_WORKER"
    user.role = user.role === "SYSTEM_ADMIN" ? "ADMIN" : user.role;

    // Generate JWT token
    const token = jwt.sign(
      {
        id: user.id,
        role: user.role
      },
      process.env.JWT_SECRET || "fallback_secret",
      { expiresIn: "8h" }
    );

    delete user.password_hash;

    return res.status(200).json({
      message: "Login successful",
      token,
      user
    });

  } catch (error) {
    console.error("Login Error:", error);

    return res.status(500).json({
      message: "Login failed",
      error: error.message
    });
  }
});

// ---------- helpers ----------
const USER_COLS = `u.id, u.username, u.full_name, u.phone, u.email, u.designation,
  u.employee_ref, u.status, u.is_active, u.created_at,
  CASE WHEN r.code = 'SYSTEM_ADMIN' THEN 'ADMIN' ELSE r.code END AS role`;

const DESIGNATIONS = ["ASHA", "ANM", "CHO", "OTHER"];

async function createUser(b, status) {
  const full_name = String(b.full_name || "").trim();
  const username = String(b.username || "").trim();
  const password = String(b.password || "");
  if (!full_name || !username || !password) {
    const e = new Error("Full name, username and password are required");
    e.status = 400;
    throw e;
  }
  if (password.length < 8) {
    const e = new Error("Password must be at least 8 characters");
    e.status = 400;
    throw e;
  }
  const designation = DESIGNATIONS.includes(b.designation) ? b.designation : "OTHER";
  const dup = await pool.query(
    "SELECT 1 FROM tbl_users WHERE LOWER(username) = LOWER($1)", [username]
  );
  if (dup.rows.length) {
    const e = new Error("Username already taken");
    e.status = 409;
    throw e;
  }
  const role = await pool.query("SELECT id FROM mst_roles WHERE code = 'HEALTH_WORKER'");
  if (!role.rows.length) {
    const e = new Error("HEALTH_WORKER role missing in mst_roles");
    e.status = 500;
    throw e;
  }
  const hash = await bcrypt.hash(password, 12);
  const { rows } = await pool.query(
    `INSERT INTO tbl_users
       (full_name, username, password_hash, phone, email, designation, employee_ref, role_id, status)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
     RETURNING id, username, full_name, status`,
    [full_name, username, hash, b.phone || null, b.email || null, designation,
     b.employee_ref || null, role.rows[0].id, status]
  );
  return rows[0];
}

function handleError(res, error, label) {
  if (error.status) return res.status(error.status).json({ message: error.message });
  console.error(label, error);
  return res.status(500).json({ message: label + " failed", error: error.message });
}

// ---------- PUBLIC SELF-REGISTRATION (needs admin approval) ----------
app.post("/api/auth/register", async (req, res) => {
  try {
    await createUser(req.body || {}, "PENDING");
    res.status(201).json({
      message: "Registration submitted. You can log in once an admin approves your account."
    });
  } catch (error) {
    handleError(res, error, "Registration");
  }
});

// ---------- ADMIN: USERS ----------
app.get("/api/users", authenticate, adminOnly, async (req, res) => {
  try {
    const { status } = req.query;
    const params = [];
    let where = "WHERE r.code = 'HEALTH_WORKER'";
    if (status) { params.push(String(status).toUpperCase()); where += " AND u.status = $1"; }
    const { rows } = await pool.query(
      `SELECT ${USER_COLS} FROM tbl_users u
       INNER JOIN mst_roles r ON r.id = u.role_id ${where}
       ORDER BY u.created_at DESC`, params
    );
    res.json(rows);
  } catch (error) { handleError(res, error, "Load users"); }
});

// Admin creates a worker directly (auto-approved)
app.post("/api/users/register", authenticate, adminOnly, async (req, res) => {
  try {
    const user = await createUser(req.body || {}, "APPROVED");
    res.status(201).json(user);
  } catch (error) { handleError(res, error, "Register user"); }
});

app.patch("/api/users/:id/status", authenticate, adminOnly, async (req, res) => {
  try {
    const status = String(req.body?.status || "").toUpperCase();
    if (!["APPROVED", "REJECTED"].includes(status)) {
      return res.status(400).json({ message: "Status must be APPROVED or REJECTED" });
    }
    const { rows } = await pool.query(
      "UPDATE tbl_users SET status = $1 WHERE id = $2 RETURNING id, username, status",
      [status, req.params.id]
    );
    if (!rows.length) return res.status(404).json({ message: "User not found" });
    res.json(rows[0]);
  } catch (error) { handleError(res, error, "Update status"); }
});

// ---------- PATIENTS (saved directly to DB) ----------
// Workers see their own patients; admins may pass ?worker=<id> (or see all)
app.get("/api/patients", authenticate, async (req, res) => {
  try {
    const params = [];
    let where = "";
    if (req.user.role === "ADMIN") {
      if (req.query.worker) { params.push(req.query.worker); where = "WHERE worker_id = $1"; }
    } else {
      params.push(req.user.id); where = "WHERE worker_id = $1";
    }
    const { rows } = await pool.query(
      `SELECT * FROM tbl_patients ${where} ORDER BY created_at DESC`, params
    );
    res.json(rows);
  } catch (error) { handleError(res, error, "Load patients"); }
});

app.post("/api/patients", authenticate, async (req, res) => {
  try {
    const b = req.body || {};
    const name = String(b.full_name || "").trim();
    const age = parseInt(b.age, 10);
    if (!name) return res.status(400).json({ message: "Patient name is required" });
    if (Number.isNaN(age) || age < 0 || age > 120) {
      return res.status(400).json({ message: "Enter a valid age (0-120)" });
    }
    const { rows } = await pool.query(
      `INSERT INTO tbl_patients (worker_id, full_name, age, gender, phone, village, health_condition)
       VALUES ($1,$2,$3,$4,$5,$6,$7) RETURNING *`,
      [req.user.id, name, age, b.gender || null, b.phone || null,
       b.village || null, b.health_condition || null]
    );
    res.status(201).json(rows[0]);
  } catch (error) { handleError(res, error, "Save patient"); }
});

// ---------- MEDIA ----------
app.post("/api/media/upload", authenticate, (req, res) => {
  upload.single("media")(req, res, async (err) => {
    if (err) return res.status(400).json({ message: err.message });
    if (!req.file) return res.status(400).json({ message: "No file uploaded" });
    try {
      const { rows } = await pool.query(
        `INSERT INTO tbl_media_files (worker_id, file_name, file_type, file_path)
         VALUES ($1,$2,$3,$4) RETURNING *`,
        [req.user.id, req.file.originalname, req.file.mimetype, "uploads/" + req.file.filename]
      );
      res.status(201).json(rows[0]);
    } catch (error) { handleError(res, error, "Upload"); }
  });
});

app.get("/api/media", authenticate, async (req, res) => {
  try {
    const { rows } = await pool.query(
      "SELECT * FROM tbl_media_files WHERE worker_id = $1 ORDER BY created_at DESC",
      [req.user.id]
    );
    res.json(rows);
  } catch (error) { handleError(res, error, "Load media"); }
});

// Basic test route to check if server is running
app.get("/", (req, res) => {
  res.send("Arogya Drishti Backend Server is Running!");
});

// START SERVER (Very Important for making it runnable)
const PORT = process.env.PORT || 5000;
app.listen(PORT, () => {
  console.log(`Server is running successfully on http://localhost:${PORT}`);
});