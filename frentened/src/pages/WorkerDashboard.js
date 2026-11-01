import React, { useEffect, useState } from "react";
import { useNavigate, useSearchParams } from "react-router-dom";
import { apiRequest } from "../api";
import "../styles.css";

function WorkerDashboard() {
  const navigate = useNavigate();

  const user = JSON.parse(localStorage.getItem("user"));
  const [searchParams] = useSearchParams();
  const viewWorker = searchParams.get("worker"); // admin viewing a worker
  const isAdmin = user?.role === "ADMIN";

  const [patients, setPatients] = useState([]);
  const [page, setPage] = useState("dashboard");
  const [media, setMedia] = useState([]);
  const [loading, setLoading] = useState(true);

  const [form, setForm] = useState({
    full_name: "",
    age: "",
    gender: "Male",
    phone: "",
    village: "",
    health_condition: "",
  });

  async function loadPatients() {
    try {
      const q = isAdmin && viewWorker ? `?worker=${viewWorker}` : "";
      const data = await apiRequest("/patients" + q);
      setPatients(data);
    } catch (error) {
      alert(error.message);
    } finally {
      setLoading(false);
    }
  }

  async function loadMedia() {
    try {
      if (!isAdmin) setMedia(await apiRequest("/media"));
    } catch (error) {
      console.error(error);
    }
  }

  useEffect(() => {
    loadPatients();
    loadMedia();
    // eslint-disable-next-line
  }, []);

  async function registerPatient(e) {
    e.preventDefault();

    try {
      const saved = await apiRequest("/patients", "POST", form);

      // show instantly, then re-sync with the database
      setPatients(prev => [saved, ...prev]);
      alert("Patient Registered Successfully!");
      setPage("dashboard");

      setForm({
        full_name: "",
        age: "",
        gender: "Male",
        phone: "",
        village: "",
        health_condition: "",
      });

      loadPatients();
    } catch (error) {
      alert(error.message);
    }
  }

  async function uploadMedia(e) {
    const file = e.target.files[0];

    if (!file) return;

    const data = new FormData();
    data.append("media", file);

    try {
      await apiRequest("/media/upload", "POST", data);
      alert("Media Uploaded Successfully!");
      e.target.value = "";
      loadMedia();
    } catch (error) {
      alert(error.message);
    }
  }

  function logout() {
    localStorage.clear();
    navigate("/login");
  }

  const patientRows = (list) => list.map(patient => (
    <tr key={patient.id}>
      <td>{patient.full_name}</td>
      <td>{patient.age}</td>
      <td>{patient.gender}</td>
      <td>{patient.phone}</td>
      <td>{patient.village}</td>
      <td>{patient.health_condition}</td>
    </tr>
  ));

  const patientHead = (
    <thead>
      <tr>
        <th>Name</th><th>Age</th><th>Gender</th>
        <th>Phone</th><th>Village</th><th>Condition</th>
      </tr>
    </thead>
  );

  return (
    <div className="dashboard">

      <aside className="sidebar">

        <h2>✚ AAROGYA</h2>
        <small>DRISHTI</small>

        <p>HEALTH WORKER MENU</p>

        <button onClick={() => setPage("dashboard")}>
          ▦ Dashboard
        </button>

        <button onClick={() => setPage("register")}>
          + Patient Registration
        </button>

        <button onClick={() => setPage("patients")}>
          ♟ Patient Records
        </button>

        <button onClick={() => setPage("media")}>
          ▣ Image & Video Upload
        </button>

        <button onClick={logout}>
          ⇥ Logout
        </button>

      </aside>

      <main className="main-content">

        <header className="topbar">
          <div>
            <small>HEALTH WORKER / OVERVIEW</small>
            <h2>Health Worker Dashboard</h2>
          </div>

          <b>Welcome, {user.full_name}</b>
        </header>

        {page === "dashboard" && (
          <>
            <div className="welcome-banner">
              <h5>HEALTHCARE MANAGEMENT</h5>
              <h1>Welcome {user.full_name}</h1>
              <p>
                Manage your patients and healthcare records.
                <br />
                మీ పేషెంట్స్ వివరాలను ఇక్కడ నిర్వహించండి.
              </p>
            </div>

            <div className="stats">
              <div className="stat-card">
                <p>Total Patients</p>
                <h1>{patients.length}</h1>
              </div>

              <div className="stat-card">
                <p>Designation</p>
                <h1>{user.designation}</h1>
              </div>
            </div>

            <button
              className="primary-button"
              onClick={() => setPage("register")}
            >
              + Register Patient
            </button>

            <button
              className="primary-button"
              onClick={() => setPage("patients")}
            >
              View Patient Records
            </button>

            <div className="content-card recent-patients">
              <h2>Patients / పేషెంట్స్ ({patients.length})</h2>
              {loading ? (
                <p>Loading...</p>
              ) : patients.length === 0 ? (
                <p>No patients registered yet.</p>
              ) : (
                <table>
                  {patientHead}
                  <tbody>{patientRows(patients)}</tbody>
                </table>
              )}
            </div>
          </>
        )}

        {page === "register" && (
          <div className="content-card">

            <h2>Patient Registration</h2>
            <p>పేషెంట్ వివరాలను నమోదు చేయండి.</p>

            <form onSubmit={registerPatient} className="register-form">

              <label>Patient Name / పేరు</label>
              <input
                value={form.full_name}
                onChange={e => setForm({...form, full_name:e.target.value})}
                required
              />

              <label>Age / వయస్సు</label>
              <input
                type="number"
                min="0"
                max="120"
                value={form.age}
                onChange={e => setForm({...form, age:e.target.value})}
                required
              />

              <label>Gender / లింగం</label>
              <select
                value={form.gender}
                onChange={e => setForm({...form, gender:e.target.value})}
              >
                <option>Male</option>
                <option>Female</option>
                <option>Other</option>
              </select>

              <label>Phone Number / ఫోన్ నంబర్</label>
              <input
                value={form.phone}
                onChange={e => setForm({...form, phone:e.target.value})}
              />

              <label>Village / గ్రామం</label>
              <input
                value={form.village}
                onChange={e => setForm({...form, village:e.target.value})}
              />

              <label>Health Condition / ఆరోగ్య వివరాలు</label>
              <textarea
                value={form.health_condition}
                onChange={e => setForm({...form, health_condition:e.target.value})}
              />

              <button className="primary-button">
                Register Patient →
              </button>

            </form>
          </div>
        )}

        {page === "patients" && (
          <div className="content-card">

            <h2>Patient Directory / పేషెంట్ వివరాలు</h2>

            <table>
              {patientHead}
              <tbody>{patientRows(patients)}</tbody>
            </table>

          </div>
        )}

        {page === "media" && (
          <div className="content-card">

            <h2>Media Upload / ఫోటోలు మరియు వీడియోలు</h2>

            <label>Upload Images / చిత్రాలు Upload చేయండి</label>
            <input
              type="file"
              accept="image/*"
              onChange={uploadMedia}
            />

            <label>Upload Videos / వీడియోలు Upload చేయండి</label>
            <input
              type="file"
              accept="video/*"
              onChange={uploadMedia}
            />

            <h3>Uploaded files</h3>
            {media.length === 0 ? <p>None yet.</p> : (
              <ul>
                {media.map(m => (
                  <li key={m.id}>
                    <a href={`http://localhost:5000/${m.file_path}`} target="_blank" rel="noreferrer">
                      {m.file_name}
                    </a>
                  </li>
                ))}
              </ul>
            )}

          </div>
        )}

      </main>
    </div>
  );
}

export default WorkerDashboard;