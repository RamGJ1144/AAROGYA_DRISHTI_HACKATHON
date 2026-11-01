const express = require("express");
const cors = require("cors");
const bcrypt = require("bcryptjs");
const jwt = require("jsonwebtoken");
const multer = require("multer");
const path = require("path");
const fs = require("fs");
require("dotenv").config();

const pool = require("./db");
// Note: authenticate and adminOnly middleware files unna validate chesukondi
// const { authenticate, adminOnly } = require("./middleware/auth");

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

// Basic test route to check if server is running
app.get("/", (req, res) => {
  res.send("Arogya Drishti Backend Server is Running!");
});

// START SERVER (Very Important for making it runnable)
const PORT = process.env.PORT || 5000;
app.listen(PORT, () => {
  console.log(`Server is running successfully on http://localhost:${PORT}`);
});