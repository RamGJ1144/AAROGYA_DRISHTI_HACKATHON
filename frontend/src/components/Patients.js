import { useEffect, useState } from 'react';
import { api } from '../api';

const blank = { full_name: '', sex: 'UNDISCLOSED', date_of_birth: '', age_years: '', village_id: '', contact_phone: '' };

export default function Patients({ user }) {
  const isHW = user.role === 'HEALTH_WORKER';
  const [items, setItems] = useState([]);
  const [masters, setMasters] = useState(null);
  const [form, setForm] = useState(blank);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');

  const load = () => api('/patients').then(setItems).catch((e) => setError(e.message));
  // eslint-disable-next-line react-hooks/exhaustive-deps
  useEffect(() => { load(); api('/masters').then(setMasters).catch(() => {}); }, []);
  const set = (k) => (e) => setForm({ ...form, [k]: e.target.value });

  async function add(e) {
    e.preventDefault();
    setError(''); setNotice('');
    try {
      const body = { ...form, age_years: form.age_years === '' ? null : Number(form.age_years),
        date_of_birth: form.date_of_birth || null, village_id: form.village_id ? Number(form.village_id) : null };
      const p = await api('/patients', { method: 'POST', body });
      setNotice(`Registered ${p.patient_code}` + (p.duplicate_warnings?.length ? ` - possible duplicate of ${p.duplicate_warnings.map((d) => d.patient_code).join(', ')}` : ''));
      setForm(blank); load();
    } catch (err) { setError(err.message); }
  }

  async function consent(id, purpose, granted) {
    setError('');
    try { await api(`/patients/${id}/consents`, { method: 'POST', body: { purpose_code: purpose, granted } }); load(); }
    catch (err) { setError(err.message); }
  }

  async function screen(id) {
    setError(''); setNotice('');
    try { await api(`/patients/${id}/screenings`, { method: 'POST', body: {} }); setNotice('Screening started - see the Screenings tab'); }
    catch (err) { setError(err.message); }
  }

  return (
    <section>
      {isHW && (
        <div className="card">
          <h3>Register patient</h3>
          <form onSubmit={add}>
            <label>Full name<input value={form.full_name} onChange={set('full_name')} required /></label>
            <div className="row">
              <label>Sex
                <select value={form.sex} onChange={set('sex')}>
                  {['FEMALE', 'MALE', 'OTHER', 'UNDISCLOSED'].map((s) => <option key={s}>{s}</option>)}
                </select>
              </label>
              <label>Date of birth<input type="date" value={form.date_of_birth} onChange={set('date_of_birth')} /></label>
              <label>or Age<input type="number" min="0" max="120" value={form.age_years} onChange={set('age_years')} /></label>
            </div>
            <div className="row">
              <label>Village
                <select value={form.village_id} onChange={set('village_id')}>
                  <option value="">-</option>
                  {masters?.villages.map((v) => <option key={v.id} value={v.id}>{v.name_en}</option>)}
                </select>
              </label>
              <label>Phone<input value={form.contact_phone} onChange={set('contact_phone')} /></label>
            </div>
            <button>Register</button>
          </form>
        </div>
      )}
      {error && <p className="error">{error}</p>}
      {notice && <p className="ok">{notice}</p>}
      <div className="card">
        <h3>Patients</h3>
        {items.length === 0 ? <p className="muted">No patients yet.</p> : (
          <ul className="list">
            {items.map((p) => (
              <li key={p.id}>
                <div className="grow">
                  <strong>{p.full_name}</strong> <span className="tag">{p.patient_code}</span>
                  <div className="muted">{p.sex} · {p.age_years ?? String(p.date_of_birth).slice(0, 10)} · {p.village || 'no village'}</div>
                  {isHW && (
                    <div className="actions">
                      {['SCREENING', 'IMAGE_CAPTURE', 'DATA_PROCESSING'].map((c) => (
                        <button key={c} className={p.consents?.[c] ? '' : 'link'} onClick={() => consent(p.id, c, !p.consents?.[c])}>
                          {p.consents?.[c] ? `✓ ${c} (withdraw)` : `Grant ${c}`}
                        </button>
                      ))}
                      {p.consents?.SCREENING && <button onClick={() => screen(p.id)}>Start screening</button>}
                    </div>
                  )}
                </div>
              </li>
            ))}
          </ul>
        )}
      </div>
    </section>
  );
}
