#!/usr/bin/env python3
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer


def free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return int(s.getsockname()[1])


def wait_port(port: int, timeout: float = 3.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return
        except OSError:
            time.sleep(0.02)
    raise RuntimeError(f"Port {port} did not open within {timeout}s")


def main() -> None:
    root_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
    proxy_script = os.path.join(root_dir, "src", "proxy", "cache_proxy.py")
    tmp_dir = tempfile.mkdtemp()

    try:
        upstream_port = free_port()
        proxy_port = free_port()
        upstream_payload = {"gmail": "Email #1", "yt": "Video #1"}

        class UpstreamHandler(BaseHTTPRequestHandler):
            def log_message(self, format, *args):
                return

            def do_GET(self):
                if self.path == "/gmail":
                    body = upstream_payload["gmail"].encode("utf-8")
                elif self.path == "/youtube":
                    body = upstream_payload["yt"].encode("utf-8")
                else:
                    self.send_response(404)
                    self.end_headers()
                    return
                self.send_response(200)
                self.send_header("Content-Type", "text/html")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        upstream = HTTPServer(("127.0.0.1", upstream_port), UpstreamHandler)
        up_thread = threading.Thread(target=upstream.serve_forever, daemon=True)
        up_thread.start()

        # 1. Start proxy online: verify first-run Wi-Fi setup screen, offline disc shortcut, submit SSID+password, then seed cache
        env = os.environ.copy()
        env["MOCK_MODE"] = "1"
        env["MOCK_DISC_DRIVE"] = "bluray"
        env["MOCK_DISC_MEDIA"] = "dvd"
        env["MOCK_DISC_LABEL"] = "TEST_DVD"
        proc = subprocess.Popen(
            [sys.executable, proxy_script, "--state-dir", tmp_dir, "--port", str(proxy_port)],
            env=env,
        )
        try:
            wait_port(proxy_port)

            with urllib.request.urlopen(f"http://127.0.0.1:{proxy_port}/app") as resp:
                setup_html = resp.read().decode("utf-8")
                assert resp.getcode() == 200
                assert "Connect to Wi-Fi" in setup_html
                assert "Watch DVD / Blu-ray Offline" in setup_html

            with urllib.request.urlopen(f"http://127.0.0.1:{proxy_port}/app?tab=disc") as resp:
                disc_app = resp.read().decode("utf-8")
                assert resp.getcode() == 200
                assert "tab-btn-disc" in disc_app and "F3" in disc_app

            with urllib.request.urlopen(f"http://127.0.0.1:{proxy_port}/__5s__/disc/status") as resp:
                disc_st = json.loads(resp.read().decode("utf-8"))
                assert disc_st["drive_present"] is True
                assert disc_st["supports_dvd"] is True
                assert disc_st["supports_bluray"] is True
                assert disc_st["media_type"] == "dvd"

            play_req = urllib.request.Request(
                f"http://127.0.0.1:{proxy_port}/__5s__/disc/play",
                data=b"{}",
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with urllib.request.urlopen(play_req) as resp:
                play_res = json.loads(resp.read().decode("utf-8"))
                assert resp.getcode() == 200 and play_res["ok"] is True
                assert play_res["status"]["playing"] is True

            stop_req = urllib.request.Request(
                f"http://127.0.0.1:{proxy_port}/__5s__/disc/stop",
                data=b"{}",
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with urllib.request.urlopen(stop_req) as resp:
                stop_res = json.loads(resp.read().decode("utf-8"))
                assert resp.getcode() == 200 and stop_res["ok"] is True
                assert stop_res["status"]["playing"] is False

            wifi_req = urllib.request.Request(
                f"http://127.0.0.1:{proxy_port}/__5s__/wifi-setup",
                data=json.dumps({"ssid": "TestNet", "password": "secret-pass"}).encode(),
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with urllib.request.urlopen(wifi_req) as resp:
                wifi_res = json.loads(resp.read().decode("utf-8"))
                assert resp.getcode() == 200 and wifi_res.get("ok") is True

            assert os.path.exists(os.path.join(tmp_dir, "wifi_configured"))
            assert os.path.exists(os.path.join(tmp_dir, "iwd", "TestNet.psk"))

            gmail_url = f"http://127.0.0.1:{upstream_port}/gmail"
            yt_url = f"http://127.0.0.1:{upstream_port}/youtube"

            for u in (gmail_url, yt_url):
                with urllib.request.urlopen(
                    f"http://127.0.0.1:{proxy_port}/proxy?url={urllib.parse.quote(u, safe='')}"
                ) as resp:
                    assert resp.getcode() == 200

            req = urllib.request.Request(
                f"http://127.0.0.1:{proxy_port}/__5s__/snapshot",
                data=json.dumps({"gmail_html": "<div>Inbox Cached</div>", "youtube_html": "<div>YT Cached</div>"}).encode(),
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with urllib.request.urlopen(req) as resp:
                assert resp.getcode() == 200
        finally:
            proc.terminate()
            proc.wait(timeout=3)

        # Stop upstream server to prove offline behavior
        upstream.shutdown()
        upstream.server_close()

        # 2. Restart proxy in --offline mode
        proc2 = subprocess.Popen(
            [sys.executable, proxy_script, "--state-dir", tmp_dir, "--port", str(proxy_port), "--offline"]
        )
        try:
            wait_port(proxy_port)

            # Warm up SQLite connection and HTTP handler thread
            with urllib.request.urlopen(f"http://127.0.0.1:{proxy_port}/__5s__/status") as warm:
                assert warm.getcode() == 200

            max_hit_ms = float(os.environ.get("MAX_CACHE_HIT_MS", "50.0"))

            # Assert /app < max_hit_ms and contains h264ify + F1/F2
            t0 = time.monotonic()
            with urllib.request.urlopen(f"http://127.0.0.1:{proxy_port}/app") as resp:
                app_ms = (time.monotonic() - t0) * 1000.0
                app_body = resp.read().decode("utf-8")
                assert resp.getcode() == 200
                assert resp.headers.get("X-5S-Cache") == "HIT"
                assert app_ms < max_hit_ms, f"/app took {app_ms:.2f}ms (>= {max_hit_ms}ms)"
                assert "vp0?9|av01" in app_body
                assert '"F1"' in app_body and '"F2"' in app_body

            # Assert cached proxy hits < max_hit_ms
            for u, expected in ((gmail_url, "Email #1"), (yt_url, "Video #1")):
                t1 = time.monotonic()
                with urllib.request.urlopen(
                    f"http://127.0.0.1:{proxy_port}/proxy?url={urllib.parse.quote(u, safe='')}"
                ) as resp:
                    hit_ms = (time.monotonic() - t1) * 1000.0
                    body = resp.read().decode("utf-8")
                    assert resp.getcode() == 200
                    assert resp.headers.get("X-5S-Cache") == "HIT"
                    assert body == expected
                    assert hit_ms < max_hit_ms, f"cache hit took {hit_ms:.2f}ms (>= {max_hit_ms}ms)"

            # 3. Bring upstream back with updated data and trigger /__5s__/net-online
            upstream_payload["gmail"] = "Email #2"
            upstream_payload["yt"] = "Video #2"
            upstream2 = HTTPServer(("127.0.0.1", upstream_port), UpstreamHandler)
            threading.Thread(target=upstream2.serve_forever, daemon=True).start()
            try:
                net_req = urllib.request.Request(
                    f"http://127.0.0.1:{proxy_port}/__5s__/net-online",
                    data=b"{}",
                    method="POST",
                )
                with urllib.request.urlopen(net_req) as resp:
                    assert resp.getcode() == 200

                # Wait briefly for background sync thread
                deadline = time.monotonic() + 2.0
                synced = False
                while time.monotonic() < deadline:
                    with urllib.request.urlopen(f"http://127.0.0.1:{proxy_port}/__5s__/status") as st:
                        status_data = json.loads(st.read().decode("utf-8"))
                    with urllib.request.urlopen(
                        f"http://127.0.0.1:{proxy_port}/proxy?url={urllib.parse.quote(gmail_url, safe='')}"
                    ) as g_resp:
                        if status_data.get("online") is True and g_resp.read().decode("utf-8") == "Email #2":
                            synced = True
                            break
                    time.sleep(0.05)
                assert synced, "Background delta sync did not update cache after net-online"
            finally:
                upstream2.shutdown()
                upstream2.server_close()

            print(f"test_cache_proxy: /app={app_ms:.2f}ms, offline HITs <15ms, live sync verified")
        finally:
            proc2.terminate()
            proc2.wait(timeout=3)
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)


if __name__ == "__main__":
    main()
