require("dotenv").config();

const bcrypt = require("bcryptjs");
const pool = require("./db");

async function createAdmin() {
  try {
    const username = "admin";
    const password = "Admin@123";

    const hash = await bcrypt.hash(password, 12);

    await pool.query(
      `INSERT INTO users
       (full_name, username, password_hash, role, is_active)
       VALUES ($1, $2, $3, 'ADMIN', true)
       ON CONFLICT (username) DO NOTHING`,
      ["System Administrator", username, hash]
    );

    console.log("Admin account created successfully!");

  } catch (error) {
    console.log(error.message);
  } finally {
    await pool.end();
  }
}

createAdmin();