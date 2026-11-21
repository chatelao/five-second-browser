#!/usr/bin/env python3
import argparse
import json
import os
import queue
import sqlite3
import subprocess
import threading
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DEFAULT_GMAIL_URL = "https://mail.google.com/mail/u/0/s/?v=or"
DEFAULT_YT_URL = "https://www.youtube.com/feed/subscriptions"

DEFAULT_GMAIL_HTML = """
<div class="mail-row"><b>Inbox (Cached)</b> — Ready for offline reading</div>
<div class="mail-row">Waiting for background sync...</div>
""".strip()

DEFAULT_YT_HTML = """
<div class="yt-card"><b>YouTube Feed (Cached)</b> — H.264 360p/480p30 ready</div>
<div class="yt-card">Waiting for background sync...</div>
""".strip()


class ProxyState:
    def __init__(self, state_dir: str, online: bool, ui_js: str, port: int = 8555):
        self.state_dir = state_dir
        os.makedirs(self.state_dir, exist_ok=True)
        self.db_path = os.path.join(self.state_dir, "http_cache.sqlite")
        self.online = online
        self.port = port
        self.last_sync = 0.0
        self.ui_js = ui_js
        self.lock = threading.Lock()
        self.sse_clients: list[queue.Queue] = []
        self.watch_urls: list[str] = []
        self._init_db()

    def is_wifi_configured(self) -> bool:
        if os.environ.get("SKIP_WIFI_SETUP") == "1":
            return True
        return os.path.exists(os.path.join(self.state_dir, "wifi_configured"))

    def configure_wifi(self, ssid: str, password: str) -> tuple[bool, str]:
        ssid = ssid.strip()
        if not ssid or "/" in ssid or "\n" in ssid or "\r" in ssid:
            return False, "Invalid Wi-Fi network name"
        if "\n" in password or "\r" in password:
            return False, "Invalid Wi-Fi password"

        mock_mode = os.environ.get("MOCK_MODE", "0") == "1"
        iwd_dir = os.environ.get("IWD_DIR") or (
            os.path.join(self.state_dir, "iwd") if mock_mode else "/var/lib/iwd"
        )
        os.makedirs(iwd_dir, exist_ok=True)
        psk_path = os.path.join(iwd_dir, f"{ssid}.psk")
        fd = os.open(psk_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            if password:
                f.write(f"[Security]\nPassphrase={password}\n")
            else:
                f.write("[Settings]\nAutoConnect=true\n")

        bin_dir = os.environ.get("BIN_DIR") or os.path.dirname(os.path.abspath(__file__))
        net_script = os.path.join(bin_dir, "5s-net-fast.sh")
        if not os.path.exists(net_script):
            net_script = os.path.abspath(
                os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "net", "5s-net-fast.sh")
            )
        if os.path.exists(net_script):
            env = os.environ.copy()
            env["PROXY_URL"] = f"http://127.0.0.1:{self.port}"
            subprocess.run(
                [net_script, "--connect", ssid, "--state-dir", self.state_dir],
                env=env,
                check=False,
                timeout=15,
            )

        with open(os.path.join(self.state_dir, "wifi_configured"), "w", encoding="utf-8") as f:
            f.write(f"{ssid}\n")
        return True, "Connected"

    def _connect(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self.db_path, timeout=5.0, check_same_thread=False)
        conn.execute("PRAGMA journal_mode=WAL;")
        conn.execute("PRAGMA synchronous=NORMAL;")
        return conn

    def _init_db(self) -> None:
        conn = self._connect()
        try:
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS cache (
                    url TEXT PRIMARY KEY,
                    status INTEGER NOT NULL,
                    content_type TEXT NOT NULL,
                    body BLOB NOT NULL,
                    updated_at REAL NOT NULL
                )
                """
            )
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS app_state (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                )
                """
            )
            conn.execute(
                "INSERT OR IGNORE INTO app_state (key, value) VALUES ('gmail_html', ?)",
                (DEFAULT_GMAIL_HTML,),
            )
            conn.execute(
                "INSERT OR IGNORE INTO app_state (key, value) VALUES ('youtube_html', ?)",
                (DEFAULT_YT_HTML,),
            )
            conn.commit()
        finally:
            conn.close()

    def get_cache(self, url: str):
        conn = self._connect()
        try:
            row = conn.execute(
                "SELECT status, content_type, body FROM cache WHERE url = ?",
                (url,),
            ).fetchone()
            return row
        finally:
            conn.close()

    def put_cache(self, url: str, status: int, content_type: str, body: bytes) -> None:
        conn = self._connect()
        try:
            conn.execute(
                """
                INSERT INTO cache (url, status, content_type, body, updated_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(url) DO UPDATE SET
                    status=excluded.status,
                    content_type=excluded.content_type,
                    body=excluded.body,
                    updated_at=excluded.updated_at
                """,
                (url, status, content_type, body, time.time()),
            )
            conn.commit()
        finally:
            conn.close()

    def cached_count(self) -> int:
        conn = self._connect()
        try:
            row = conn.execute("SELECT COUNT(*) FROM cache").fetchone()
            return int(row[0]) if row else 0
        finally:
            conn.close()

    def get_app_state(self) -> tuple[str, str]:
        conn = self._connect()
        try:
            rows = dict(conn.execute("SELECT key, value FROM app_state").fetchall())
            return (
                rows.get("gmail_html", DEFAULT_GMAIL_HTML),
                rows.get("youtube_html", DEFAULT_YT_HTML),
            )
        finally:
            conn.close()

    def save_snapshot(self, gmail_html: str | None = None, youtube_html: str | None = None) -> None:
        conn = self._connect()
        try:
            if gmail_html is not None:
                conn.execute(
                    "INSERT OR REPLACE INTO app_state (key, value) VALUES ('gmail_html', ?)",
                    (gmail_html,),
                )
            if youtube_html is not None:
                conn.execute(
                    "INSERT OR REPLACE INTO app_state (key, value) VALUES ('youtube_html', ?)",
                    (youtube_html,),
                )
            conn.commit()
            conn.execute("PRAGMA wal_checkpoint(TRUNCATE);")
        finally:
            conn.close()

    def broadcast_delta(self, payload: dict) -> None:
        msg = f"event: delta\ndata: {json.dumps(payload)}\n\n".encode("utf-8")
        with self.lock:
            for q in list(self.sse_clients):
                try:
                    q.put_nowait(msg)
                except queue.Full:
                    pass

    def fetch_and_cache(self, url: str) -> bool:
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "5s-browser/0.1"})
            with urllib.request.urlopen(req, timeout=3.0) as resp:
                status = resp.getcode()
                ctype = resp.headers.get("Content-Type", "text/html; charset=utf-8")
                body = resp.read()
                self.put_cache(url, status, ctype, body)
                return True
        except Exception:
            return False

    def trigger_online_sync(self) -> None:
        with self.lock:
            self.online = True
            urls = list(self.watch_urls)
        if not urls:
            conn = self._connect()
            try:
                urls = [r[0] for r in conn.execute("SELECT url FROM cache").fetchall()]
            finally:
                conn.close()

        def _worker():
            updated = False
            for u in urls:
                if self.fetch_and_cache(u):
                    updated = True
            with self.lock:
                self.last_sync = time.time()
            gmail_html, yt_html = self.get_app_state()
            self.broadcast_delta(
                {
                    "updated": updated,
                    "last_sync": self.last_sync,
                    "gmail_html": gmail_html,
                    "youtube_html": yt_html,
                }
            )

        threading.Thread(target=_worker, daemon=True).start()


def render_wifi_setup_html() -> bytes:
    html = """<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>5s-browser Wi-Fi Setup</title>
<style>
  html, body { margin: 0; padding: 0; width: 100vw; height: 100vh; overflow: hidden; font-family: sans-serif; background: #0f172a; color: #f8fafc; display: flex; align-items: center; justify-content: center; }
  .card { width: 420px; background: #1e293b; border-radius: 10px; padding: 28px; box-shadow: 0 10px 30px rgba(0,0,0,0.4); }
  h1 { margin: 0 0 8px 0; font-size: 20px; }
  p { margin: 0 0 20px 0; font-size: 13px; color: #94a3b8; }
  label { display: block; font-size: 13px; margin-bottom: 6px; color: #cbd5e1; }
  input { width: 100%; box-sizing: border-box; padding: 10px; margin-bottom: 14px; border: 1px solid #334155; border-radius: 6px; background: #0f172a; color: #fff; font-size: 14px; }
  button { width: 100%; padding: 11px; border: none; border-radius: 6px; background: #3b82f6; color: #fff; font-size: 15px; font-weight: bold; cursor: pointer; }
  #msg { margin-top: 12px; font-size: 13px; color: #fbbf24; min-height: 18px; }
</style>
</head>
<body>
  <div class="card">
    <h1>Connect to Wi-Fi</h1>
    <p>One-time setup for Gmail &amp; YouTube. Everything else is automatic.</p>
    <form id="wifi-form">
      <label for="ssid">Wi-Fi Name (SSID)</label>
      <input id="ssid" name="ssid" type="text" required autofocus placeholder="Your Wi-Fi network">
      <label for="password">Wi-Fi Password</label>
      <input id="password" name="password" type="password" placeholder="WPA2 passphrase">
      <button type="submit">Connect &amp; Start</button>
    </form>
    <div id="msg"></div>
  </div>
  <script>
    document.getElementById("wifi-form").addEventListener("submit", async function (e) {
      e.preventDefault();
      const msg = document.getElementById("msg");
      msg.textContent = "Connecting...";
      const ssid = document.getElementById("ssid").value;
      const password = document.getElementById("password").value;
      try {
        const res = await fetch("/__5s__/wifi-setup", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ ssid: ssid, password: password })
        });
        const data = await res.json();
        if (data.ok) {
          window.location.href = data.redirect || "/app";
        } else {
          msg.textContent = data.error || "Connection failed";
        }
      } catch (err) {
        msg.textContent = "Setup error: " + err;
      }
    });
  </script>
</body>
</html>
"""
    return html.encode("utf-8")


def render_app_html(state: ProxyState) -> bytes:
    if not state.is_wifi_configured():
        return render_wifi_setup_html()
    gmail_html, yt_html = state.get_app_state()
    pill_text = "● Live" if state.online else "● Cached (Connecting...)"
    pill_color = "#4ade80" if state.online else "#fbbf24"
    html = f"""<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>5s-browser</title>
<style>
  html, body {{ margin: 0; padding: 0; width: 100vw; height: 100vh; overflow: hidden; font-family: sans-serif; background: #111; color: #eee; }}
  #topbar {{ height: 24px; background: #1e293b; display: flex; align-items: center; justify-content: space-between; padding: 0 8px; font-size: 12px; }}
  .tabs {{ display: flex; gap: 6px; }}
  .tab-btn {{ background: #334155; color: #e2e8f0; border: none; height: 20px; padding: 0 10px; cursor: pointer; font-size: 12px; }}
  .tab-btn.active {{ background: #3b82f6; color: #fff; font-weight: bold; }}
  #viewport {{ position: relative; width: 100%; height: calc(100vh - 24px); }}
  .pane {{ position: absolute; inset: 0; overflow-y: auto; padding: 12px; background: #fff; color: #111; }}
  #pane-youtube {{ visibility: hidden; pointer-events: none; background: #0f0f0f; color: #f1f1f1; }}
</style>
</head>
<body>
  <div id="topbar">
    <div class="tabs">
      <button id="tab-btn-gmail" class="tab-btn active">&#9993; Gmail (F1)</button>
      <button id="tab-btn-youtube" class="tab-btn">&#9654; YouTube (F2)</button>
    </div>
    <div id="status-pill" style="color: {pill_color};">{pill_text}</div>
  </div>
  <div id="viewport">
    <div id="pane-gmail" class="pane">
      <div id="gmail-feed">{gmail_html}</div>
    </div>
    <div id="pane-youtube" class="pane">
      <div id="youtube-feed">{yt_html}</div>
    </div>
  </div>
  <script>{state.ui_js}</script>
</body>
</html>
"""
    return html.encode("utf-8")


def make_handler(state: ProxyState):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, format, *args):
            return

        def _send(self, code: int, ctype: str, body: bytes, cache_hdr: str | None = None):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            if cache_hdr:
                self.send_header("X-5S-Cache", cache_hdr)
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            parsed = urllib.parse.urlparse(self.path)
            if parsed.path == "/app":
                self._send(200, "text/html; charset=utf-8", render_app_html(state), "HIT")
                return

            if parsed.path == "/__5s__/status":
                payload = json.dumps(
                    {
                        "online": state.online,
                        "cached_items": state.cached_count(),
                        "last_sync": state.last_sync,
                    }
                ).encode("utf-8")
                self._send(200, "application/json", payload)
                return

            if parsed.path == "/__5s__/events":
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Cache-Control", "no-cache")
                self.send_header("Connection", "keep-alive")
                self.end_headers()
                q: queue.Queue = queue.Queue(maxsize=32)
                with state.lock:
                    state.sse_clients.append(q)
                try:
                    self.wfile.write(b": connected\n\n")
                    self.wfile.flush()
                    while True:
                        try:
                            msg = q.get(timeout=1.0)
                            self.wfile.write(msg)
                            self.wfile.flush()
                        except queue.Empty:
                            break
                except Exception:
                    pass
                finally:
                    with state.lock:
                        if q in state.sse_clients:
                            state.sse_clients.remove(q)
                return

            if parsed.path == "/proxy":
                qs = urllib.parse.parse_qs(parsed.query)
                target = qs.get("url", [""])[0]
                if not target:
                    self._send(400, "text/plain", b"missing url")
                    return
                cached = state.get_cache(target)
                if cached is not None:
                    status, ctype, body = cached
                    self._send(status, ctype, body, "HIT")
                    if state.online:
                        threading.Thread(
                            target=state.fetch_and_cache, args=(target,), daemon=True
                        ).start()
                    return
                if state.online and state.fetch_and_cache(target):
                    row = state.get_cache(target)
                    if row is not None:
                        self._send(row[0], row[1], row[2], "MISS")
                        return
                self._send(503, "text/plain", b"offline cache miss", "MISS")
                return

            self._send(404, "text/plain", b"not found")

        def do_POST(self):
            length = int(self.headers.get("Content-Length", "0") or "0")
            raw = self.rfile.read(length) if length > 0 else b"{}"
            if self.path == "/__5s__/net-online":
                state.trigger_online_sync()
                self._send(200, "application/json", b'{"ok":true}')
                return
            if self.path == "/__5s__/wifi-setup":
                try:
                    data = json.loads(raw.decode("utf-8") or "{}")
                except Exception:
                    data = {}
                ok, msg = state.configure_wifi(
                    str(data.get("ssid", "")), str(data.get("password", ""))
                )
                code = 200 if ok else 400
                self._send(
                    code,
                    "application/json",
                    json.dumps({"ok": ok, "error": None if ok else msg, "redirect": "/app"}).encode("utf-8"),
                )
                return
            if self.path == "/__5s__/snapshot":
                try:
                    data = json.loads(raw.decode("utf-8") or "{}")
                except Exception:
                    data = {}
                state.save_snapshot(data.get("gmail_html"), data.get("youtube_html"))
                self._send(200, "application/json", b'{"saved":true}')
                return
            self._send(404, "text/plain", b"not found")

    return Handler


def main():
    parser = argparse.ArgumentParser(description="5s-browser SQLite WAL cache proxy")
    parser.add_argument("--state-dir", default="/var/cache/5s")
    parser.add_argument("--port", type=int, default=8555)
    parser.add_argument("--offline", action="store_true")
    args = parser.parse_args()

    ui_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "injected_ui.js")
    with open(ui_path, "r", encoding="utf-8") as f:
        ui_js = f.read()

    state = ProxyState(args.state_dir, online=not args.offline, ui_js=ui_js, port=args.port)
    server = ThreadingHTTPServer(("127.0.0.1", args.port), make_handler(state))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
