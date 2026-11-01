import { useEffect, useState } from 'react';
import { api } from '../api';

const TYPES = ['checkup', 'prescription', 'lab', 'vaccination', 'surgery', 'other'];
const today = () => new Date().toISOString().slice(0, 10);
const blank = () => ({ title: '', record_type: 'checkup', record_date: today(), notes: '' });

export default function Records() {
  const [items, setItems] = useState([]);
  const [form, setForm] = useState(blank());
  const [error, setError] = useState('');

  const load = () => api('/records').then(setItems).catch((e) => setError(e.message));
  // eslint-disable-next-line react-hooks/exhaustive-deps
  useEffect(() => { load(); }, []);

  const set = (k) => (e) => setForm({ ...form, [k]: e.target.value });

  async function add(e) {
    e.preventDefault();
    setError('');
    try {
      await api('/records', { method: 'POST', body: form });
      setForm(blank());
      load();
    } catch (err) { setError(err.message); }
  }

  async function remove(id) {
    if (!window.confirm('Delete this record?')) return;
    try { await api(`/records/${id}`, { method: 'DELETE' }); load(); } catch (err) { setError(err.message); }
  }

  return (
    <section>
      <div className="card">
        <h3>Add health record</h3>
        <form onSubmit={add}>
          <label>Title<input value={form.title} onChange={set('title')} required /></label>
          <div className="row">
            <label>Type
              <select value={form.record_type} onChange={set('record_type')}>
                {TYPES.map((t) => <option key={t}>{t}</option>)}
              </select>
            </label>
            <label>Date<input type="date" value={form.record_date} onChange={set('record_date')} required /></label>
          </div>
          <label>Notes<textarea rows={3} value={form.notes} onChange={set('notes')} /></label>
          <button>Add record</button>
        </form>
        {error && <p className="error">{error}</p>}
      </div>

      <div className="card">
        <h3>Your records</h3>
        {items.length === 0 ? <p className="muted">No records yet.</p> : (
          <ul className="list">
            {items.map((r) => (
              <li key={r.id}>
                <div>
                  <strong>{r.title}</strong> <span className="tag">{r.record_type}</span>
                  <div className="muted">{String(r.record_date).slice(0, 10)}</div>
                  {r.notes && <div>{r.notes}</div>}
                </div>
                <button className="danger" onClick={() => remove(r.id)}>Delete</button>
              </li>
            ))}
          </ul>
        )}
      </div>
    </section>
  );
}
