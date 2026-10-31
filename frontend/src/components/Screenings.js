import { useEffect, useState } from 'react';
import { api, fetchBlobUrl } from '../api';

const VIEWS = ['CHEEK_LINING', 'TONGUE', 'PALATE', 'GUMS', 'FLOOR_OF_MOUTH', 'OTHER'];

function Thumb({ id }) {
  const [src, setSrc] = useState(null);
  useEffect(() => {
    let url, gone = false;
    fetchBlobUrl(`/photos/${id}/file`).then((u) => { url = u; gone ? URL.revokeObjectURL(u) : setSrc(u); }).catch(() => {});
    return () => { gone = true; if (url) URL.revokeObjectURL(url); };
  }, [id]);
  return src ? <img className="thumb" src={src} alt="oral" /> : <div className="thumb placeholder" />;
}

function Screening({ s, canUpload, reload, setError }) {
  const [photos, setPhotos] = useState([]);
  const [file, setFile] = useState(null);
  const [view, setView] = useState('CHEEK_LINING');
  const loadPhotos = () => api(`/screenings/${s.id}/photos`).then(setPhotos).catch(() => {});
  // eslint-disable-next-line react-hooks/exhaustive-deps
  useEffect(() => { loadPhotos(); }, [s.photo_count]);

  async function upload(e) {
    e.preventDefault();
    if (!file) return;
    const form = new FormData();
    form.append('image', file); form.append('view_type', view);
    try { await api(`/screenings/${s.id}/photos`, { method: 'POST', form }); setFile(null); e.target.reset(); reload(); }
    catch (err) { setError(err.message); }
  }

  return (
    <li>
      <div className="grow">
        <strong>{s.patient_name}</strong> <span className="tag">{s.patient_code}</span> <span className="tag">{s.case_state}</span>
        <div className="muted">{String(s.screening_date).slice(0, 10)} · {photos.length} photo(s)</div>
        <div className="actions">{photos.map((p) => <Thumb key={p.id} id={p.id} />)}</div>
        {canUpload && (
          <form className="row" onSubmit={upload}>
            <select value={view} onChange={(e) => setView(e.target.value)}>{VIEWS.map((v) => <option key={v}>{v}</option>)}</select>
            <input type="file" accept="image/jpeg,image/png,image/webp" onChange={(e) => setFile(e.target.files[0])} />
            <button>Upload photo</button>
          </form>
        )}
      </div>
    </li>
  );
}

export default function Screenings({ user }) {
  const [items, setItems] = useState([]);
  const [error, setError] = useState('');
  const load = () => api('/screenings').then(setItems).catch((e) => setError(e.message));
  // eslint-disable-next-line react-hooks/exhaustive-deps
  useEffect(() => { load(); }, []);
  return (
    <section>
      {error && <p className="error">{error}</p>}
      <div className="card">
        <h3>Screenings</h3>
        {items.length === 0 ? <p className="muted">No screenings yet. Grant consent and start one from Patients.</p> : (
          <ul className="list">
            {items.map((s) => <Screening key={s.id} s={s} canUpload={user.role === 'HEALTH_WORKER'} reload={load} setError={setError} />)}
          </ul>
        )}
      </div>
    </section>
  );
}
