require("dotenv").config();

const bcrypt = require("bcryptjs");
const pool = require("./db");

async function resetPassword() {
  try {
    // మీ కొత్త password ఇక్కడ పెట్టండి
    const newPassword = "Demo@1234";

    const hash = await bcrypt.hash(newPassword, 12);

    const result = await pool.query(
      `UPDATE tbl_users
       SET password_hash = $1
       WHERE username = $2
       AND role_id = 1
       RETURNING id, username`,
      [hash, "asha1"]
    );

    if (result.rows.length === 0) {
      console.log("Admin account asha1 not found.");
    } else {
      console.log("Admin password updated successfully!");
      console.log("Username:", result.rows[0].username);
      console.log("New password:", newPassword);
    }

  } catch (error) {
    console.log("Error:", error.message);
  } finally {
    await pool.end();
  }
}

resetPassword();