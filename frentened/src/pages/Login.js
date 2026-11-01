import React, { useState } from "react";
import { useNavigate, Link } from "react-router-dom";
import "../styles.css";

function Login() {
  const navigate = useNavigate();

  const [role, setRole] = useState("ADMIN");
  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const [show, setShow] = useState(false);
  const [error, setError] = useState("");

  async function handleLogin(e) {
    e.preventDefault();

    try {
      const response = await fetch(
        "http://localhost:5000/api/auth/login",
        {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            username,
            password,
            role,
          }),
        }
      );

      const data = await response.json();

      if (!response.ok) {
        throw new Error(data.message);
      }

      localStorage.setItem("token", data.token);
      localStorage.setItem("user", JSON.stringify(data.user));

      if (data.user.role === "ADMIN") {
        navigate("/admin-dashboard");
      } else {
        navigate("/worker-dashboard");
      }
    } catch (err) {
      setError(err.message || "Login failed / Login కాలేదు");
    }
  }

  return (
    <div className="login-container">

      <div className="login-left">
        <h2>✚ AAROGYA DRISHTI</h2>
        <small>Digital Healthcare Platform</small>

        <div className="left-content">
          <h5>HEALTHCARE MANAGEMENT SYSTEM</h5>

          <h1>
            Better Healthcare.
            <br />
            <span>Better Communities.</span>
          </h1>

          <p>
            Empowering healthcare workers with intelligent
            digital solutions for better healthcare management.
          </p>

          <p>✓ Secure Healthcare Access</p>
          <p>✓ Health Worker Management</p>
          <p>✓ Digital Health Monitoring</p>
        </div>

        <footer>© 2026 AAROGYA DRISHTI</footer>
      </div>

      <div className="login-right">

        <form onSubmit={handleLogin} className="login-form">

          <h5>WELCOME BACK</h5>
          <h1>Sign in to your account</h1>

          <p>Access your Aarogya Drishti workspace.</p>

          <div className="role-select">
            <button
              type="button"
              className={role === "HEALTH_WORKER" ? "selected" : ""}
              onClick={() => setRole("HEALTH_WORKER")}
            >
              ♟ Health Worker
            </button>

            <button
              type="button"
              className={role === "ADMIN" ? "selected" : ""}
              onClick={() => setRole("ADMIN")}
            >
              ♟ System Admin
            </button>
          </div>

          <label>Username / యూజర్ పేరు</label>

          <input
            type="text"
            placeholder="Enter your username"
            value={username}
            onChange={(e) => setUsername(e.target.value)}
            required
          />

          <label>Password / పాస్‌వర్డ్</label>

          <div className="password-box">
            <input
              type={show ? "text" : "password"}
              placeholder="Enter your password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              required
            />

            <button type="button" onClick={() => setShow(!show)}>
              {show ? "Hide" : "Show"}
            </button>
          </div>

          {error && <p className="error">{error}</p>}

          <button className="login-button">
            Sign In →
          </button>

          <button
            type="button"
            className="register-button"
            onClick={() => navigate("/register")}
          >
            Register / నమోదు
          </button>

          {role === "HEALTH_WORKER" && (
            <p className="register-link">
              New health worker?{" "}
              <Link to="/register">Register here / నమోదు చేసుకోండి</Link>
            </p>
          )}

          {role === "ADMIN" && (
            <div className="notice">
              <b>Secure Administrator Access</b>
              <p>
                Admin accounts are created only by authorized
                system administrators.
                <br />
                Admin ఖాతాలను అనుమతి ఉన్నవారే సృష్టించాలి.
              </p>
            </div>
          )}

        </form>
      </div>
    </div>
  );
}

export default Login;