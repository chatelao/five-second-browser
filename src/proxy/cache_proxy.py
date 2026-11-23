#!/usr/bin/env python3
import argparse
import hashlib
import html as html_lib
import json
import os
import queue
import re
import shutil
import sqlite3
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

_HERE = os.path.dirname(os.path.abspath(__file__))
for _cand in (_HERE, os.path.abspath(os.path.join(_HERE, "..", "disc"))):
    if os.path.isfile(os.path.join(_cand, "disc_manager.py")) and _cand not in sys.path:
        sys.path.insert(0, _cand)
        break

from disc_manager import DiscManager  # noqa: E402

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


def _parse_bool(val: str) -> bool | None:
    v = val.strip().strip('"').strip("'").lower()
    if v in ("1", "true", "yes", "on", "enable", "enabled"):
        return True
    if v in ("0", "false", "no", "off", "disable", "disabled"):
        return False
    return None


class ProxyState:
    def __init__(self, state_dir: str, online: bool, ui_js: str, port: int = 8555):
        self.state_dir = state_dir
        os.makedirs(self.state_dir, exist_ok=True)
        self.logs_dir = os.path.join(self.state_dir, "logs")
        os.makedirs(self.logs_dir, exist_ok=True)
        self.db_path = os.path.join(self.state_dir, "http_cache.sqlite")
        self.online = online
        self.port = port
        self.last_sync = 0.0
        self.ssid = ""
        self.ip = ""
        self.gw = ""
        self.signal_percent: int | None = None
        self.signal_dbm: int | None = None
        self._last_wifi_probe = 0.0
        self.internet_ok = online
        self.net_error = ""
        self.ui_js = ui_js
        self.lock = threading.Lock()
        self.sse_clients: list[queue.Queue] = []
        self.watch_urls: list[str] = []
        self._init_db()
        self._init_profiles()
        self.disc_manager = DiscManager(state_dir=self.state_dir)
        if self.get_features()["disc"]:
            self.disc_manager.start_monitor(self.broadcast_disc)
        self.log_proxy("info", f"cache_proxy started (port={port}, online={online}, state_dir={state_dir})")

    def _write_log(self, filename: str, level: str, msg: str) -> None:
        ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        line = f"[{ts}] [{level.upper()}] {msg}\n"
        path = os.path.join(self.logs_dir, filename)
        try:
            with self.lock:
                with open(path, "a", encoding="utf-8") as f:
                    f.write(line)
        except OSError:
            pass

    def log_proxy(self, level: str, msg: str) -> None:
        self._write_log("proxy.log", level, msg)

    def log_app(self, level: str, source: str, msg: str, extra: dict | None = None) -> None:
        detail = f"[{source}] {msg}"
        if extra:
            detail += f" {json.dumps(extra)}"
        self._write_log("apps.log", level, detail)

    def get_features(self) -> dict[str, bool]:
        features = {"gmail": True, "youtube": True, "disc": True}
        feat_path = os.path.join(self.state_dir, "features.json")
        if os.path.isfile(feat_path):
            try:
                with open(feat_path, "r", encoding="utf-8") as f:
                    data = json.load(f)
                for key in ("gmail", "youtube", "disc"):
                    if isinstance(data.get(key), bool):
                        features[key] = data[key]
            except Exception:
                pass

        for cand in (
            os.path.join(self.state_dir, "wifi.txt"),
            "/boot/efi/wifi.txt",
            "/boot/efi/WIFI.TXT",
        ):
            if os.path.isfile(cand):
                try:
                    with open(cand, "r", encoding="utf-8", errors="replace") as f:
                        for raw_line in f:
                            line = raw_line.strip()
                            if not line or line.startswith("#") or "=" not in line:
                                continue
                            k, v = line.split("=", 1)
                            k = k.strip().upper()
                            parsed = _parse_bool(v)
                            if parsed is None:
                                continue
                            if k == "ENABLE_GMAIL":
                                features["gmail"] = parsed
                            elif k == "ENABLE_YOUTUBE":
                                features["youtube"] = parsed
                            elif k == "ENABLE_DISC":
                                features["disc"] = parsed
                except Exception:
                    pass
                break
        return features

    # --- Family Profiles (up to 5 members) ---
    MAX_PROFILES = 5
    PROFILE_COLORS = ["#3b82f6", "#10b981", "#f59e0b", "#ec4899", "#8b5cf6"]

    @staticmethod
    def _hash_pin(pin: str) -> str:
        clean = pin.strip()
        if not clean:
            return ""
        return hashlib.sha256(f"5s-pin:{clean}".encode("utf-8")).hexdigest()

    def _profiles_path(self) -> str:
        return os.path.join(self.state_dir, "profiles.json")

    def _active_profile_path(self) -> str:
        return os.path.join(self.state_dir, "active_profile")

    def _init_profiles(self) -> None:
        pfile = self._profiles_path()
        if not os.path.isfile(pfile):
            names: list[str] = []
            for cand in (
                os.path.join(self.state_dir, "wifi.txt"),
                "/boot/efi/wifi.txt",
                "/boot/efi/WIFI.TXT",
            ):
                if os.path.isfile(cand):
                    try:
                        with open(cand, "r", encoding="utf-8", errors="replace") as f:
                            for raw_line in f:
                                line = raw_line.strip()
                                if not line or line.startswith("#") or "=" not in line:
                                    continue
                                k, v = line.split("=", 1)
                                if k.strip().upper() == "PROFILES":
                                    names = [x.strip() for x in v.split(",") if x.strip()][: self.MAX_PROFILES]
                                    break
                    except Exception:
                        pass
                    if names:
                        break
            if not names:
                names = ["Standard"]
            profiles = []
            for idx, nm in enumerate(names):
                profiles.append(
                    {
                        "id": f"p{idx + 1}",
                        "name": nm[:24],
                        "color": self.PROFILE_COLORS[idx % len(self.PROFILE_COLORS)],
                        "pin_hash": "",
                        "features": None,
                    }
                )
            self._save_profiles_raw(profiles)
        if not os.path.isfile(self._active_profile_path()):
            profiles = self._load_profiles_raw()
            first_id = profiles[0]["id"] if profiles else "p1"
            self._write_active_profile_id(first_id)

    def _load_profiles_raw(self) -> list[dict]:
        pfile = self._profiles_path()
        try:
            with open(pfile, "r", encoding="utf-8") as f:
                data = json.load(f)
            if isinstance(data, list) and data:
                return data[: self.MAX_PROFILES]
        except Exception:
            pass
        return [{"id": "p1", "name": "Standard", "color": "#3b82f6", "pin_hash": "", "features": None}]

    def _save_profiles_raw(self, profiles: list[dict]) -> None:
        pfile = self._profiles_path()
        tmp = pfile + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(profiles[: self.MAX_PROFILES], f, indent=2)
        os.replace(tmp, pfile)

    def _write_active_profile_id(self, profile_id: str) -> None:
        ap = self._active_profile_path()
        tmp = ap + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(profile_id.strip() + "\n")
        os.replace(tmp, ap)

    def get_active_profile_id(self) -> str:
        try:
            with open(self._active_profile_path(), "r", encoding="utf-8") as f:
                val = f.read().strip()
                if val:
                    return val
        except Exception:
            pass
        return "p1"

    def get_profiles_public(self) -> dict:
        with self.lock:
            raw = self._load_profiles_raw()
            active_id = self.get_active_profile_id()
        pub = []
        active_obj = None
        for p in raw:
            item = {
                "id": p.get("id", "p1"),
                "name": p.get("name", "Standard"),
                "color": p.get("color", "#3b82f6"),
                "has_pin": bool(p.get("pin_hash")),
                "features": p.get("features"),
            }
            if item["id"] == active_id:
                active_obj = item
            pub.append(item)
        if active_obj is None and pub:
            active_obj = pub[0]
            active_id = pub[0]["id"]
        return {
            "active_id": active_id,
            "active_profile": active_obj,
            "profiles": pub,
            "max_profiles": self.MAX_PROFILES,
        }

    def save_profile(
        self,
        profile_id: str | None,
        name: str,
        color: str | None = None,
        pin: str | None = None,
        clear_pin: bool = False,
        features: dict | None = None,
    ) -> tuple[bool, str, dict | None]:
        clean_name = name.strip()[:24]
        if not clean_name:
            return False, "Profile name required", None
        with self.lock:
            profiles = self._load_profiles_raw()
            target = None
            if profile_id:
                for p in profiles:
                    if p.get("id") == profile_id:
                        target = p
                        break
            if target is not None:
                target["name"] = clean_name
                if color and re.match(r"^#[0-9a-fA-F]{6}$", color.strip()):
                    target["color"] = color.strip()
                if clear_pin:
                    target["pin_hash"] = ""
                elif pin is not None and pin.strip():
                    if not re.match(r"^\d{4}$", pin.strip()):
                        return False, "PIN must be 4 digits", None
                    target["pin_hash"] = self._hash_pin(pin)
                if isinstance(features, dict):
                    target["features"] = {
                        "gmail": features.get("gmail", True) is not False,
                        "youtube": features.get("youtube", True) is not False,
                        "disc": features.get("disc", True) is not False,
                    }
            else:
                if len(profiles) >= self.MAX_PROFILES:
                    return False, f"Maximum of {self.MAX_PROFILES} family profiles reached", None
                existing_ids = {p.get("id") for p in profiles}
                new_id = None
                for i in range(1, self.MAX_PROFILES + 1):
                    cand = f"p{i}"
                    if cand not in existing_ids:
                        new_id = cand
                        break
                if not new_id:
                    return False, "No profile slot available", None
                pin_hash = ""
                if pin is not None and pin.strip():
                    if not re.match(r"^\d{4}$", pin.strip()):
                        return False, "PIN must be 4 digits", None
                    pin_hash = self._hash_pin(pin)
                idx = len(profiles)
                target = {
                    "id": new_id,
                    "name": clean_name,
                    "color": (color.strip() if color and re.match(r"^#[0-9a-fA-F]{6}$", color.strip()) else self.PROFILE_COLORS[idx % len(self.PROFILE_COLORS)]),
                    "pin_hash": pin_hash,
                    "features": (
                        {
                            "gmail": features.get("gmail", True) is not False,
                            "youtube": features.get("youtube", True) is not False,
                            "disc": features.get("disc", True) is not False,
                        }
                        if isinstance(features, dict)
                        else None
                    ),
                }
                profiles.append(target)
            self._save_profiles_raw(profiles)
        return True, "ok", {"id": target["id"], "name": target["name"], "color": target["color"], "has_pin": bool(target.get("pin_hash"))}

    def delete_profile(self, profile_id: str) -> tuple[bool, str]:
        with self.lock:
            profiles = self._load_profiles_raw()
            if len(profiles) <= 1:
                return False, "Cannot delete the last profile"
            new_profiles = [p for p in profiles if p.get("id") != profile_id]
            if len(new_profiles) == len(profiles):
                return False, "Profile not found"
            self._save_profiles_raw(new_profiles)
            if self.get_active_profile_id() == profile_id:
                self._write_active_profile_id(new_profiles[0]["id"])
        prof_dir = os.path.join(self.state_dir, "profiles", profile_id)
        if os.path.isdir(prof_dir):
            shutil.rmtree(prof_dir, ignore_errors=True)
        return True, "ok"

    def switch_profile(self, profile_id: str, pin: str = "") -> tuple[bool, str]:
        with self.lock:
            profiles = self._load_profiles_raw()
            target = None
            for p in profiles:
                if p.get("id") == profile_id:
                    target = p
                    break
            if target is None:
                return False, "Profile not found"
            expected_hash = target.get("pin_hash", "")
            if expected_hash and self._hash_pin(pin) != expected_hash:
                return False, "Invalid PIN"
            self._write_active_profile_id(profile_id)
        req_file = os.path.join(self.state_dir, "profile_switch_requested")
        with open(req_file, "w", encoding="utf-8") as f:
            f.write(profile_id + "\n")
        self.log_proxy("info", f"profile switch requested -> {profile_id} ({target.get('name')})")
        if os.environ.get("MOCK_MODE", "0") != "1":
            pid_file = os.path.join(self.state_dir, "chromium_pid")
            if os.path.isfile(pid_file):
                try:
                    with open(pid_file, "r", encoding="utf-8") as pf:
                        cpid = int(pf.read().strip())
                    os.kill(cpid, 15)
                except Exception:
                    pass
        return True, "switching"

    def reset_profile(self, profile_id: str) -> tuple[bool, str]:
        if not re.match(r"^p[1-5]$", profile_id):
            return False, "Invalid profile id"
        if profile_id == "p1":
            pdir = os.path.join(self.state_dir, "chromium_profile")
        else:
            pdir = os.path.join(self.state_dir, "profiles", profile_id, "chromium_profile")
        if os.path.isdir(pdir):
            shutil.rmtree(pdir, ignore_errors=True)
            os.makedirs(pdir, exist_ok=True)
        fb = os.path.join(self.state_dir, f"last_frame_{profile_id}.fb")
        if os.path.isfile(fb):
            try:
                os.remove(fb)
            except OSError:
                pass
        return True, "reset"

    # --- Laptop Hardware & Overlay Controls ---
    def get_battery_info(self) -> dict | None:
        if os.environ.get("MOCK_MODE", "0") == "1":
            return {"present": True, "percent": 85, "status": "Discharging"}
        ps_dir = "/sys/class/power_supply"
        if not os.path.isdir(ps_dir):
            return None
        try:
            for name in sorted(os.listdir(ps_dir)):
                if not name.startswith("BAT"):
                    continue
                cap_path = os.path.join(ps_dir, name, "capacity")
                st_path = os.path.join(ps_dir, name, "status")
                if os.path.isfile(cap_path):
                    with open(cap_path, "r", encoding="utf-8") as f:
                        pct = int(f.read().strip())
                    st = "Unknown"
                    if os.path.isfile(st_path):
                        with open(st_path, "r", encoding="utf-8") as f:
                            st = f.read().strip()
                    return {"present": True, "percent": max(0, min(100, pct)), "status": st}
        except Exception:
            pass
        return None

    def get_overlay_usage_pct(self) -> int | None:
        target = "/mnt/5s-backing" if os.path.ismount("/mnt/5s-backing") else self.state_dir
        try:
            st = os.statvfs(target)
            if st.f_blocks > 0:
                used = st.f_blocks - st.f_bfree
                return int(round((used / st.f_blocks) * 100))
        except Exception:
            pass
        return None

    def get_hw_status(self) -> dict:
        vol = 80
        bri = 80
        if os.environ.get("MOCK_MODE", "0") != "1":
            try:
                res = subprocess.run(["amixer", "get", "Master"], capture_output=True, text=True, timeout=1.5, check=False)
                m = re.search(r"\[(\d{1,3})%\]", res.stdout or "")
                if m:
                    vol = max(0, min(100, int(m.group(1))))
            except Exception:
                pass
            bl_dir = "/sys/class/backlight"
            if os.path.isdir(bl_dir):
                try:
                    for name in sorted(os.listdir(bl_dir)):
                        cur_p = os.path.join(bl_dir, name, "brightness")
                        max_p = os.path.join(bl_dir, name, "max_brightness")
                        if os.path.isfile(cur_p) and os.path.isfile(max_p):
                            cur_v = int(open(cur_p, "r").read().strip())
                            max_v = max(1, int(open(max_p, "r").read().strip()))
                            bri = max(1, min(100, int(round((cur_v / max_v) * 100))))
                            break
                except Exception:
                    pass
        return {
            "battery": self.get_battery_info(),
            "volume": vol,
            "brightness": bri,
            "overlay_usage_pct": self.get_overlay_usage_pct(),
        }

    def set_volume(self, pct: int) -> tuple[bool, int]:
        pct = max(0, min(100, int(pct)))
        if os.environ.get("MOCK_MODE", "0") != "1" and shutil.which("amixer"):
            try:
                subprocess.run(["amixer", "-q", "sset", "Master", f"{pct}%", "unmute"], timeout=1.5, check=False)
            except Exception:
                return False, pct
        return True, pct

    def set_brightness(self, pct: int) -> tuple[bool, int]:
        pct = max(5, min(100, int(pct)))
        if os.environ.get("MOCK_MODE", "0") != "1":
            bl_dir = "/sys/class/backlight"
            if os.path.isdir(bl_dir):
                try:
                    for name in sorted(os.listdir(bl_dir)):
                        cur_p = os.path.join(bl_dir, name, "brightness")
                        max_p = os.path.join(bl_dir, name, "max_brightness")
                        if os.path.isfile(cur_p) and os.path.isfile(max_p):
                            max_v = max(1, int(open(max_p, "r").read().strip()))
                            val = max(1, int(round((pct / 100.0) * max_v)))
                            with open(cur_p, "w", encoding="utf-8") as f:
                                f.write(str(val))
                            return True, pct
                except Exception:
                    return False, pct
        return True, pct

    def trigger_power(self, action: str) -> tuple[bool, str]:
        if action not in ("poweroff", "reboot"):
            return False, "Invalid action"
        self.log_proxy("info", f"power action requested: {action}")
        if os.environ.get("MOCK_MODE", "0") == "1" or not os.path.exists("/run/5s-boot-marks"):
            return True, action
        if action == "reboot":
            with open(os.path.join(self.state_dir, "reboot_requested"), "w", encoding="utf-8") as f:
                f.write("1\n")
        try:
            os.kill(1, 15)
        except Exception as exc:
            return False, str(exc)
        return True, action

    def scan_wifi(self) -> list[dict]:
        if os.environ.get("MOCK_MODE", "0") == "1":
            return [
                {"ssid": "HomeWiFi-5G", "security": "psk", "signal": "****"},
                {"ssid": "GuestWiFi", "security": "open", "signal": "**"},
            ]
        iface = "wlan0"
        try:
            for name in sorted(os.listdir("/sys/class/net")):
                if name.startswith("wl"):
                    iface = name
                    break
        except OSError:
            pass
        try:
            subprocess.run(["iwctl", "station", iface, "scan"], capture_output=True, text=True, timeout=4.0, check=False)
            time.sleep(0.8)
            res = subprocess.run(
                ["iwctl", "station", iface, "get-networks"],
                capture_output=True,
                text=True,
                timeout=4.0,
                check=False,
            )
            ansi_re = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
            networks: list[dict] = []
            seen: set[str] = set()
            for raw_ln in (res.stdout or "").splitlines():
                clean = ansi_re.sub("", raw_ln).strip()
                if not clean or clean.startswith("Available") or clean.startswith("Network name") or clean.startswith("---"):
                    continue
                if clean.startswith(">"):
                    clean = clean[1:].strip()
                parts = re.split(r"\s{2,}", clean)
                if len(parts) >= 2:
                    ssid = parts[0].strip()
                    sec = parts[1].strip() if len(parts) >= 2 else ""
                    sig = parts[2].strip() if len(parts) >= 3 else ""
                    if ssid and ssid not in seen:
                        seen.add(ssid)
                        networks.append({"ssid": ssid, "security": sec, "signal": sig})
            return networks
        except Exception as exc:
            self.log_proxy("warn", f"scan_wifi failed: {exc}")
            return []

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

        self.log_proxy("info", f"configure_wifi requested for SSID='{ssid}'")
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
            res = subprocess.run(
                [net_script, "--connect", ssid, "--state-dir", self.state_dir],
                env=env,
                capture_output=True,
                text=True,
                check=False,
                timeout=35,
            )
            if res.returncode != 0:
                self.log_proxy("error", f"5s-net-fast.sh --connect failed (rc={res.returncode}): {res.stderr.strip()}")
                return False, f"Failed to connect to {ssid}"

        with open(os.path.join(self.state_dir, "wifi_configured"), "w", encoding="utf-8") as f:
            f.write(f"{ssid}\n")
        with self.lock:
            self.ssid = ssid
        self.log_proxy("info", f"configure_wifi succeeded for SSID='{ssid}'")
        return True, "Connected"

    def get_wifi_info(self, allow_subprocess: bool = False) -> dict:
        with self.lock:
            ssid = self.ssid
            pct = self.signal_percent
            dbm = self.signal_dbm
            online = self.online

        if not ssid:
            cfg_path = os.path.join(self.state_dir, "wifi_configured")
            if os.path.isfile(cfg_path):
                try:
                    with open(cfg_path, "r", encoding="utf-8", errors="replace") as f:
                        ssid = f.readline().strip()
                except OSError:
                    pass

        if os.environ.get("MOCK_MODE", "0") == "1":
            if pct is None and dbm is None and online and ssid:
                pct = 82
                dbm = -55
            return {"ssid": ssid, "signal_percent": pct, "signal_dbm": dbm}

        # Fast path: read /proc/net/wireless (<0.1ms, no subprocess)
        if os.path.isfile("/proc/net/wireless"):
            try:
                with open("/proc/net/wireless", "r", encoding="utf-8", errors="replace") as f:
                    lines = f.read().splitlines()
                for ln in lines[2:]:
                    if ":" not in ln:
                        continue
                    iface_part, rest = ln.split(":", 1)
                    iface_name = iface_part.strip()
                    if not iface_name:
                        continue
                    cols = rest.split()
                    if len(cols) >= 3:
                        try:
                            link_val = float(cols[1].rstrip("."))
                            level_val = float(cols[2].rstrip("."))
                            if level_val > 110:
                                level_val -= 256.0
                            dbm_cand = int(round(level_val)) if level_val < 0 else None
                            if 0 < link_val <= 70:
                                pct_cand = min(100, max(0, int(round(link_val * 100.0 / 70.0))))
                            elif dbm_cand is not None:
                                pct_cand = min(100, max(0, int(round(2 * (dbm_cand + 100)))))
                            else:
                                pct_cand = None
                            if pct_cand is not None:
                                pct = pct_cand
                            if dbm_cand is not None:
                                dbm = dbm_cand
                            if iface_name.startswith("wl"):
                                break
                        except ValueError:
                            continue
            except OSError:
                pass

        # Fallback: iwctl station <iface> show (rate-limited, only when allow_subprocess=True)
        now = time.monotonic()
        if allow_subprocess and (pct is None or not ssid) and (now - self._last_wifi_probe >= 5.0):
            self._last_wifi_probe = now
            iface = "wlan0"
            try:
                for name in sorted(os.listdir("/sys/class/net")):
                    if name.startswith("wl"):
                        iface = name
                        break
            except OSError:
                pass
            try:
                res = subprocess.run(
                    ["iwctl", "station", iface, "show"],
                    capture_output=True,
                    text=True,
                    timeout=1.5,
                    check=False,
                )
                ansi_re = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
                for raw_ln in (res.stdout or "").splitlines():
                    clean = ansi_re.sub("", raw_ln).strip()
                    m_ssid = re.match(r"Connected network\s+(.+)$", clean, re.IGNORECASE)
                    if m_ssid and not ssid:
                        ssid = m_ssid.group(1).strip()
                    m_rssi = re.match(r"RSSI\s+(-?\d+)\s*dBm", clean, re.IGNORECASE)
                    if m_rssi:
                        dbm = int(m_rssi.group(1))
                        pct = min(100, max(0, 2 * (dbm + 100)))
                if ssid or pct is not None or dbm is not None:
                    with self.lock:
                        if ssid and not self.ssid:
                            self.ssid = ssid
                        if pct is not None:
                            self.signal_percent = pct
                        if dbm is not None:
                            self.signal_dbm = dbm
            except Exception:
                pass

        return {"ssid": ssid, "signal_percent": pct, "signal_dbm": dbm}

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

    def broadcast_sse(self, event_name: str, payload: dict) -> None:
        msg = f"event: {event_name}\ndata: {json.dumps(payload)}\n\n".encode("utf-8")
        with self.lock:
            for q in list(self.sse_clients):
                try:
                    q.put_nowait(msg)
                except queue.Full:
                    pass

    def broadcast_delta(self, payload: dict) -> None:
        self.broadcast_sse("delta", payload)

    def broadcast_disc(self, payload: dict) -> None:
        self.broadcast_sse("disc", payload)

    def fetch_and_cache(self, url: str) -> bool:
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "5s-browser/0.1"})
            with urllib.request.urlopen(req, timeout=3.0) as resp:
                status = resp.getcode()
                ctype = resp.headers.get("Content-Type", "text/html; charset=utf-8")
                body = resp.read()
                self.put_cache(url, status, ctype, body)
                return True
        except Exception as exc:
            self.log_proxy("error", f"fetch_and_cache({url}) failed: {exc}")
            return False

    def update_network_state(self, data: dict) -> None:
        is_online = bool(data.get("online", True))
        ssid = str(data.get("ssid", "") or "")
        ip = str(data.get("ip", "") or "")
        gw = str(data.get("gw", "") or "")
        internet_ok = bool(data.get("internet_ok", is_online))
        net_error = str(data.get("error", "") or "")
        sig_pct = data.get("signal_percent")
        sig_dbm = data.get("signal_dbm")

        with self.lock:
            self.online = is_online
            if ssid:
                self.ssid = ssid
            if ip:
                self.ip = ip
            if gw:
                self.gw = gw
            if isinstance(sig_pct, (int, float)):
                self.signal_percent = min(100, max(0, int(sig_pct)))
            if isinstance(sig_dbm, (int, float)):
                self.signal_dbm = int(sig_dbm)
                if not isinstance(sig_pct, (int, float)):
                    self.signal_percent = min(100, max(0, 2 * (self.signal_dbm + 100)))
            self.internet_ok = internet_ok
            self.net_error = "" if is_online else net_error

        if is_online:
            self.log_proxy("info", f"network online: ssid='{self.ssid}' ip='{self.ip}' gw='{self.gw}'")
            self.trigger_online_sync()
        else:
            wifi = self.get_wifi_info(allow_subprocess=False)
            self.log_proxy("warn", f"network offline/error: ssid='{self.ssid}' err='{self.net_error}'")
            self.broadcast_sse(
                "net_status",
                {
                    "online": False,
                    "ssid": wifi["ssid"],
                    "signal_percent": wifi["signal_percent"],
                    "signal_dbm": wifi["signal_dbm"],
                    "ip": self.ip,
                    "error": self.net_error,
                },
            )

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
            wifi = self.get_wifi_info(allow_subprocess=False)
            self.broadcast_delta(
                {
                    "updated": updated,
                    "last_sync": self.last_sync,
                    "ssid": wifi["ssid"],
                    "signal_percent": wifi["signal_percent"],
                    "signal_dbm": wifi["signal_dbm"],
                    "ip": self.ip,
                    "gmail_html": gmail_html,
                    "youtube_html": yt_html,
                }
            )

        threading.Thread(target=_worker, daemon=True).start()


def render_wifi_setup_html(features: dict[str, bool] | None = None) -> bytes:
    if features is None:
        features = {"gmail": True, "youtube": True, "disc": True}
    enabled_net = []
    if features.get("gmail", True):
        enabled_net.append("Gmail")
    if features.get("youtube", True):
        enabled_net.append("YouTube")
    subtitle_target = " &amp; ".join(enabled_net) if enabled_net else "online services"
    disc_btn_html = (
        '<button id="btn-offline-disc" type="button" class="btn-secondary">Watch DVD / Blu-ray Offline</button>'
        if features.get("disc", True)
        else ""
    )
    disc_js = (
        'document.getElementById("btn-offline-disc").addEventListener("click", function () {\n'
        '      window.location.href = "/app?tab=disc";\n'
        '    });'
        if features.get("disc", True)
        else ""
    )
    html = f"""<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>5s-browser Wi-Fi Setup</title>
<style>
  html, body {{ margin: 0; padding: 0; width: 100vw; height: 100vh; overflow: hidden; font-family: sans-serif; background: #0f172a; color: #f8fafc; display: flex; align-items: center; justify-content: center; }}
  .card {{ width: 420px; background: #1e293b; border-radius: 10px; padding: 28px; box-shadow: 0 10px 30px rgba(0,0,0,0.4); }}
  h1 {{ margin: 0 0 8px 0; font-size: 20px; }}
  p {{ margin: 0 0 20px 0; font-size: 13px; color: #94a3b8; }}
  label {{ display: block; font-size: 13px; margin-bottom: 6px; color: #cbd5e1; }}
  input {{ width: 100%; box-sizing: border-box; padding: 10px; margin-bottom: 14px; border: 1px solid #334155; border-radius: 6px; background: #0f172a; color: #fff; font-size: 14px; }}
  button {{ width: 100%; padding: 11px; border: none; border-radius: 6px; background: #3b82f6; color: #fff; font-size: 15px; font-weight: bold; cursor: pointer; }}
  .btn-secondary {{ margin-top: 10px; background: #334155; font-size: 13px; padding: 9px; }}
  .btn-scan {{ margin-bottom: 10px; background: #0f766e; font-size: 13px; padding: 8px; }}
  #scan-list {{ display: none; max-height: 120px; overflow-y: auto; margin-bottom: 12px; border: 1px solid #334155; border-radius: 6px; background: #0f172a; }}
  .net-item {{ padding: 7px 10px; font-size: 13px; cursor: pointer; display: flex; justify-content: space-between; border-bottom: 1px solid #1e293b; }}
  .net-item:hover {{ background: #1e293b; }}
  .diag-link {{ margin-top: 12px; text-align: center; font-size: 12px; color: #64748b; }}
  .diag-link a {{ color: #38bdf8; text-decoration: none; }}
  #msg {{ margin-top: 12px; font-size: 13px; color: #fbbf24; min-height: 18px; }}
</style>
</head>
<body>
  <div class="card">
    <h1>Connect to Wi-Fi</h1>
    <p>One-time setup for {subtitle_target}. Everything else is automatic.</p>
    <button id="btn-scan-wifi" type="button" class="btn-scan">Scan Wi-Fi Networks</button>
    <div id="scan-list"></div>
    <form id="wifi-form">
      <label for="ssid">Wi-Fi Name (SSID)</label>
      <input id="ssid" name="ssid" type="text" required autofocus placeholder="Your Wi-Fi network">
      <label for="password">Wi-Fi Password</label>
      <input id="password" name="password" type="password" placeholder="WPA2 passphrase">
      <button type="submit">Connect &amp; Start</button>
    </form>
    {disc_btn_html}
    <div id="msg"></div>
    <div class="diag-link"><a href="/diag">System Diagnostics (F12)</a></div>
  </div>
  <script>
    {disc_js}
    window.addEventListener("keydown", function (e) {{
      if (e.key === "F12") {{ e.preventDefault(); window.location.href = "/diag"; }}
    }});
    document.getElementById("btn-scan-wifi").addEventListener("click", async function () {{
      const list = document.getElementById("scan-list");
      const msg = document.getElementById("msg");
      msg.textContent = "Scanning Wi-Fi networks...";
      try {{
        const res = await fetch("/__5s__/wifi-scan");
        const data = await res.json();
        const nets = data.networks || [];
        list.innerHTML = "";
        if (nets.length === 0) {{
          list.style.display = "none";
          msg.textContent = "No Wi-Fi networks found yet. Check Diagnostics (F12).";
          return;
        }}
        nets.forEach(function (n) {{
          const row = document.createElement("div");
          row.className = "net-item";
          const left = document.createElement("span");
          left.textContent = n.ssid;
          const right = document.createElement("span");
          right.style.color = "#94a3b8";
          right.textContent = [n.security, n.signal].filter(Boolean).join(" ");
          row.appendChild(left);
          row.appendChild(right);
          row.addEventListener("click", function () {{
            document.getElementById("ssid").value = n.ssid;
            document.getElementById("password").focus();
          }});
          list.appendChild(row);
        }});
        list.style.display = "block";
        msg.textContent = "Select a network or enter SSID manually.";
      }} catch (err) {{
        msg.textContent = "Scan error: " + err;
      }}
    }});
    document.getElementById("wifi-form").addEventListener("submit", async function (e) {{
      e.preventDefault();
      const msg = document.getElementById("msg");
      msg.textContent = "Connecting...";
      const ssid = document.getElementById("ssid").value;
      const password = document.getElementById("password").value;
      try {{
        const res = await fetch("/__5s__/wifi-setup", {{
          method: "POST",
          headers: {{ "Content-Type": "application/json" }},
          body: JSON.stringify({{ ssid: ssid, password: password }})
        }});
        const data = await res.json();
        if (data.ok) {{
          window.location.href = data.redirect || "/app";
        }} else {{
          msg.textContent = data.error || "Connection failed";
        }}
      }} catch (err) {{
        msg.textContent = "Setup error: " + err;
      }}
    }});
  </script>
</body>
</html>
"""
    return html.encode("utf-8")


def format_wifi_status(ssid: str, signal_percent: int | None) -> str:
    if ssid and signal_percent is not None:
        return f"{ssid} ({signal_percent}%)"
    if ssid:
        return f"{ssid}"
    return "No Wi-Fi"


def render_app_html(state: ProxyState, requested_tab: str = "") -> bytes:
    features = state.get_features()
    needs_wifi = features["gmail"] or features["youtube"]
    if not state.is_wifi_configured() and needs_wifi and not (requested_tab == "disc" and features["disc"]):
        return render_wifi_setup_html(features)

    enabled_tabs = [t for t in ("gmail", "youtube", "disc") if features[t]]
    if requested_tab in enabled_tabs:
        active_tab = requested_tab
    elif enabled_tabs:
        active_tab = enabled_tabs[0]
    else:
        active_tab = ""

    gmail_html, yt_html = state.get_app_state()
    pill_text = "● Live" if state.online else "● Cached (Connecting...)"
    pill_color = "#4ade80" if state.online else "#fbbf24"
    wifi = state.get_wifi_info(allow_subprocess=False)
    wifi_text = html_lib.escape(format_wifi_status(wifi["ssid"], wifi["signal_percent"]))
    wifi_title = html_lib.escape(
        f"{wifi['ssid']} ({wifi['signal_percent']}%, {wifi['signal_dbm']} dBm)"
        if wifi["ssid"] and wifi["signal_percent"] is not None and wifi["signal_dbm"] is not None
        else (wifi["ssid"] or "Wi-Fi Network & Signal")
    )

    svg_gmail = '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="1.75" y="3" width="12.5" height="10" rx="1.5"/><path d="M2 4l6 4.5L14 4"/></svg>'
    svg_yt = '<svg viewBox="0 0 16 16" fill="currentColor"><path d="M5.5 3.8v8.4L12.5 8l-7-4.2z"/></svg>'
    svg_disc = '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5"><circle cx="8" cy="8" r="6"/><circle cx="8" cy="8" r="1.8"/></svg>'
    svg_wifi = '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"><path d="M2.2 6.2a8.5 8.5 0 0 1 11.6 0"/><path d="M4.6 8.9a5.2 5.2 0 0 1 6.8 0"/><circle cx="8" cy="12" r="1" fill="currentColor" stroke="none"/></svg>'

    tab_buttons = []
    if features["gmail"]:
        cls = "tab-btn active" if active_tab == "gmail" else "tab-btn"
        tab_buttons.append(f'<button id="tab-btn-gmail" class="{cls}">{svg_gmail}<span>Gmail</span><kbd>F1</kbd></button>')
    if features["youtube"]:
        cls = "tab-btn active" if active_tab == "youtube" else "tab-btn"
        tab_buttons.append(f'<button id="tab-btn-youtube" class="{cls}">{svg_yt}<span>YouTube</span><kbd>F2</kbd></button>')
    if features["disc"]:
        cls = "tab-btn active" if active_tab == "disc" else "tab-btn"
        tab_buttons.append(f'<button id="tab-btn-disc" class="{cls}">{svg_disc}<span>Disc</span><span id="disc-tab-dot" class="disc-dot" hidden></span><kbd>F3</kbd></button>')
    tabs_html = "\n      ".join(tab_buttons)

    panes = []
    if features["gmail"]:
        cls = "pane active" if active_tab == "gmail" else "pane"
        panes.append(f'<div id="pane-gmail" class="{cls}">\n      <div id="gmail-feed">{gmail_html}</div>\n    </div>')
    if features["youtube"]:
        cls = "pane active" if active_tab == "youtube" else "pane"
        panes.append(f'<div id="pane-youtube" class="{cls}">\n      <div id="youtube-feed">{yt_html}</div>\n    </div>')
    if features["disc"]:
        cls = "pane active" if active_tab == "disc" else "pane"
        panes.append(
            f'<div id="pane-disc" class="{cls}">\n'
            '      <div class="disc-card">\n'
            '        <h2 id="disc-title">Optical Drive</h2>\n'
            '        <div id="disc-caps" class="disc-meta">Checking built-in drive...</div>\n'
            '        <div class="disc-actions">\n'
            '          <button id="btn-disc-play" class="disc-btn" disabled>&#9654; Play Disc</button>\n'
            '          <button id="btn-disc-stop" class="disc-btn stop" disabled>&#9632; Stop</button>\n'
            '          <button id="btn-disc-eject" class="disc-btn eject" disabled>&#9167; Eject</button>\n'
            '        </div>\n'
            '        <div id="disc-msg" class="disc-msg"></div>\n'
            '        <div class="disc-keys">\n'
            '          <b>Controls while playing:</b> Space = Play/Pause &bull; &larr;/&rarr; = Seek &bull; &uarr;/&darr; = Volume &bull; j = Subtitles &bull; # = Audio &bull; Esc / q = Return to Browser\n'
            '        </div>\n'
            '      </div>\n'
            '    </div>'
        )
    if not panes:
        panes.append(
            '<div class="pane active" style="background:#0f172a;color:#94a3b8;display:flex;align-items:center;justify-content:center;">'
            'All features are disabled in wifi.txt.'
            '</div>'
        )
    panes_html = "\n    ".join(panes)

    html = f"""<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>5s-browser</title>
<style>
  html, body {{ margin: 0; padding: 0; width: 100vw; height: 100vh; overflow: hidden; font-family: system-ui, -apple-system, 'Segoe UI', Roboto, sans-serif; background: #111; color: #eee; }}
  #topbar {{ height: 34px; background: #0f172a; border-bottom: 1px solid rgba(255, 255, 255, 0.08); display: flex; align-items: center; justify-content: space-between; padding: 0 10px; box-sizing: border-box; font-size: 12px; user-select: none; }}
  .tabs {{ display: flex; align-items: center; gap: 6px; }}
  .tab-btn {{ display: inline-flex; align-items: center; gap: 6px; height: 24px; padding: 0 10px; border: 1px solid transparent; border-radius: 6px; background: rgba(255, 255, 255, 0.06); color: #cbd5e1; font-family: inherit; font-size: 12px; font-weight: 500; cursor: pointer; transition: background 0.15s ease, color 0.15s ease, border-color 0.15s ease; outline: none; }}
  .tab-btn:hover {{ background: rgba(255, 255, 255, 0.12); color: #f8fafc; }}
  .tab-btn.active {{ background: #2563eb; border-color: rgba(255, 255, 255, 0.15); color: #ffffff; font-weight: 600; box-shadow: 0 1px 2px rgba(0, 0, 0, 0.25); }}
  .tab-btn svg, #wifi-status svg {{ width: 14px; height: 14px; flex-shrink: 0; display: block; }}
  .tab-btn kbd {{ font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 10px; line-height: 1; padding: 2px 5px; border-radius: 4px; background: rgba(0, 0, 0, 0.25); border: 1px solid rgba(255, 255, 255, 0.12); color: inherit; opacity: 0.85; }}
  .disc-dot {{ width: 6px; height: 6px; border-radius: 50%; background: #4ade80; display: inline-block; }}
  .disc-dot[hidden] {{ display: none; }}
  .topbar-right {{ display: flex; align-items: center; gap: 10px; font-size: 11px; }}
  #wifi-status {{ display: inline-flex; align-items: center; gap: 5px; color: #94a3b8; white-space: nowrap; }}
  #topbar-clock {{ color: #e2e8f0; font-variant-numeric: tabular-nums; white-space: nowrap; }}
  .diag-link-btn {{ display: inline-flex; align-items: center; gap: 4px; height: 22px; padding: 0 8px; border-radius: 5px; border: 1px solid rgba(255, 255, 255, 0.1); background: transparent; color: #94a3b8; font-family: inherit; font-size: 11px; text-decoration: none; cursor: pointer; }}
  .diag-link-btn:hover {{ background: rgba(255, 255, 255, 0.08); color: #e2e8f0; }}
  .diag-link-btn kbd {{ font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 10px; line-height: 1; padding: 1px 4px; border-radius: 3px; background: rgba(0, 0, 0, 0.25); border: 1px solid rgba(255, 255, 255, 0.12); color: inherit; }}
  #status-pill {{ font-size: 11px; font-weight: 500; padding: 2px 8px; border-radius: 999px; background: rgba(255, 255, 255, 0.06); border: 1px solid rgba(255, 255, 255, 0.1); white-space: nowrap; }}
  #viewport {{ position: relative; width: 100%; height: calc(100vh - 34px); }}
  .pane {{ position: absolute; inset: 0; overflow-y: auto; padding: 12px; background: #fff; color: #111; visibility: hidden; pointer-events: none; }}
  .pane.active {{ visibility: visible; pointer-events: auto; }}
  #pane-youtube {{ background: #0f0f0f; color: #f1f1f1; }}
  #pane-disc {{ background: #0f172a; color: #f1f5f9; display: flex; align-items: center; justify-content: center; }}
  .disc-card {{ width: 520px; background: #1e293b; border-radius: 10px; padding: 24px; box-shadow: 0 8px 24px rgba(0,0,0,0.45); }}
  .disc-card h2 {{ margin: 0 0 8px 0; font-size: 20px; }}
  .disc-meta {{ font-size: 13px; color: #94a3b8; margin-bottom: 16px; line-height: 1.5; }}
  .disc-actions {{ display: flex; gap: 10px; margin-bottom: 14px; }}
  .disc-btn {{ border: none; border-radius: 6px; padding: 10px 16px; font-size: 14px; font-weight: bold; cursor: pointer; color: #fff; background: #3b82f6; }}
  .disc-btn:disabled {{ opacity: 0.45; cursor: not-allowed; }}
  .disc-btn.stop {{ background: #dc2626; }}
  .disc-btn.eject {{ background: #475569; }}
  .disc-msg {{ font-size: 13px; color: #fbbf24; min-height: 18px; margin-bottom: 12px; }}
  .disc-keys {{ font-size: 12px; color: #94a3b8; border-top: 1px solid #334155; padding-top: 10px; }}
</style>
</head>
<body>
  <div id="topbar">
    <div class="tabs">
      {tabs_html}
    </div>
    <div class="topbar-right">
      <div id="wifi-status" title="{wifi_title}">{svg_wifi}<span id="wifi-status-text">{wifi_text}</span></div>
      <div id="topbar-clock" title="Local Time">--:--</div>
      <a class="diag-link-btn" href="/diag"><span>Diag</span><kbd>F12</kbd></a>
      <div id="status-pill" style="color: {pill_color};">{pill_text}</div>
    </div>
  </div>
  <div id="viewport">
    {panes_html}
  </div>
  <script>{state.ui_js}</script>
</body>
</html>
"""
    return html.encode("utf-8")


def get_image_version() -> str:
    env_ver = os.environ.get("APP_VERSION", "").strip()
    if env_ver:
        return env_ver
    here = os.path.dirname(os.path.abspath(__file__))
    candidates = [
        "/opt/5s-browser/VERSION",
        os.path.abspath(os.path.join(here, "..", "VERSION")),
        os.path.abspath(os.path.join(here, "..", "..", "VERSION")),
    ]
    for path in candidates:
        if os.path.isfile(path):
            try:
                with open(path, "r", encoding="utf-8") as f:
                    ver = f.read().strip()
                if ver:
                    return ver
            except OSError:
                pass
    return "0.7.0"


def _tail_file(path: str, max_lines: int = 35) -> list[str]:
    if not os.path.isfile(path):
        return []
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
        return lines[-max_lines:]
    except OSError:
        return []


def collect_diagnostics(state: ProxyState) -> dict:
    uptime_s = None
    try:
        with open("/proc/uptime", "r", encoding="utf-8") as f:
            uptime_s = float(f.read().split()[0])
    except Exception:
        pass

    uname = os.uname()
    log_files: list[dict] = []
    if os.path.isdir(state.logs_dir):
        for name in sorted(os.listdir(state.logs_dir)):
            full = os.path.join(state.logs_dir, name)
            if os.path.isfile(full):
                try:
                    log_files.append({"name": name, "bytes": os.path.getsize(full)})
                except OSError:
                    pass

    audio_cards: list[str] = []
    if os.path.isfile("/proc/asound/cards"):
        try:
            with open("/proc/asound/cards", "r", encoding="utf-8", errors="replace") as f:
                audio_cards = [ln.rstrip() for ln in f.read().splitlines() if ln.strip()]
        except OSError:
            pass

    resolv_conf: list[str] = []
    if os.path.isfile("/etc/resolv.conf"):
        try:
            with open("/etc/resolv.conf", "r", encoding="utf-8", errors="replace") as f:
                resolv_conf = [ln.strip() for ln in f.read().splitlines() if ln.strip() and not ln.strip().startswith("#")]
        except OSError:
            pass

    return {
        "version": get_image_version(),
        "uptime_s": uptime_s,
        "kernel": f"{uname.sysname} {uname.release} ({uname.machine})",
        "hostname": uname.nodename,
        "mock_mode": os.environ.get("MOCK_MODE", "0") == "1",
        "state_dir": state.state_dir,
        "audio_cards": audio_cards,
        "resolv_conf": resolv_conf,
        "network": {
            "online": state.online,
            "wifi_configured": state.is_wifi_configured(),
            "ssid": state.ssid,
            "ip": state.ip,
            "gw": state.gw,
            "internet_ok": state.internet_ok,
            "net_error": state.net_error,
            "last_sync": state.last_sync,
            "cached_items": state.cached_count(),
        },
        "disc": state.disc_manager.probe(),
        "logs": {
            "files": log_files,
            "network_tail": _tail_file(os.path.join(state.logs_dir, "network.log")),
            "apps_tail": _tail_file(os.path.join(state.logs_dir, "apps.log")),
            "audio_tail": _tail_file(os.path.join(state.logs_dir, "audio.log")),
            "mpv_tail": _tail_file(os.path.join(state.logs_dir, "mpv.log")),
            "init_tail": _tail_file(os.path.join(state.logs_dir, "init.log")),
            "proxy_tail": _tail_file(os.path.join(state.logs_dir, "proxy.log")),
            "timeline_tail": _tail_file(os.path.join(state.logs_dir, "boot-timeline.log")),
        },
    }


def render_diag_html() -> bytes:
    html = """<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>5s-browser Diagnostics</title>
<style>
  * { box-sizing: border-box; }
  body { margin: 0; padding: 16px; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; background: #0b1220; color: #e2e8f0; font-size: 13px; }
  header { display: flex; align-items: center; justify-content: space-between; border-bottom: 1px solid #1e293b; padding-bottom: 10px; margin-bottom: 14px; }
  h1 { margin: 0; font-size: 16px; color: #38bdf8; }
  .actions { display: flex; gap: 8px; }
  button { background: #1e293b; color: #e2e8f0; border: 1px solid #334155; border-radius: 5px; padding: 6px 12px; cursor: pointer; font-family: inherit; font-size: 12px; }
  button:hover { background: #334155; }
  .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(320px, 1fr)); gap: 12px; margin-bottom: 12px; }
  .card { background: #111a2e; border: 1px solid #1e293b; border-radius: 8px; padding: 12px; }
  .card h2 { margin: 0 0 8px 0; font-size: 13px; color: #94a3b8; text-transform: uppercase; letter-spacing: 0.05em; }
  table { width: 100%; border-collapse: collapse; }
  td { padding: 3px 0; vertical-align: top; }
  td:first-child { color: #94a3b8; width: 42%; }
  .ok { color: #4ade80; font-weight: bold; }
  .warn { color: #fbbf24; font-weight: bold; }
  .err { color: #f87171; font-weight: bold; }
  pre { margin: 6px 0 0 0; background: #070c16; border: 1px solid #1e293b; border-radius: 6px; padding: 8px; max-height: 180px; overflow: auto; white-space: pre-wrap; word-break: break-word; font-size: 11px; line-height: 1.4; }
</style>
</head>
<body>
  <header>
    <h1>5s-browser Diagnostics <span id="hdr-ver" style="color:#94a3b8;font-weight:normal;"></span></h1>
    <div class="actions">
      <button id="btn-refresh">Refresh</button>
      <button id="btn-back">Back to App (F1)</button>
    </div>
  </header>
  <div class="grid">
    <div class="card">
      <h2>System &amp; Image</h2>
      <table id="tbl-sys"></table>
    </div>
    <div class="card">
      <h2>Network Status</h2>
      <table id="tbl-net"></table>
    </div>
    <div class="card">
      <h2>CD / DVD / Blu-ray Drive</h2>
      <table id="tbl-disc"></table>
    </div>
  </div>
  <div class="grid">
    <div class="card">
      <h2>network.log</h2>
      <pre id="log-net">(loading...)</pre>
    </div>
    <div class="card">
      <h2>apps.log</h2>
      <pre id="log-apps">(loading...)</pre>
    </div>
    <div class="card">
      <h2>init.log / proxy.log</h2>
      <pre id="log-init">(loading...)</pre>
    </div>
  </div>
  <script>
    function esc(s) {
      return String(s === undefined || s === null ? "" : s)
        .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    }
    function row(k, v, cls) {
      return "<tr><td>" + esc(k) + "</td><td class='" + (cls || "") + "'>" + esc(v) + "</td></tr>";
    }
    async function loadDiag() {
      try {
        const res = await fetch("/__5s__/diagnostics");
        const d = await res.json();
        document.getElementById("hdr-ver").textContent = "v" + d.version;
        document.getElementById("tbl-sys").innerHTML = [
          row("Release Version", d.version, "ok"),
          row("Kernel", d.kernel),
          row("Hostname", d.hostname),
          row("Uptime", d.uptime_s !== null ? d.uptime_s.toFixed(1) + " s" : "n/a"),
          row("State Dir", d.state_dir),
          row("Audio Cards", (d.audio_cards || []).join(" | ") || "none"),
          row("Log Files", (d.logs.files || []).map(f => f.name + " (" + f.bytes + "B)").join(", ") || "none")
        ].join("");

        const n = d.network || {};
        document.getElementById("tbl-net").innerHTML = [
          row("Online", n.online ? "YES (Live)" : "NO (Offline)", n.online ? "ok" : "warn"),
          row("Wi-Fi Configured", n.wifi_configured ? "Yes" : "No"),
          row("SSID", n.ssid || "(none)"),
          row("IPv4 Address", n.ip || "(none)"),
          row("Gateway", n.gw || "(none)"),
          row("DNS (resolv.conf)", (d.resolv_conf || []).join(", ") || "(empty)"),
          row("Internet / HTTPS", n.internet_ok ? "Reachable" : "Unreachable", n.internet_ok ? "ok" : "warn"),
          row("Last Error", n.net_error || "none", n.net_error ? "err" : ""),
          row("Cached Items", n.cached_items)
        ].join("");

        const c = d.disc || {};
        document.getElementById("tbl-disc").innerHTML = [
          row("Drive Present", c.drive_present ? "Yes (" + (c.device || "/dev/sr0") + ")" : "No", c.drive_present ? "ok" : "warn"),
          row("Drive Model", c.model || "n/a"),
          row("Capabilities", "DVD=" + (c.supports_dvd ? "Yes" : "No") + ", Blu-ray=" + (c.supports_bluray ? "Yes" : "No")),
          row("DVD CSS (libdvdcss2)", c.libdvdcss_present ? "Installed" : "Missing (unencrypted DVDs only)", c.libdvdcss_present ? "ok" : "warn"),
          row("Disc Inserted", c.disc_present ? "Yes (" + c.media_type + ")" : "No"),
          row("Disc Label", c.label || "n/a"),
          row("AACS KEYDB.cfg", c.aacs_keydb_present ? "Present" : "Not found"),
          row("Playback", c.playing ? "Playing (" + c.playing_type + ")" : "Idle"),
          row("Last Error", c.last_error || "none", c.last_error ? "err" : "")
        ].join("");

        document.getElementById("log-net").textContent = (d.logs.network_tail || []).join("\\n") || "(empty)";
        document.getElementById("log-apps").textContent = (d.logs.apps_tail || []).join("\\n") || "(empty)";
        const combined = [].concat(
          d.logs.init_tail || [],
          ["--- proxy.log ---"],
          d.logs.proxy_tail || [],
          ["--- mpv.log ---"],
          d.logs.mpv_tail || []
        );
        document.getElementById("log-init").textContent = combined.join("\\n") || "(empty)";
      } catch (err) {
        document.getElementById("log-apps").textContent = "Failed to load diagnostics: " + err;
      }
    }
    document.getElementById("btn-refresh").addEventListener("click", loadDiag);
    document.getElementById("btn-back").addEventListener("click", function () {
      window.location.href = "/app";
    });
    window.addEventListener("keydown", function (e) {
      if (e.key === "Escape" || e.key === "F1") {
        e.preventDefault();
        window.location.href = "/app";
      } else if (e.key === "F5") {
        e.preventDefault();
        loadDiag();
      }
    });
    loadDiag();
    setInterval(loadDiag, 4000);
  </script>
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
                qs = urllib.parse.parse_qs(parsed.query)
                tab = qs.get("tab", [""])[0]
                self._send(200, "text/html; charset=utf-8", render_app_html(state, requested_tab=tab), "HIT")
                return

            if parsed.path in ("/diag", "/__5s__/diag"):
                self._send(200, "text/html; charset=utf-8", render_diag_html())
                return

            if parsed.path == "/__5s__/diagnostics":
                payload = json.dumps(collect_diagnostics(state)).encode("utf-8")
                self._send(200, "application/json", payload)
                return

            if parsed.path == "/__5s__/wifi-scan":
                payload = json.dumps({"networks": state.scan_wifi()}).encode("utf-8")
                self._send(200, "application/json", payload)
                return

            if parsed.path == "/__5s__/disc/status":
                if not state.get_features()["disc"]:
                    payload = json.dumps(
                        {"enabled": False, "drive_present": False, "disc_present": False, "playing": False}
                    ).encode("utf-8")
                    self._send(200, "application/json", payload)
                    return
                payload = json.dumps(state.disc_manager.probe()).encode("utf-8")
                self._send(200, "application/json", payload)
                return

            if parsed.path == "/__5s__/profiles":
                payload = json.dumps(state.get_profiles_public()).encode("utf-8")
                self._send(200, "application/json", payload)
                return

            if parsed.path == "/__5s__/hw/status":
                payload = json.dumps(state.get_hw_status()).encode("utf-8")
                self._send(200, "application/json", payload)
                return

            if parsed.path == "/__5s__/status":
                wifi = state.get_wifi_info(allow_subprocess=True)
                prof_info = state.get_profiles_public()
                payload = json.dumps(
                    {
                        "online": state.online,
                        "cached_items": state.cached_count(),
                        "last_sync": state.last_sync,
                        "wifi_configured": state.is_wifi_configured(),
                        "ssid": wifi["ssid"],
                        "signal_percent": wifi["signal_percent"],
                        "signal_dbm": wifi["signal_dbm"],
                        "ip": state.ip,
                        "gw": state.gw,
                        "internet_ok": state.internet_ok,
                        "net_error": state.net_error,
                        "features": state.get_features(),
                        "active_profile": prof_info.get("active_profile"),
                        "battery": state.get_battery_info(),
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
                            msg = q.get(timeout=15.0)
                            self.wfile.write(msg)
                            self.wfile.flush()
                        except queue.Empty:
                            self.wfile.write(b": keepalive\n\n")
                            self.wfile.flush()
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
                try:
                    data = json.loads(raw.decode("utf-8") or "{}")
                except Exception:
                    data = {}
                if not isinstance(data, dict):
                    data = {}
                state.update_network_state(data)
                self._send(200, "application/json", b'{"ok":true}')
                return
            if self.path == "/__5s__/app-log":
                try:
                    data = json.loads(raw.decode("utf-8") or "{}")
                except Exception:
                    data = {}
                level = str(data.get("level", "info"))
                source = str(data.get("source", "app"))
                message = str(data.get("message", ""))
                extra = data.get("extra") if isinstance(data.get("extra"), dict) else None
                state.log_app(level, source, message, extra)
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
            if self.path in ("/__5s__/disc/play", "/__5s__/disc/stop", "/__5s__/disc/eject") and not state.get_features()["disc"]:
                self._send(
                    403,
                    "application/json",
                    json.dumps({"ok": False, "message": "Disc feature is disabled"}).encode("utf-8"),
                )
                return
            if self.path == "/__5s__/disc/play":
                try:
                    data = json.loads(raw.decode("utf-8") or "{}")
                except Exception:
                    data = {}
                disc_type = data.get("type")
                ok, msg = state.disc_manager.play(disc_type)
                code = 200 if ok else 400
                self._send(
                    code,
                    "application/json",
                    json.dumps({"ok": ok, "message": msg, "status": state.disc_manager.probe()}).encode("utf-8"),
                )
                return
            if self.path == "/__5s__/disc/stop":
                ok, msg = state.disc_manager.stop()
                self._send(
                    200 if ok else 400,
                    "application/json",
                    json.dumps({"ok": ok, "message": msg, "status": state.disc_manager.probe()}).encode("utf-8"),
                )
                return
            if self.path == "/__5s__/disc/eject":
                ok, msg = state.disc_manager.eject()
                self._send(
                    200 if ok else 400,
                    "application/json",
                    json.dumps({"ok": ok, "message": msg, "status": state.disc_manager.probe()}).encode("utf-8"),
                )
                return
            if self.path == "/__5s__/profiles/save":
                try:
                    data = json.loads(raw.decode("utf-8") or "{}")
                except Exception:
                    data = {}
                ok, msg, prof = state.save_profile(
                    data.get("id"),
                    str(data.get("name", "")),
                    data.get("color"),
                    data.get("pin"),
                    bool(data.get("clear_pin", False)),
                    data.get("features") if isinstance(data.get("features"), dict) else None,
                )
                self._send(
                    200 if ok else 400,
                    "application/json",
                    json.dumps({"ok": ok, "error": None if ok else msg, "profile": prof, "state": state.get_profiles_public()}).encode("utf-8"),
                )
                return
            if self.path == "/__5s__/profiles/delete":
                try:
                    data = json.loads(raw.decode("utf-8") or "{}")
                except Exception:
                    data = {}
                ok, msg = state.delete_profile(str(data.get("id", "")))
                self._send(
                    200 if ok else 400,
                    "application/json",
                    json.dumps({"ok": ok, "error": None if ok else msg, "state": state.get_profiles_public()}).encode("utf-8"),
                )
                return
            if self.path == "/__5s__/profiles/switch":
                try:
                    data = json.loads(raw.decode("utf-8") or "{}")
                except Exception:
                    data = {}
                ok, msg = state.switch_profile(str(data.get("id", "")), str(data.get("pin", "")))
                self._send(
                    200 if ok else 403 if msg == "Invalid PIN" else 400,
                    "application/json",
                    json.dumps({"ok": ok, "error": None if ok else msg, "state": state.get_profiles_public()}).encode("utf-8"),
                )
                return
            if self.path == "/__5s__/profiles/reset":
                try:
                    data = json.loads(raw.decode("utf-8") or "{}")
                except Exception:
                    data = {}
                ok, msg = state.reset_profile(str(data.get("id", "")))
                self._send(
                    200 if ok else 400,
                    "application/json",
                    json.dumps({"ok": ok, "error": None if ok else msg}).encode("utf-8"),
                )
                return
            if self.path == "/__5s__/hw/volume":
                try:
                    data = json.loads(raw.decode("utf-8") or "{}")
                    pct = int(data.get("percent", 80))
                except Exception:
                    pct = 80
                ok, val = state.set_volume(pct)
                self._send(200 if ok else 500, "application/json", json.dumps({"ok": ok, "volume": val}).encode("utf-8"))
                return
            if self.path == "/__5s__/hw/brightness":
                try:
                    data = json.loads(raw.decode("utf-8") or "{}")
                    pct = int(data.get("percent", 80))
                except Exception:
                    pct = 80
                ok, val = state.set_brightness(pct)
                self._send(200 if ok else 500, "application/json", json.dumps({"ok": ok, "brightness": val}).encode("utf-8"))
                return
            if self.path == "/__5s__/hw/power":
                try:
                    data = json.loads(raw.decode("utf-8") or "{}")
                except Exception:
                    data = {}
                ok, msg = state.trigger_power(str(data.get("action", "")))
                self._send(200 if ok else 400, "application/json", json.dumps({"ok": ok, "action": msg}).encode("utf-8"))
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
    parser.add_argument("--host", default=os.environ.get("PROXY_HOST", "127.0.0.1"))
    parser.add_argument("--port", type=int, default=8555)
    parser.add_argument("--offline", action="store_true")
    args = parser.parse_args()

    ui_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "injected_ui.js")
    with open(ui_path, "r", encoding="utf-8") as f:
        ui_js = f.read()

    state = ProxyState(args.state_dir, online=not args.offline, ui_js=ui_js, port=args.port)
    server = ThreadingHTTPServer((args.host, args.port), make_handler(state))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        state.disc_manager.stop_monitor()
        state.disc_manager.stop()
        server.server_close()


if __name__ == "__main__":
    main()
