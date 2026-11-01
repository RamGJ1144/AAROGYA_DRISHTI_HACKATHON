import { useEffect, useState } from 'react';
import { api, fetchBlobUrl } from '../api';

function Thumb({ id, alt }) {
  const [src, setSrc] = useState(null);
  useEffect(() => {
    let url;
    let cancelled = false;
    fetchBlobUrl(`/images/${id}/file`)
      .then((u) => { url = u; if (!cancelled) setSrc(u); else URL.revokeObjectURL(u); })
      .catch(() => {});
    return () => { cancelled = true; if (url) URL.revokeObjectURL(url); };
  }, [id]);
  return src ? <img className="thumb" src={src} alt={alt} /> : <div className="thumb placeholder" />;
}

export default function Images() {
  const [items, setItems] = useState([]);
  const [file, setFile] = useState(null);
  const [description, setDescription] = useState('');
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');
  const [inputKey, setInputKey] = useState(0);

  const load = () => api('/images').then(setItems).catch((e) => setError(e.message));
  // eslint-disable-next-line react-hooks/exhaustive-deps
  useEffect(() => { load(); }, []);

  async function upload(e) {
    e.preventDefault();
    setError('');
    if (!file) return setError('Choose an image first');
    const form = new FormData();
    form.append('image', file);
    form.append('description', description);
    try {
      await api('/images', { method: 'POST', form });
      setFile(null); setDescription(''); setInputKey((k) => k + 1);
      load();
    } catch (err) { setError(err.message); }
  }

  async function analyze(id) {
    setError(''); setNotice('');
    try { await api(`/images/${id}/analyze`, { method: 'POST' }); load(); }
    catch (err) { setNotice(err.message); }
  }

  async function remove(id) {
    if (!window.confirm('Delete this image?')) return;
    try { await api(`/images/${id}`, { method: 'DELETE' }); load(); } catch (err) { setError(err.message); }
  }

  return (
    <section>
      <div className="card">
        <h3>Upload medical image</h3>
        <form onSubmit={upload}>
          <label>Image (JPEG, PNG, WebP, max 10 MB)
            <input key={inputKey} type="file" accept="image/jpeg,image/png,image/webp" onChange={(e) => setFile(e.target.files[0] || null)} />
          </label>
          <label>Description<input value={description} onChange={(e) => setDescription(e.target.value)} /></label>
          <button>Upload</button>
        </form>
        {error && <p className="error">{error}</p>}
      </div>

      <div className="card">
        <h3>Your images</h3>
        {notice && <p className="muted">{notice}</p>}
        {items.length === 0 ? <p className="muted">No images yet.</p> : (
          <ul className="list">
            {items.map((img) => (
              <li key={img.id}>
                <Thumb id={img.id} alt={img.original_name} />
                <div className="grow">
                  <strong>{img.original_name}</strong>
                  <div className="muted">{new Date(img.created_at).toLocaleDateString()} - {(img.size_bytes / 1024).toFixed(0)} KB</div>
                  {img.description && <div>{img.description}</div>}
                  <div className="muted">Analysis: {img.analysis_status.replace('_', ' ')}</div>
                  {img.analysis_result && <pre>{JSON.stringify(img.analysis_result, null, 2)}</pre>}
                </div>
                <div className="actions">
                  <button onClick={() => analyze(img.id)}>Analyze</button>
                  <button className="danger" onClick={() => remove(img.id)}>Delete</button>
                </div>
              </li>
            ))}
          </ul>
        )}
      </div>
    </section>
  );
}
