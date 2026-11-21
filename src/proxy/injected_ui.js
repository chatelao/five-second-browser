(function () {
  "use strict";

  // 1. Atom N550 Media Survival (h264ify <= 480p30)
  const BLOCKED_CODECS = /vp0?9|vp0?8|av01/i;
  const HIGH_RES = /height=(?:[5-9]\d{2}|[1-9]\d{3,})/i;

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

  // 3. 24px Dual-Tab Appliance Bar + Hotkeys (F1/Alt+1 = Gmail, F2/Alt+2 = YouTube)
  function switchTab(tabName) {
    const gmailBtn = document.getElementById("tab-btn-gmail");
    const ytBtn = document.getElementById("tab-btn-youtube");
    const gmailPane = document.getElementById("pane-gmail");
    const ytPane = document.getElementById("pane-youtube");
    if (!gmailBtn || !ytBtn || !gmailPane || !ytPane) return;

    const isGmail = tabName === "gmail";
    gmailBtn.classList.toggle("active", isGmail);
    ytBtn.classList.toggle("active", !isGmail);
    gmailPane.style.visibility = isGmail ? "visible" : "hidden";
    gmailPane.style.pointerEvents = isGmail ? "auto" : "none";
    ytPane.style.visibility = isGmail ? "hidden" : "visible";
    ytPane.style.pointerEvents = isGmail ? "none" : "auto";
  }

  function setStatus(text, color) {
    const pill = document.getElementById("status-pill");
    if (!pill) return;
    pill.textContent = text;
    pill.style.color = color;
  }

  function initUI() {
    const gmailBtn = document.getElementById("tab-btn-gmail");
    const ytBtn = document.getElementById("tab-btn-youtube");
    if (gmailBtn) gmailBtn.addEventListener("click", function () { switchTab("gmail"); });
    if (ytBtn) ytBtn.addEventListener("click", function () { switchTab("youtube"); });

    window.addEventListener("keydown", function (e) {
      if (e.key === "F1" || (e.altKey && e.key === "1")) {
        e.preventDefault();
        switchTab("gmail");
      } else if (e.key === "F2" || (e.altKey && e.key === "2")) {
        e.preventDefault();
        switchTab("youtube");
      }
    });

    // 4. Live SSE Delta Listener
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
