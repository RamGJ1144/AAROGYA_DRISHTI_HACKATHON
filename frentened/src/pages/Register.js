import React, { useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import "../styles.css";

function Register() {
  const navigate = useNavigate();
  const [form, setForm] = useState({
    full_name: "",
    username: "",
    password: "",
    confirm: "",
    phone: "",
    email: "",
    designation: "ASHA",
    employee_ref: "",
  });
  const [error, setError] = useState("");
  const [done, setDone] = useState(false);

  const set = (k) => (e) => setForm({ ...form, [k]: e.target.value });

  async function submit(e) {
    e.preventDefault();
    setError("");
    if (form.password !== form.confirm) {
      return setError("Passwords do not match");
    }
    try {
      const { confirm, ...body } = form;
      const response = await fetch("http://localhost:5000/api/auth/register", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      });
      const data = await response.json().catch(() => ({}));
      if (!response.ok) throw new Error(data.message || "Registration failed");
      setDone(true);
    } catch (err) {
      setError(err.message);
    }
  }

  return (
    <div className="login-container">
      <div className="login-left">
        <h2>✚ AAROGYA DRISHTI</h2>
        <small>Digital Healthcare Platform</small>
        <div className="left-content">
          <h5>HEALTH WORKER REGISTRATION</h5>
          <h1>
            Join the network.
            <br />
            <span>Admin approval required.</span>
          </h1>
          <p>
            After you register, an administrator reviews your request. You can
            sign in once it is approved.
          </p>
        </div>
        <footer>© 2026 AAROGYA DRISHTI</footer>
      </div>

      <div className="login-right">
        {done ? (
          <div className="login-form">
            <h5>REQUEST SENT</h5>
            <h1>Registration submitted</h1>
            <p>
              Your account is waiting for admin approval. You will be able to
              log in once it is approved.
              <br />
              మీ నమోదు Admin ఆమోదం కోసం పంపబడింది.
            </p>
            <button className="login-button" onClick={() => navigate("/login")}>
              Back to Login
            </button>
          </div>
        ) : (
          <form onSubmit={submit} className="login-form">
            <h5>NEW ACCOUNT</h5>
            <h1>Register as Health Worker</h1>

            <label>Full Name / పూర్తి పేరు</label>
            <input value={form.full_name} onChange={set("full_name")} required />

            <label>Username / యూజర్ పేరు</label>
            <input value={form.username} onChange={set("username")} required />

            <label>Phone Number / ఫోన్ నంబర్</label>
            <input value={form.phone} onChange={set("phone")} />

            <label>Email / ఈమెయిల్</label>
            <input type="email" value={form.email} onChange={set("email")} />

            <label>Designation / హోదా</label>
            <select value={form.designation} onChange={set("designation")}>
              <option value="ASHA">ASHA</option>
              <option value="ANM">ANM</option>
              <option value="CHO">CHO</option>
              <option value="OTHER">OTHER</option>
            </select>

            <label>Employee Reference</label>
            <input value={form.employee_ref} onChange={set("employee_ref")} />

            <label>Password (min 8 characters)</label>
            <input type="password" value={form.password} onChange={set("password")} required minLength={8} />

            <label>Confirm Password</label>
            <input type="password" value={form.confirm} onChange={set("confirm")} required minLength={8} />

            {error && <p className="error">{error}</p>}

            <button className="login-button">Submit Registration →</button>

            <p className="register-link">
              Already approved? <Link to="/login">Sign in</Link>
            </p>
          </form>
        )}
      </div>
    </div>
  );
}

export default Register;
