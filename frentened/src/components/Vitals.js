import { useEffect, useState } from 'react';
import { api } from '../api';

const blank = { systolic: '', diastolic: '', heart_rate: '', blood_sugar: '', weight_kg: '', notes: '' };

export default function Vitals() {
  const [items, setItems] = useState([]);
  const [form, setForm] = useState(blank);
  const [error, setError] = useState('');

  const load = () => api('/vitals').then(setItems).catch((e) => setError(e.message));
  // eslint-disable-next-line react-hooks/exhaustive-deps
  useEffect(() => { load(); }, []);

  const set = (k) => (e) => setForm({ ...form, [k]: e.target.value });

  async function add(e) {
    e.preventDefault();
    setError('');
    try {
      await api('/vitals', { method: 'POST', body: form });
      setForm(blank);
      load();
    } catch (err) { setError(err.message); }
  }

  async function remove(id) {
    try { await api(`/vitals/${id}`, { method: 'DELETE' }); load(); } catch (err) { setError(err.message); }
  }

  return (
    <section>
      <div className="card">
        <h3>Log vitals</h3>
        <form onSubmit={add}>
          <div className="row">
            <label>BP systolic<input type="number" value={form.systolic} onChange={set('systolic')} /></label>
            <label>BP diastolic<input type="number" value={form.diastolic} onChange={set('diastolic')} /></label>
            <label>Heart rate (bpm)<input type="number" value={form.heart_rate} onChange={set('heart_rate')} /></label>
          </div>
          <div className="row">
            <label>Blood sugar (mg/dL)<input type="number" step="0.1" value={form.blood_sugar} onChange={set('blood_sugar')} /></label>
            <label>Weight (kg)<input type="number" step="0.1" value={form.weight_kg} onChange={set('weight_kg')} /></label>
          </div>
          <label>Notes<input value={form.notes} onChange={set('notes')} /></label>
          <button>Save entry</button>
        </form>
        {error && <p className="error">{error}</p>}
      </div>

      <div className="card">
        <h3>History</h3>
        {items.length === 0 ? <p className="muted">No entries yet.</p> : (
          <div className="table-wrap">
            <table>
              <thead>
                <tr><th>When</th><th>BP</th><th>HR</th><th>Sugar</th><th>Weight</th><th>Notes</th><th /></tr>
              </thead>
              <tbody>
                {items.map((v) => (
                  <tr key={v.id}>
                    <td>{new Date(v.measured_at).toLocaleString()}</td>
                    <td>{v.systolic ? `${v.systolic}/${v.diastolic}` : '-'}</td>
                    <td>{v.heart_rate ?? '-'}</td>
                    <td>{v.blood_sugar ?? '-'}</td>
                    <td>{v.weight_kg ?? '-'}</td>
                    <td>{v.notes || ''}</td>
                    <td><button className="danger" onClick={() => remove(v.id)}>Delete</button></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </section>
  );
}
