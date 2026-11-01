import { useEffect, useState } from 'react';
import { api } from '../api';

const BLOOD = ['', 'A+', 'A-', 'B+', 'B-', 'AB+', 'AB-', 'O+', 'O-'];
const FIELDS = ['name', 'date_of_birth', 'gender', 'blood_group', 'phone', 'emergency_contact'];

export default function Profile({ onNameChange }) {
  const [form, setForm] = useState(null);
  const [email, setEmail] = useState('');
  const [msg, setMsg] = useState('');
  const [error, setError] = useState('');

  useEffect(() => {
    api('/profile').then((p) => {
      setEmail(p.email);
      const f = {};
      FIELDS.forEach((k) => { f[k] = p[k] ? String(p[k]).slice(0, k === 'date_of_birth' ? 10 : undefined) : ''; });
      setForm(f);
    }).catch((e) => setError(e.message));
  }, []);

  const set = (k) => (e) => setForm({ ...form, [k]: e.target.value });

  async function save(e) {
    e.preventDefault();
    setMsg(''); setError('');
    try {
      await api('/profile', { method: 'PUT', body: form });
      onNameChange(form.name);
      setMsg('Saved.');
    } catch (err) { setError(err.message); }
  }

  if (!form) return <p className="muted">{error || 'Loading...'}</p>;

  return (
    <section className="card">
      <h3>Profile</h3>
      <form onSubmit={save}>
        <label>Email<input value={email} disabled /></label>
        <label>Name<input value={form.name} onChange={set('name')} required /></label>
        <div className="row">
          <label>Date of birth<input type="date" value={form.date_of_birth} onChange={set('date_of_birth')} /></label>
          <label>Gender
            <select value={form.gender} onChange={set('gender')}>
              <option value="">-</option><option>female</option><option>male</option><option>other</option>
            </select>
          </label>
          <label>Blood group
            <select value={form.blood_group} onChange={set('blood_group')}>
              {BLOOD.map((b) => <option key={b} value={b}>{b || '-'}</option>)}
            </select>
          </label>
        </div>
        <label>Phone<input value={form.phone} onChange={set('phone')} /></label>
        <label>Emergency contact<input value={form.emergency_contact} onChange={set('emergency_contact')} /></label>
        <button>Save profile</button>
      </form>
      {msg && <p className="ok">{msg}</p>}
      {error && <p className="error">{error}</p>}
    </section>
  );
}
