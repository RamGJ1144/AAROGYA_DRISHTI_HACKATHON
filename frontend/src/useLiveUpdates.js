import { useEffect, useRef } from 'react';
import { WS_URL, getToken } from './api';

// Opens a WebSocket to the FastAPI backend and calls onUpdate({resource, action}) on every push.
export default function useLiveUpdates(enabled, onUpdate) {
  const cb = useRef(onUpdate);
  cb.current = onUpdate;

  useEffect(() => {
    if (!enabled) return undefined;
    let ws, timer, closed = false;
    const connect = () => {
      ws = new WebSocket(`${WS_URL}?token=${encodeURIComponent(getToken() || '')}`);
      ws.onmessage = (e) => {
        try { const m = JSON.parse(e.data); if (m.type === 'update') cb.current(m); } catch { /* ignore */ }
      };
      ws.onclose = (e) => { if (!closed && e.code !== 4401) timer = setTimeout(connect, 2000); };
    };
    connect();
    const ping = setInterval(() => ws && ws.readyState === 1 && ws.send('ping'), 25000);
    return () => { closed = true; clearTimeout(timer); clearInterval(ping); ws && ws.close(); };
  }, [enabled]);
}
