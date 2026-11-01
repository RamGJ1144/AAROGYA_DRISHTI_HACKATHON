import React from "react";
import { BrowserRouter, Routes, Route, Navigate } from "react-router-dom";

import Login from "./pages/Login";
import AdminDashboard from "./pages/AdminDashboard";
import WorkerDashboard from "./pages/WorkerDashboard";

function App() {
  const user = JSON.parse(localStorage.getItem("user"));

  return (
    <BrowserRouter>
      <Routes>
        <Route path="/login" element={<Login />} />

        <Route
          path="/admin-dashboard"
          element={
            user?.role === "ADMIN"
              ? <AdminDashboard />
              : <Navigate to="/login" />
          }
        />

        <Route
          path="/worker-dashboard"
          element={
            user?.role === "HEALTH_WORKER"
              ? <WorkerDashboard />
              : <Navigate to="/login" />
          }
        />

        <Route path="*" element={<Navigate to="/login" />} />
      </Routes>
    </BrowserRouter>
  );
}

export default App;