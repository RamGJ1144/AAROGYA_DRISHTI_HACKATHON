import { useState } from 'react';
import { api, setToken } from '../api';

export default function Auth({ onLogin }) {
  const [mode, setMode] = useState('login');
  const [form, setForm] = useState({ name: '', email: '', password: '' });
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);

  const set = (k) => (e) => setForm({ ...form, [k]: e.target.value });

  async function submit(e) {
    e.preventDefault();
    setError('');
    setBusy(true);
    try {
      const data = await api(`/auth/${mode}`, { method: 'POST', body: form });
      setToken(data.token);
      onLogin(data.user);
    } catch (err) {
      setError(err.message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="card auth">
      <h2>{mode === 'login' ? 'Log in' : 'Create account'}</h2>
      <form onSubmit={submit}>
        {mode === 'register' && (
          <label>Name<input value={form.name} onChange={set('name')} required /></label>
        )}
        <label>Email<input type="email" value={form.email} onChange={set('email')} required /></label>
        <label>Password<input type="password" minLength={8} value={form.password} onChange={set('password')} required /></label>
        {error && <p className="error">{error}</p>}
        <button disabled={busy}>{mode === 'login' ? 'Log in' : 'Sign up'}</button>
      </form>
      <p className="muted">
        {mode === 'login' ? 'New here? ' : 'Already registered? '}
        <button className="link" type="button" onClick={() => { setMode(mode === 'login' ? 'register' : 'login'); setError(''); }}>
          {mode === 'login' ? 'Create an account' : 'Log in'}
        </button>
      </p>
    </div>
  );
}
