import { useEffect, useState } from 'react';
import { api, setToken } from '../api';

const blankReg = { full_name: '', username: '', phone: '', designation: 'ASHA', employee_ref: '', facility_id: '', language_id: '', password: '', terms_accepted: false };

export default function Auth({ onLogin }) {
  const [mode, setMode] = useState('login');
  const [login, setLogin] = useState({ username: '', password: '' });
  const [reg, setReg] = useState(blankReg);
  const [masters, setMasters] = useState(null);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (mode === 'register' && !masters) api('/masters').then(setMasters).catch((e) => setError(e.message));
  }, [mode, masters]);

  const setL = (k) => (e) => setLogin({ ...login, [k]: e.target.value });
  const setR = (k) => (e) => setReg({ ...reg, [k]: e.target.type === 'checkbox' ? e.target.checked : e.target.value });

  async function submit(e) {
    e.preventDefault();
    setError(''); setNotice(''); setBusy(true);
    try {
      if (mode === 'login') {
        const data = await api('/auth/login', { method: 'POST', body: login });
        setToken(data.token);
        onLogin(data.user);
      } else {
        const data = await api('/auth/register', {
          method: 'POST',
          body: { ...reg, facility_id: Number(reg.facility_id) || null, language_id: Number(reg.language_id) || null },
        });
        setNotice(data.message);
        setReg(blankReg);
        setMode('login');
      }
    } catch (err) { setError(err.message); } finally { setBusy(false); }
  }

  return (
    <div className="card auth">
      <h2>{mode === 'login' ? 'Log in' : 'Request an account'}</h2>
      <form onSubmit={submit}>
        {mode === 'login' ? (
          <>
            <label>Username<input value={login.username} onChange={setL('username')} required /></label>
            <label>Password<input type="password" value={login.password} onChange={setL('password')} required /></label>
          </>
        ) : (
          <>
            <label>Full name<input value={reg.full_name} onChange={setR('full_name')} required /></label>
            <label>Username<input value={reg.username} onChange={setR('username')} required /></label>
            <label>Phone<input value={reg.phone} onChange={setR('phone')} required /></label>
            <div className="row">
              <label>Designation
                <select value={reg.designation} onChange={setR('designation')}>
                  {(masters?.designations || ['ASHA', 'ANM', 'CHO', 'OTHER']).map((d) => <option key={d}>{d}</option>)}
                </select>
              </label>
              <label>Employee ref (optional)<input value={reg.employee_ref} onChange={setR('employee_ref')} /></label>
            </div>
            <div className="row">
              <label>Facility
                <select value={reg.facility_id} onChange={setR('facility_id')} required>
                  <option value="">Select...</option>
                  {masters?.facilities.map((f) => <option key={f.id} value={f.id}>{f.name_en}</option>)}
                </select>
              </label>
              <label>Language
                <select value={reg.language_id} onChange={setR('language_id')} required>
                  <option value="">Select...</option>
                  {masters?.languages.map((l) => <option key={l.id} value={l.id}>{l.name_en} ({l.native_name})</option>)}
                </select>
              </label>
            </div>
            <label>Password<input type="password" minLength={8} value={reg.password} onChange={setR('password')} required /></label>
            <label><input type="checkbox" checked={reg.terms_accepted} onChange={setR('terms_accepted')} /> I accept the terms (demonstration, synthetic data only)</label>
          </>
        )}
        {error && <p className="error">{error}</p>}
        {notice && <p className="ok">{notice}</p>}
        <button disabled={busy}>{mode === 'login' ? 'Log in' : 'Submit request'}</button>
      </form>
      <p className="muted">
        {mode === 'login' ? 'Health worker without an account? ' : 'Already approved? '}
        <button className="link" type="button" onClick={() => { setMode(mode === 'login' ? 'register' : 'login'); setError(''); setNotice(''); }}>
          {mode === 'login' ? 'Request an account' : 'Log in'}
        </button>
      </p>
    </div>
  );
}
