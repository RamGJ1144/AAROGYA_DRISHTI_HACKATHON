"""WebSocket connection manager: per-user live updates across tabs/devices."""
from collections import defaultdict
from fastapi import WebSocket


class ConnectionManager:
    def __init__(self):
        self.active: dict[str, set[WebSocket]] = defaultdict(set)

    async def connect(self, user_id, ws: WebSocket):
        await ws.accept()
        self.active[str(user_id)].add(ws)

    def disconnect(self, user_id, ws: WebSocket):
        k = str(user_id)
        self.active[k].discard(ws)
        if not self.active[k]:
            self.active.pop(k, None)

    async def notify(self, user_ids, resource: str, action: str, data: dict | None = None):
        if not isinstance(user_ids, (list, tuple, set)):
            user_ids = [user_ids]
        msg = {"type": "update", "resource": resource, "action": action, "data": data}
        for uid in user_ids:
            for ws in list(self.active.get(str(uid), ())):
                try:
                    await ws.send_json(msg)
                except Exception:
                    self.disconnect(uid, ws)


manager = ConnectionManager()
