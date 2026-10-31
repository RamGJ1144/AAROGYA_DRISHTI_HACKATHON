// Tiny fetch wrapper. All backend calls go through here (FastAPI on :8000).
export const API_URL = process.env.REACT_APP_API_URL || 'http://localhost:8000';
export const WS_URL = API_URL.replace(/^http/, 'ws') + '/ws';
const TOKEN_KEY = 'ad_token';

export const getToken = () => localStorage.getItem(TOKEN_KEY);
export const setToken = (t) => (t ? localStorage.setItem(TOKEN_KEY, t) : localStorage.removeItem(TOKEN_KEY));

export async function api(path, { method = 'GET', body, form } = {}) {
  const headers = {};
  const token = getToken();
  if (token) headers.Authorization = `Bearer ${token}`;
  let payload;
  if (form) {
    payload = form;
  } else if (body !== undefined) {
    headers['Content-Type'] = 'application/json';
    payload = JSON.stringify(body);
  }
  const res = await fetch(`${API_URL}/api${path}`, { method, headers, body: payload });
  if (res.status === 204) return null;
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    if (res.status === 401 && token) {
      setToken(null);
      window.dispatchEvent(new Event('ad-logout'));
    }
    throw new Error(data.error || `Request failed (${res.status})`);
  }
  return data;
}

// Fetch a protected file and return an object URL (for <img src>).
export async function fetchBlobUrl(path) {
  const res = await fetch(`${API_URL}/api${path}`, { headers: { Authorization: `Bearer ${getToken()}` } });
  if (!res.ok) throw new Error('Could not load file');
  return URL.createObjectURL(await res.blob());
}
