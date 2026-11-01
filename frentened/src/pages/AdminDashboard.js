import React, { useEffect, useState } from "react";
import { useNavigate } from "react-router-dom";
import { apiRequest } from "../api";
import "../styles.css";

function AdminDashboard() {
  const navigate = useNavigate();

  const [users, setUsers] = useState([]);
  const [page, setPage] = useState("dashboard");

  const [form, setForm] = useState({
    full_name: "",
    username: "",
    password: "",
    phone: "",
    email: "",
    designation: "ASHA",
    employee_ref: "",
  });

  async function loadUsers() {
    try {
      const data = await apiRequest("/users");
      setUsers(data);
    } catch (error) {
      alert(error.message);
    }
  }

  useEffect(() => {
    loadUsers();
  }, []);

  async function registerUser(e) {
    e.preventDefault();

    try {
      await apiRequest("/users/register", "POST", {
        ...form,
        role: "HEALTH_WORKER",
      });

      alert("Health Worker Registered Successfully!");

      setForm({
        full_name: "",
        username: "",
        password: "",
        phone: "",
        email: "",
        designation: "ASHA",
        employee_ref: "",
      });

      loadUsers();
    } catch (error) {
      alert(error.message);
    }
  }

  function logout() {
    localStorage.clear();
    navigate("/login");
  }

  return (
    <div className="dashboard">

      <aside className="sidebar">

        <h2>✚ AAROGYA</h2>
        <small>DRISHTI</small>

        <p>MAIN MENU</p>

        <button onClick={() => setPage("dashboard")}>
          ▦ Dashboard
        </button>

        <button onClick={() => setPage("register")}>
          + Register User
        </button>

        <button onClick={() => setPage("directory")}>
          ♟ User Directory
        </button>

        <button onClick={logout}>
          ⇥ Logout
        </button>

      </aside>

      <main className="main-content">

        <header className="topbar">
          <div>
            <small>ADMINISTRATION / OVERVIEW</small>
            <h2>Dashboard</h2>
          </div>

          <b>System Administrator</b>
        </header>

        {page === "dashboard" && (
          <>
            <div className="welcome-banner">
              <h5>SYSTEM ADMINISTRATION</h5>
              <h1>Manage your users</h1>
              <p>
                Register healthcare staff, review account information
                and manage your Aarogya Drishti directory.
              </p>
            </div>

            <div className="stats">

              <div className="stat-card">
                <p>Total Users / మొత్తం యూజర్లు</p>
                <h1>{users.length}</h1>
              </div>

              <div className="stat-card">
                <p>Active Accounts / యాక్టివ్</p>
                <h1>{users.filter(u => u.is_active).length}</h1>
              </div>

              <div className="stat-card">
                <p>Health Workers</p>
                <h1>{users.filter(u => u.role === "HEALTH_WORKER").length}</h1>
              </div>

              <div className="stat-card">
                <p>Designations</p>
                <h1>4</h1>
              </div>

            </div>

            <button
              className="primary-button"
              onClick={() => setPage("register")}
            >
              + Register New Health Worker
            </button>

            <button
              className="primary-button"
              onClick={() => setPage("directory")}
            >
              View All Health Workers
            </button>
          </>
        )}

        {page === "register" && (
          <div className="content-card">

            <h2>Register a New User</h2>
            <p>Enter account and contact information.</p>
            <p>కొత్త Health Worker వివరాలు నమోదు చేయండి.</p>

            <form onSubmit={registerUser} className="register-form">

              <label>Full Name / పూర్తి పేరు</label>
              <input
                placeholder="Enter full name"
                value={form.full_name}
                onChange={e => setForm({...form, full_name:e.target.value})}
                required
              />

              <label>Username / యూజర్ పేరు</label>
              <input
                placeholder="Create username"
                value={form.username}
                onChange={e => setForm({...form, username:e.target.value})}
                required
              />

              <label>Phone Number / ఫోన్ నంబర్</label>
              <input
                placeholder="Enter phone"
                value={form.phone}
                onChange={e => setForm({...form, phone:e.target.value})}
              />

              <label>Email Address / ఈమెయిల్</label>
              <input
                type="email"
                placeholder="Enter email"
                value={form.email}
                onChange={e => setForm({...form, email:e.target.value})}
              />

              <label>Designation / హోదా</label>
              <select
                value={form.designation}
                onChange={e => setForm({...form, designation:e.target.value})}
              >
                <option value="ASHA">ASHA</option>
                <option value="ANM">ANM</option>
                <option value="CHO">CHO</option>
                <option value="OTHER">OTHER</option>
              </select>

              <label>Employee Reference</label>
              <input
                value={form.employee_ref}
                onChange={e => setForm({...form, employee_ref:e.target.value})}
              />

              <label>Temporary Password / తాత్కాలిక పాస్‌వర్డ్</label>
              <input
                type="password"
                value={form.password}
                onChange={e => setForm({...form, password:e.target.value})}
                required
              />

              <button className="primary-button">
                Register User →
              </button>

            </form>
          </div>
        )}

        {page === "directory" && (
          <div className="content-card">

            <h2>User Directory / యూజర్ వివరాలు</h2>

            <table>
              <thead>
                <tr>
                  <th>Name</th>
                  <th>Username</th>
                  <th>Phone</th>
                  <th>Designation</th>
                  <th>Dashboard</th>
                </tr>
              </thead>

              <tbody>
                {users.map(user => (
                  <tr key={user.id}>
                    <td>{user.full_name}</td>
                    <td>{user.username}</td>
                    <td>{user.phone}</td>
                    <td>{user.designation}</td>
                    <td>
                      <button
                        onClick={() => navigate(
                          `/worker-dashboard?worker=${user.id}`
                        )}
                      >
                        View
                      </button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>

          </div>
        )}

      </main>
    </div>
  );
}

export default AdminDashboard;