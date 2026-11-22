#!/usr/bin/env python3
"""Optical drive capability probing and mpv DVD/Blu-ray playback manager."""

import json
import os
import pwd
import shutil
import socket
import subprocess
import threading
import time
from typing import Callable, Optional


def parse_udev_props(raw_text: str) -> dict[str, str]:
    props: dict[str, str] = {}
    for line in raw_text.splitlines():
        line = line.strip()
        if not line or "=" not in line:
            continue
        k, v = line.split("=", 1)
        props[k.strip()] = v.strip()
    return props


def classify_drive_and_media(
    props: dict[str, str],
    sys_model: str = "",
    drive_exists: bool = True,
) -> dict:
    if not drive_exists:
        return {
            "drive_present": False,
            "model": "",
            "supports_dvd": False,
            "supports_bluray": False,
            "disc_present": False,
            "media_type": "none",
            "label": "",
        }

    is_dvd_drive = props.get("ID_CDROM_DVD") == "1"
    is_bd_drive = any(
        props.get(k) == "1" for k in ("ID_CDROM_BD", "ID_CDROM_BD_R", "ID_CDROM_BD_RE")
    )
    disc_present = props.get("ID_CDROM_MEDIA") == "1"

    media_type = "none"
    if disc_present:
        if any(
            props.get(k) == "1"
            for k in ("ID_CDROM_MEDIA_BD", "ID_CDROM_MEDIA_BD_R", "ID_CDROM_MEDIA_BD_RE")
        ):
            media_type = "bluray"
        elif any(
            props.get(k) == "1"
            for k in (
                "ID_CDROM_MEDIA_DVD",
                "ID_CDROM_MEDIA_DVD_R",
                "ID_CDROM_MEDIA_DVD_RW",
                "ID_CDROM_MEDIA_DVD_PLUS_R",
                "ID_CDROM_MEDIA_DVD_PLUS_RW",
                "ID_CDROM_MEDIA_DVD_PLUS_R_DL",
                "ID_CDROM_MEDIA_DVD_RAM",
            )
        ):
            media_type = "dvd"
        elif props.get("ID_CDROM_MEDIA_TRACK_COUNT_AUDIO"):
            media_type = "audio_cd"
        elif props.get("ID_FS_TYPE") in ("udf", "iso9660"):
            media_type = "dvd" if is_dvd_drive else "data"
        else:
            media_type = "data"

    model = (sys_model or props.get("ID_MODEL") or "Optical Drive").replace("_", " ").strip()
    label = (props.get("ID_FS_LABEL") or "").replace("\\x20", " ").strip()
    if disc_present and not label:
        label = "Blu-ray Disc" if media_type == "bluray" else "DVD / Optical Disc"

    return {
        "drive_present": True,
        "model": model,
        "supports_dvd": is_dvd_drive,
        "supports_bluray": is_bd_drive,
        "disc_present": disc_present,
        "media_type": media_type,
        "label": label,
    }


def map_mpv_error(stderr_text: str, disc_type: str) -> str:
    lower = stderr_text.lower()
    if "aacs" in lower or "keydb" in lower or "vuk" in lower:
        return (
            "Encrypted Blu-ray requires AACS keys: place KEYDB.cfg on the "
            "5S-USB-EFI partition (/boot/efi/KEYDB.cfg)."
        )
    if "bdplus" in lower or "bd+" in lower:
        return "This Blu-ray uses BD+ protection that could not be decoded."
    if "dvdnav" in lower or "dvdread" in lower or "css" in lower or "encrypted" in lower:
        return (
            "Failed to open DVD. Commercial encrypted DVDs require libdvdcss2 "
            "(build with ENABLE_LIBDVDCSS=1)."
        )
    if "no such file" in lower or "cannot open" in lower:
        return f"Could not read {disc_type.upper()} from optical drive."
    tail = [ln.strip() for ln in stderr_text.splitlines() if ln.strip()]
    if tail:
        return f"Playback error: {tail[-1][:180]}"
    return "Playback stopped unexpectedly."


class DiscManager:
    def __init__(
        self,
        state_dir: str = "/var/cache/5s",
        device: Optional[str] = None,
        mock_mode: Optional[bool] = None,
    ):
        self.state_dir = state_dir
        self.device = device or os.environ.get("OPTICAL_DEV", "/dev/sr0")
        self.mock_mode = (
            mock_mode if mock_mode is not None else (os.environ.get("MOCK_MODE", "0") == "1")
        )
        self.lock = threading.Lock()
        self.mpv_proc: Optional[subprocess.Popen] = None
        self.playing_type: Optional[str] = None
        self.last_error: Optional[str] = None
        self.ipc_sock = os.path.join(self.state_dir, "5s-mpv.sock")
        self._monitor_stop = threading.Event()
        self._monitor_thread: Optional[threading.Thread] = None
        self._on_change: Optional[Callable[[dict], None]] = None

    def _kiosk_user_info(self) -> tuple[Optional[int], Optional[int], str]:
        try:
            pw = pwd.getpwnam("kiosk")
            return pw.pw_uid, pw.pw_gid, pw.pw_dir
        except KeyError:
            return None, None, os.environ.get("HOME", "/root")

    def _aacs_keydb_paths(self) -> tuple[str, str]:
        _, _, kiosk_home = self._kiosk_user_info()
        efi_keydb = os.environ.get("EFI_KEYDB_PATH", "/boot/efi/KEYDB.cfg")
        dest_dir = os.path.join(kiosk_home, ".config", "aacs")
        return efi_keydb, os.path.join(dest_dir, "KEYDB.cfg")

    def sync_keydb(self) -> bool:
        efi_keydb, dest_keydb = self._aacs_keydb_paths()
        if os.path.isfile(efi_keydb):
            os.makedirs(os.path.dirname(dest_keydb), exist_ok=True)
            shutil.copy2(efi_keydb, dest_keydb)
            os.chmod(dest_keydb, 0o644)
            uid, gid, _ = self._kiosk_user_info()
            if os.geteuid() == 0 and uid is not None and gid is not None:
                os.chown(os.path.dirname(dest_keydb), uid, gid)
                os.chown(dest_keydb, uid, gid)
            return True
        return os.path.isfile(dest_keydb)

    def _read_sys_model(self) -> str:
        dev_name = os.path.basename(self.device)
        sys_path = f"/sys/block/{dev_name}/device/model"
        try:
            with open(sys_path, "r", encoding="utf-8") as f:
                return f.read().strip()
        except OSError:
            return ""

    def _mock_probe(self) -> dict:
        mock_drive = os.environ.get("MOCK_DISC_DRIVE", "none")
        mock_media = os.environ.get("MOCK_DISC_MEDIA", "none")
        mock_label = os.environ.get("MOCK_DISC_LABEL", "MOCK_DISC")

        mock_file = os.path.join(self.state_dir, "mock_disc.json")
        if os.path.isfile(mock_file):
            try:
                with open(mock_file, "r", encoding="utf-8") as f:
                    data = json.load(f)
                mock_drive = data.get("drive", mock_drive)
                mock_media = data.get("media", mock_media)
                mock_label = data.get("label", mock_label)
            except Exception:
                pass

        if mock_drive == "none":
            return classify_drive_and_media({}, drive_exists=False)

        props = {"ID_CDROM_DVD": "1"}
        if mock_drive == "bluray":
            props["ID_CDROM_BD"] = "1"
        if mock_media != "none":
            props["ID_CDROM_MEDIA"] = "1"
            props["ID_FS_LABEL"] = mock_label
            if mock_media == "dvd":
                props["ID_CDROM_MEDIA_DVD"] = "1"
            elif mock_media == "bluray":
                props["ID_CDROM_MEDIA_BD"] = "1"
            elif mock_media == "audio_cd":
                props["ID_CDROM_MEDIA_TRACK_COUNT_AUDIO"] = "12"

        model = "Mock BD-ROM Drive" if mock_drive == "bluray" else "Mock DVD-RW Drive"
        return classify_drive_and_media(props, sys_model=model, drive_exists=True)

    def _supplement_props_from_kernel(self, props: dict[str, str]) -> None:
        dev_name = os.path.basename(self.device)
        if "ID_CDROM_DVD" not in props:
            try:
                with open("/proc/sys/dev/cdrom/info", "r", encoding="utf-8") as f:
                    for line in f:
                        if line.startswith("Can read DVD:") and line.split(":", 1)[1].strip().startswith("1"):
                            props["ID_CDROM_DVD"] = "1"
            except OSError:
                pass

        if "ID_CDROM_MEDIA" not in props:
            try:
                with open(f"/sys/block/{dev_name}/size", "r", encoding="utf-8") as f:
                    sectors = int(f.read().strip() or "0")
                if sectors > 0:
                    props["ID_CDROM_MEDIA"] = "1"
                    if props.get("ID_CDROM_DVD") == "1" and "ID_CDROM_MEDIA_DVD" not in props:
                        props["ID_CDROM_MEDIA_DVD"] = "1"
            except (OSError, ValueError):
                pass

        if props.get("ID_CDROM_MEDIA") == "1" and not props.get("ID_FS_LABEL"):
            try:
                with open(self.device, "rb") as f:
                    f.seek(32768)
                    pvd = f.read(128)
                if len(pvd) >= 72 and pvd[1:6] == b"CD001":
                    lbl = pvd[40:72].decode("ascii", errors="ignore").strip()
                    if lbl:
                        props["ID_FS_LABEL"] = lbl
            except OSError:
                pass

    def probe(self) -> dict:
        if self.mock_mode:
            info = self._mock_probe()
        else:
            drive_exists = os.path.exists(self.device)
            if not drive_exists:
                info = classify_drive_and_media({}, drive_exists=False)
            else:
                raw = ""
                try:
                    res = subprocess.run(
                        ["udevadm", "info", "--query=property", f"--name={self.device}"],
                        capture_output=True,
                        text=True,
                        timeout=2.0,
                        check=False,
                    )
                    if res.returncode == 0:
                        raw = res.stdout
                except Exception:
                    raw = ""
                props = parse_udev_props(raw)
                self._supplement_props_from_kernel(props)
                info = classify_drive_and_media(
                    props, sys_model=self._read_sys_model(), drive_exists=True
                )

        _, dest_keydb = self._aacs_keydb_paths()
        with self.lock:
            playing = self.mpv_proc is not None and self.mpv_proc.poll() is None
            if not playing:
                self.playing_type = None
            info.update(
                {
                    "device": self.device,
                    "playing": playing,
                    "playing_type": self.playing_type if playing else None,
                    "last_error": self.last_error,
                    "aacs_keydb_present": os.path.isfile(dest_keydb),
                }
            )
        return info

    def _discover_wayland_env(self) -> dict[str, str]:
        env = os.environ.copy()
        uid, _, kiosk_home = self._kiosk_user_info()
        if os.geteuid() == 0 and uid is not None:
            runtime_dir = f"/run/user/{uid}"
            env["HOME"] = kiosk_home
        else:
            runtime_dir = env.get("XDG_RUNTIME_DIR") or f"/run/user/{os.geteuid()}"
        env["XDG_RUNTIME_DIR"] = runtime_dir

        if not env.get("WAYLAND_DISPLAY") and os.path.isdir(runtime_dir):
            for name in sorted(os.listdir(runtime_dir)):
                if name.startswith("wayland-") and not name.endswith(".lock"):
                    env["WAYLAND_DISPLAY"] = name
                    break
        return env

    def _notify_change(self) -> None:
        if self._on_change is not None:
            try:
                self._on_change(self.probe())
            except Exception:
                pass

    def play(self, disc_type: Optional[str] = None) -> tuple[bool, str]:
        info = self.probe()
        if not info["drive_present"]:
            return False, f"No optical drive detected ({self.device})"
        if not info["disc_present"]:
            return False, "No disc inserted in optical drive"

        target = disc_type or info["media_type"]
        if target not in ("dvd", "bluray"):
            return False, f"Unsupported disc format: {info['media_type']}"
        if target == "bluray" and not info["supports_bluray"]:
            return False, "Built-in optical drive is DVD-only and does not support Blu-ray"
        if target == "dvd" and not info["supports_dvd"]:
            return False, "Built-in optical drive does not support DVD playback"

        self.stop()

        if target == "bluray":
            self.sync_keydb()

        with self.lock:
            self.last_error = None

        if self.mock_mode:
            proc = subprocess.Popen(
                ["python3", "-c", "import time; time.sleep(30)"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                text=True,
            )
            with self.lock:
                self.mpv_proc = proc
                self.playing_type = target
            self._notify_change()
            return True, f"Playing {target.upper()} (mock)"

        if not shutil.which("mpv"):
            return False, "mpv player is not installed"

        env = self._discover_wayland_env()
        uid, gid, _ = self._kiosk_user_info()
        if os.geteuid() == 0 and uid is not None:
            self.ipc_sock = f"/run/user/{uid}/5s-mpv.sock"
        else:
            self.ipc_sock = os.path.join(self.state_dir, "5s-mpv.sock")

        try:
            os.unlink(self.ipc_sock)
        except OSError:
            pass

        vo_override = os.environ.get("MPV_VO_OVERRIDE", "")
        if vo_override == "drm" or not env.get("WAYLAND_DISPLAY"):
            vo_flags = ["--vo=drm", "--hwdec=no"]
        else:
            vo_flags = ["--vo=gpu", "--hwdec=vaapi", "--gpu-context=wayland"]

        mpv_cmd = [
            "mpv",
            "--fs",
            *vo_flags,
            f"--input-ipc-server={self.ipc_sock}",
            "--keep-open=no",
        ]
        if target == "bluray":
            mpv_cmd.extend([f"--bluray-device={self.device}", "bd://"])
        else:
            mpv_cmd.extend([f"--dvd-device={self.device}", "dvdnav://"])

        if os.geteuid() == 0 and uid is not None and gid is not None and shutil.which("setpriv"):
            cmd = [
                "setpriv",
                f"--reuid={uid}",
                f"--regid={gid}",
                "--init-groups",
                *mpv_cmd,
            ]
        else:
            cmd = mpv_cmd

        proc = subprocess.Popen(
            cmd,
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
        )

        with self.lock:
            self.mpv_proc = proc
            self.playing_type = target

        def _wait_mpv():
            _, stderr_data = proc.communicate()
            rc = proc.returncode
            with self.lock:
                if self.mpv_proc is proc:
                    self.mpv_proc = None
                    self.playing_type = None
                    if rc not in (0, -15, -9, None):
                        self.last_error = map_mpv_error(stderr_data or "", target)
            self._notify_change()

        threading.Thread(target=_wait_mpv, daemon=True).start()
        self._notify_change()
        return True, f"Started {target.upper()} playback"

    def stop(self) -> tuple[bool, str]:
        with self.lock:
            proc = self.mpv_proc
            sock_path = self.ipc_sock

        if proc is None or proc.poll() is not None:
            with self.lock:
                self.mpv_proc = None
                self.playing_type = None
            return True, "Not playing"

        if sock_path and os.path.exists(sock_path):
            try:
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
                    s.settimeout(0.5)
                    s.connect(sock_path)
                    s.sendall(b'{"command":["quit"]}\n')
            except OSError:
                pass

        try:
            proc.wait(timeout=1.5)
        except subprocess.TimeoutExpired:
            proc.terminate()
            try:
                proc.wait(timeout=1.0)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=1.0)

        with self.lock:
            if self.mpv_proc is proc:
                self.mpv_proc = None
                self.playing_type = None
        self._notify_change()
        return True, "Playback stopped"

    def eject(self) -> tuple[bool, str]:
        self.stop()
        if self.mock_mode:
            mock_file = os.path.join(self.state_dir, "mock_disc.json")
            if os.path.isfile(mock_file):
                try:
                    with open(mock_file, "r", encoding="utf-8") as f:
                        data = json.load(f)
                    data["media"] = "none"
                    with open(mock_file, "w", encoding="utf-8") as f:
                        json.dump(data, f)
                except Exception:
                    pass
            self._notify_change()
            return True, "Ejected (mock)"

        if not os.path.exists(self.device):
            return False, f"No optical drive detected ({self.device})"
        if not shutil.which("eject"):
            return False, "eject utility is not installed"
        res = subprocess.run(["eject", self.device], capture_output=True, text=True, check=False)
        if res.returncode != 0:
            return False, (res.stderr or "Failed to eject disc").strip()
        self._notify_change()
        return True, "Disc ejected"

    def start_monitor(self, on_change: Callable[[dict], None]) -> None:
        self._on_change = on_change
        if self.mock_mode or not shutil.which("udevadm"):
            return
        if self._monitor_thread is not None and self._monitor_thread.is_alive():
            return

        dev_name = os.path.basename(self.device)

        def _worker():
            while not self._monitor_stop.is_set():
                try:
                    proc = subprocess.Popen(
                        ["udevadm", "monitor", "--udev", "--subsystem-match=block"],
                        stdout=subprocess.PIPE,
                        stderr=subprocess.DEVNULL,
                        text=True,
                    )
                    if proc.stdout is None:
                        break
                    for line in proc.stdout:
                        if self._monitor_stop.is_set():
                            break
                        if dev_name in line:
                            time.sleep(0.25)
                            self._notify_change()
                    proc.terminate()
                    proc.wait(timeout=1.0)
                except Exception:
                    time.sleep(1.0)

        self._monitor_thread = threading.Thread(target=_worker, daemon=True)
        self._monitor_thread.start()

    def stop_monitor(self) -> None:
        self._monitor_stop.set()
