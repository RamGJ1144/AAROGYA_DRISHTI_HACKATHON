import { useEffect, useState } from 'react';
import { api } from '../api';

export default function Approvals() {
  const [items, setItems] = useState([]);
  const [error, setError] = useState('');
  const load = () => api('/auth/registrations?status=PENDING').then(setItems).catch((e) => setError(e.message));
  // eslint-disable-next-line react-hooks/exhaustive-deps
  useEffect(() => { load(); }, []);

  async function act(id, kind) {
    setError('');
    let body;
    if (kind === 'reject') {
      const reason = window.prompt('Reason for rejection?');
      if (!reason) return;
      body = { reason };
    }
    try { await api(`/auth/registrations/${id}/${kind}`, { method: 'POST', body: body || {} }); load(); }
    catch (err) { setError(err.message); }
  }

  return (
    <section className="card">
      <h3>Pending health-worker requests</h3>
      {error && <p className="error">{error}</p>}
      {items.length === 0 ? <p className="muted">Nothing pending.</p> : (
        <ul className="list">
          {items.map((r) => (
            <li key={r.id}>
              <div className="grow">
                <strong>{r.full_name}</strong> <span className="tag">{r.designation}</span>
                <div className="muted">@{r.username} · {r.phone} · {r.facility}</div>
              </div>
              <div className="actions">
                <button onClick={() => act(r.id, 'approve')}>Approve</button>
                <button className="danger" onClick={() => act(r.id, 'reject')}>Reject</button>
              </div>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}
