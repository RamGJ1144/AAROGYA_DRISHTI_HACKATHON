require("dotenv").config();

const bcrypt = require("bcryptjs");
const pool = require("./db");

// Resets the password of EVERY user (admins + health workers) to Demo@1234
// Usage: node sample.js
async function resetAllPasswords() {
  try {
    const newPassword = "Demo@1234";
    const hash = await bcrypt.hash(newPassword, 12);

    const result = await pool.query(
      `UPDATE tbl_users
       SET password_hash = $1
       RETURNING id, username`,
      [hash]
    );

    console.log(`Updated password for ${result.rowCount} user(s):`);
    result.rows.forEach((u) => console.log(" -", u.username));
    console.log("New password for all users:", newPassword);
  } catch (error) {
    console.log("Error:", error.message);
  } finally {
    await pool.end();
  }
}

resetAllPasswords();
