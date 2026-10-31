import { useEffect, useState } from 'react';
import './App.css';
import { api, getToken, setToken } from './api';
import Auth from './components/Auth';
import Patients from './components/Patients';
import Screenings from './components/Screenings';
import Approvals from './components/Approvals';
import useLiveUpdates from './useLiveUpdates';

const CLINICAL = { patients: ['Patients', Patients], screenings: ['Screenings', Screenings] };
const ADMIN = { approvals: ['Approvals', Approvals] };

function tabsFor(role) {
  if (role === 'SYSTEM_ADMIN') return ADMIN;
  if (['HEALTH_WORKER', 'MEDICAL_OFFICER', 'SPECIALIST'].includes(role)) return CLINICAL;
  return {};
}

function App() {
  const [user, setUser] = useState(null);
  const [checking, setChecking] = useState(!!getToken());
  const [tab, setTab] = useState(null);
  const [version, setVersion] = useState(0);
  // Any server push (this or another device) remounts the active tab so it refetches.
  useLiveUpdates(!!user, () => setVersion((v) => v + 1));

  useEffect(() => {
    if (getToken()) {
      api('/auth/me').then(setUser).catch(() => setToken(null)).finally(() => setChecking(false));
    }
    const onLogout = () => setUser(null);
    window.addEventListener('ad-logout', onLogout);
    return () => window.removeEventListener('ad-logout', onLogout);
  }, []);

  async function logout() {
    try { await api('/auth/logout', { method: 'POST' }); } catch { /* ignore */ }
    setToken(null);
    setUser(null);
    setTab(null);
  }

  if (checking) return <p className="muted center">Loading...</p>;

  const tabs = user ? tabsFor(user.role) : {};
  const keys = Object.keys(tabs);
  const current = tab && tabs[tab] ? tab : keys[0];
  const Active = current ? tabs[current][1] : null;

  return (
    <div className="app">
      <header className="topbar">
        <h1>Aarogya Drishti</h1>
        {user && (
          <div className="user">
            <span>{user.name} <span className="tag">{user.role}</span></span>
            <button onClick={logout}>Log out</button>
          </div>
        )}
      </header>
      <main>
        {!user ? <Auth onLogin={setUser} /> : (
          <>
            <nav className="tabs">
              {keys.map((key) => (
                <button key={key} className={current === key ? 'active' : ''} onClick={() => setTab(key)}>{tabs[key][0]}</button>
              ))}
            </nav>
            {Active ? <Active key={`${current}-${version}`} user={user} />
              : <p className="muted">No screens are available for your role in this demo.</p>}
          </>
        )}
      </main>
    </div>
  );
}

export default App;
