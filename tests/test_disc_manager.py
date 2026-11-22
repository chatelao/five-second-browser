#!/usr/bin/env python3
import json
import os
import shutil
import sys
import tempfile

ROOT_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.join(ROOT_DIR, "src", "disc"))

from disc_manager import DiscManager, classify_drive_and_media, map_mpv_error, parse_udev_props  # noqa: E402


def test_udev_parsing_and_capabilities() -> None:
    raw_dvd_only = """
    ID_CDROM=1
    ID_CDROM_DVD=1
    ID_CDROM_MEDIA=1
    ID_CDROM_MEDIA_DVD=1
    ID_FS_LABEL=MOVIE_NIGHT
    ID_MODEL=hp_DVDRW_GUD1N
    """
    props = parse_udev_props(raw_dvd_only)
    info = classify_drive_and_media(props, sys_model="DVDRW GUD1N", drive_exists=True)
    assert info["drive_present"] is True
    assert info["supports_dvd"] is True
    assert info["supports_bluray"] is False
    assert info["disc_present"] is True
    assert info["media_type"] == "dvd"
    assert info["label"] == "MOVIE_NIGHT"

    raw_bd_drive = """
    ID_CDROM=1
    ID_CDROM_DVD=1
    ID_CDROM_BD=1
    ID_CDROM_MEDIA=1
    ID_CDROM_MEDIA_BD=1
    ID_FS_LABEL=PLANET_EARTH_BD
    """
    bd_info = classify_drive_and_media(parse_udev_props(raw_bd_drive), sys_model="BD-RE BU40N", drive_exists=True)
    assert bd_info["supports_dvd"] is True
    assert bd_info["supports_bluray"] is True
    assert bd_info["media_type"] == "bluray"
    assert bd_info["label"] == "PLANET_EARTH_BD"

    no_drive = classify_drive_and_media({}, drive_exists=False)
    assert no_drive["drive_present"] is False
    assert no_drive["supports_dvd"] is False
    assert no_drive["supports_bluray"] is False
    assert no_drive["media_type"] == "none"


def test_error_mapping() -> None:
    assert "KEYDB.cfg" in map_mpv_error("libaacs: Error decrypting AACS", "bluray")
    assert "libdvdcss2" in map_mpv_error("dvdread: Encrypted DVD CSS failed", "dvd")


def test_mock_lifecycle_and_keydb() -> None:
    tmp_dir = tempfile.mkdtemp()
    old_home = os.environ.get("HOME")
    old_efi = os.environ.get("EFI_KEYDB_PATH")
    try:
        os.environ["HOME"] = tmp_dir
        efi_keydb = os.path.join(tmp_dir, "KEYDB.cfg")
        with open(efi_keydb, "w", encoding="utf-8") as f:
            f.write("; mock aacs keys\n")
        os.environ["EFI_KEYDB_PATH"] = efi_keydb

        mock_file = os.path.join(tmp_dir, "mock_disc.json")
        # 1. DVD-only drive with Blu-ray disc inserted -> Blu-ray play rejected
        with open(mock_file, "w", encoding="utf-8") as f:
            json.dump({"drive": "dvd", "media": "bluray", "label": "TEST_BD"}, f)

        mgr = DiscManager(state_dir=tmp_dir, mock_mode=True)
        st = mgr.probe()
        assert st["drive_present"] is True
        assert st["supports_dvd"] is True
        assert st["supports_bluray"] is False
        assert st["media_type"] == "bluray"

        ok, msg = mgr.play("bluray")
        assert ok is False and "DVD-only" in msg

        # 2. Blu-ray capable drive with Blu-ray disc -> play, stop, KEYDB sync, eject
        with open(mock_file, "w", encoding="utf-8") as f:
            json.dump({"drive": "bluray", "media": "bluray", "label": "TEST_BD"}, f)

        st2 = mgr.probe()
        assert st2["supports_bluray"] is True

        ok, msg = mgr.play()
        assert ok is True, msg
        assert mgr.probe()["playing"] is True
        assert mgr.probe()["playing_type"] == "bluray"
        assert os.path.isfile(os.path.join(tmp_dir, ".config", "aacs", "KEYDB.cfg"))

        ok, _ = mgr.stop()
        assert ok is True
        assert mgr.probe()["playing"] is False

        ok, _ = mgr.eject()
        assert ok is True
        assert mgr.probe()["disc_present"] is False
    finally:
        if old_home is not None:
            os.environ["HOME"] = old_home
        if old_efi is not None:
            os.environ["EFI_KEYDB_PATH"] = old_efi
        else:
            os.environ.pop("EFI_KEYDB_PATH", None)
        shutil.rmtree(tmp_dir, ignore_errors=True)


def main() -> None:
    test_udev_parsing_and_capabilities()
    test_error_mapping()
    test_mock_lifecycle_and_keydb()
    print("test_disc_manager: udev parsing, DVD/BD capability gating, KEYDB sync, and mock playback verified")


if __name__ == "__main__":
    main()
