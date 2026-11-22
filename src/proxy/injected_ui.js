(function () {
  "use strict";

  // 1. Broadwell Gen8 VA-API Media Filter (H.264/VP8 <= 1080p hardware decode; block VP9/AV1)
  const BLOCKED_CODECS = /vp0?9|av01/i;
  const HIGH_RES = /height=(?:1[1-9]\d{2}|[2-9]\d{3,})/i;

  if (typeof MediaSource !== "undefined" && typeof MediaSource.isTypeSupported === "function") {
    const origIsSupported = MediaSource.isTypeSupported.bind(MediaSource);
    MediaSource.isTypeSupported = function (mime) {
      if (typeof mime === "string" && (BLOCKED_CODECS.test(mime) || HIGH_RES.test(mime))) {
        return false;
      }
      return origIsSupported(mime);
    };
  }

  if (typeof HTMLMediaElement !== "undefined" && HTMLMediaElement.prototype.canPlayType) {
    const origCanPlay = HTMLMediaElement.prototype.canPlayType;
    HTMLMediaElement.prototype.canPlayType = function (mime) {
      if (typeof mime === "string" && BLOCKED_CODECS.test(mime)) {
        return "";
      }
      return origCanPlay.call(this, mime);
    };
  }

  // 2. Offline Banner Suppression during initial 0-5s boot window
  try {
    Object.defineProperty(navigator, "onLine", {
      get: function () { return true; },
      configurable: true
    });
  } catch (_) {}

  // 3. 24px Triple-Tab Appliance Bar + Hotkeys (F1/Alt+1 = Gmail, F2/Alt+2 = YouTube, F3/Alt+3 = Disc)
  function switchTab(tabName) {
    const tabs = ["gmail", "youtube", "disc"];
    for (let i = 0; i < tabs.length; i++) {
      const name = tabs[i];
      const btn = document.getElementById("tab-btn-" + name);
      const pane = document.getElementById("pane-" + name);
      const active = name === tabName;
      if (btn) btn.classList.toggle("active", active);
      if (pane) {
        pane.style.visibility = active ? "visible" : "hidden";
        pane.style.pointerEvents = active ? "auto" : "none";
      }
    }
    if (tabName === "disc") {
      refreshDiscStatus();
    }
  }

  function setStatus(text, color) {
    const pill = document.getElementById("status-pill");
    if (!pill) return;
    pill.textContent = text;
    pill.style.color = color;
  }

  function renderDiscState(data) {
    const titleEl = document.getElementById("disc-title");
    const capsEl = document.getElementById("disc-caps");
    const msgEl = document.getElementById("disc-msg");
    const playBtn = document.getElementById("btn-disc-play");
    const stopBtn = document.getElementById("btn-disc-stop");
    const ejectBtn = document.getElementById("btn-disc-eject");
    const tabBtn = document.getElementById("tab-btn-disc");
    if (!titleEl || !capsEl) return;

    if (!data || !data.drive_present) {
      titleEl.textContent = "No Optical Drive Detected";
      capsEl.textContent = "Waiting for built-in optical drive (/dev/sr0)...";
      if (playBtn) playBtn.disabled = true;
      if (stopBtn) stopBtn.disabled = true;
      if (ejectBtn) ejectBtn.disabled = true;
      if (tabBtn) tabBtn.textContent = "\uD83D\uDCBF Disc (F3)";
      return;
    }

    const dvdCap = data.supports_dvd ? "DVD: Supported" : "DVD: Unsupported";
    const bdCap = data.supports_bluray ? "Blu-ray: Supported" : "Blu-ray: Not supported (DVD-only drive)";
    const keyInfo = data.supports_bluray
      ? (data.aacs_keydb_present ? " | AACS KEYDB.cfg: Ready" : " | AACS KEYDB.cfg: Not found")
      : "";

    if (data.disc_present) {
      const fmt = (data.media_type || "disc").toUpperCase();
      titleEl.textContent = (data.label || "Optical Disc") + " (" + fmt + ")";
      if (tabBtn) tabBtn.textContent = "\uD83D\uDCBF Disc \u25CF (F3)";
    } else {
      titleEl.textContent = (data.model || "Optical Drive") + " \u2014 No Disc";
      if (tabBtn) tabBtn.textContent = "\uD83D\uDCBF Disc (F3)";
    }

    capsEl.textContent = (data.model || "Built-in Drive") + " \u2014 " + dvdCap + " | " + bdCap + keyInfo;

    const playableType = data.media_type === "dvd" || data.media_type === "bluray";
    const typeSupported =
      (data.media_type === "dvd" && data.supports_dvd) ||
      (data.media_type === "bluray" && data.supports_bluray);

    if (playBtn) playBtn.disabled = !(data.disc_present && playableType && typeSupported && !data.playing);
    if (stopBtn) stopBtn.disabled = !data.playing;
    if (ejectBtn) ejectBtn.disabled = !data.drive_present;

    if (msgEl) {
      if (data.playing) {
        msgEl.textContent = "Playing " + (data.playing_type || "").toUpperCase() + " fullscreen (press Esc or q to return)...";
      } else if (data.last_error) {
        msgEl.textContent = data.last_error;
      } else if (data.disc_present && data.media_type === "bluray" && !data.supports_bluray) {
        msgEl.textContent = "Blu-ray disc detected, but the built-in drive is DVD-only.";
      } else {
        msgEl.textContent = "";
      }
    }
  }

  function refreshDiscStatus() {
    fetch("/__5s__/disc/status")
      .then(function (r) { return r.json(); })
      .then(renderDiscState)
      .catch(function () {});
  }

  function postDiscAction(endpoint) {
    const msgEl = document.getElementById("disc-msg");
    if (msgEl) msgEl.textContent = "Working...";
    fetch(endpoint, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: "{}"
    })
      .then(function (r) { return r.json(); })
      .then(function (res) {
        if (res.status) renderDiscState(res.status);
        if (!res.ok && res.message && msgEl) {
          msgEl.textContent = res.message;
        }
      })
      .catch(function (err) {
        if (msgEl) msgEl.textContent = "Request failed: " + err;
      });
  }

  function initUI() {
    const gmailBtn = document.getElementById("tab-btn-gmail");
    const ytBtn = document.getElementById("tab-btn-youtube");
    const discBtn = document.getElementById("tab-btn-disc");
    if (gmailBtn) gmailBtn.addEventListener("click", function () { switchTab("gmail"); });
    if (ytBtn) ytBtn.addEventListener("click", function () { switchTab("youtube"); });
    if (discBtn) discBtn.addEventListener("click", function () { switchTab("disc"); });

    const playBtn = document.getElementById("btn-disc-play");
    const stopBtn = document.getElementById("btn-disc-stop");
    const ejectBtn = document.getElementById("btn-disc-eject");
    if (playBtn) playBtn.addEventListener("click", function () { postDiscAction("/__5s__/disc/play"); });
    if (stopBtn) stopBtn.addEventListener("click", function () { postDiscAction("/__5s__/disc/stop"); });
    if (ejectBtn) ejectBtn.addEventListener("click", function () { postDiscAction("/__5s__/disc/eject"); });

    window.addEventListener("keydown", function (e) {
      if (e.key === "F1" || (e.altKey && e.key === "1")) {
        e.preventDefault();
        switchTab("gmail");
      } else if (e.key === "F2" || (e.altKey && e.key === "2")) {
        e.preventDefault();
        switchTab("youtube");
      } else if (e.key === "F3" || (e.altKey && e.key === "3")) {
        e.preventDefault();
        switchTab("disc");
      }
    });

    if (typeof URLSearchParams !== "undefined") {
      const params = new URLSearchParams(window.location.search);
      if (params.get("tab") === "disc") {
        switchTab("disc");
      }
    }
    refreshDiscStatus();

    // 4. Live SSE Delta & Disc Listener
    if (typeof EventSource !== "undefined") {
      const es = new EventSource("/__5s__/events");
      es.addEventListener("delta", function (ev) {
        setStatus("● Live", "#4ade80");
        try {
          const data = JSON.parse(ev.data);
          if (data.gmail_html) {
            const g = document.getElementById("gmail-feed");
            if (g) g.innerHTML = data.gmail_html;
          }
          if (data.youtube_html) {
            const y = document.getElementById("youtube-feed");
            if (y) y.innerHTML = data.youtube_html;
          }
        } catch (_) {}
      });
      es.addEventListener("disc", function (ev) {
        try {
          renderDiscState(JSON.parse(ev.data));
        } catch (_) {}
      });
    }

    // 5. Shutdown Flush Hook
    window.addEventListener("5s-prepare-shutdown", function () {
      const g = document.getElementById("gmail-feed");
      const y = document.getElementById("youtube-feed");
      fetch("/__5s__/snapshot", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          gmail_html: g ? g.innerHTML : "",
          youtube_html: y ? y.innerHTML : ""
        })
      }).catch(function () {});
    });
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", initUI);
  } else {
    initUI();
  }
})();
