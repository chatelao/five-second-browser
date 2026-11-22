(function () {
  "use strict";

  const BAR_HEIGHT = 34;
  const isLocalShell = window.location.hostname === "127.0.0.1";

  function sendSwitch(tab) {
    try {
      chrome.runtime.sendMessage({ type: "switch_tab", tab: tab });
    } catch (_) {}
  }

  window.addEventListener("keydown", function (e) {
    if (e.key === "F1" || (e.altKey && e.key === "1")) {
      e.preventDefault();
      sendSwitch("gmail");
    } else if (e.key === "F2" || (e.altKey && e.key === "2")) {
      e.preventDefault();
      sendSwitch("youtube");
    } else if (e.key === "F3" || (e.altKey && e.key === "3")) {
      e.preventDefault();
      sendSwitch("disc");
    } else if (e.key === "F12" || (e.altKey && (e.key === "d" || e.key === "D"))) {
      e.preventDefault();
      sendSwitch("diag");
    }
  }, true);

  if (isLocalShell) {
    function bindLocalTabs() {
      const g = document.getElementById("tab-btn-gmail");
      const y = document.getElementById("tab-btn-youtube");
      const d = document.getElementById("tab-btn-disc");
      if (g) g.addEventListener("click", function () { sendSwitch("gmail"); });
      if (y) y.addEventListener("click", function () { sendSwitch("youtube"); });
      if (d) d.addEventListener("click", function () { sendSwitch("disc"); });
    }
    if (document.readyState === "loading") {
      document.addEventListener("DOMContentLoaded", bindLocalTabs, { once: true });
    } else {
      bindLocalTabs();
    }
    return;
  }

  const host = window.location.hostname;
  const isYouTube = host.indexOf("youtube.com") !== -1;
  const isGmail = host.indexOf("mail.google.com") !== -1;

  // Inject per-site layout offset immediately at document_start so fixed headers never clip.
  function injectOffsetStyle() {
    if (document.getElementById("fs-5s-offset-style")) return;
    const style = document.createElement("style");
    style.id = "fs-5s-offset-style";

    let siteCss = "";
    if (isYouTube) {
      siteCss = [
        "ytd-masthead, #masthead-container.ytd-app, ytd-masthead#masthead { top: var(--fs-5s-bar-h) !important; }",
        "#frosted-glass, #frosted-glass.with-chipbar { top: var(--fs-5s-bar-h) !important; }",
        "tp-yt-app-drawer#guide, ytd-mini-guide-renderer { top: var(--fs-5s-bar-h) !important; height: calc(100vh - var(--fs-5s-bar-h)) !important; }",
        "ytd-app { margin-top: var(--fs-5s-bar-h) !important; }"
      ].join("\n");
    } else if (isGmail) {
      siteCss = [
        "html { height: calc(100% - var(--fs-5s-bar-h)) !important; margin-top: var(--fs-5s-bar-h) !important; box-sizing: border-box !important; }",
        "body { height: 100% !important; }"
      ].join("\n");
    } else {
      siteCss = "html { padding-top: var(--fs-5s-bar-h) !important; box-sizing: border-box !important; }";
    }

    style.textContent = [
      ":root { --fs-5s-bar-h: " + BAR_HEIGHT + "px; }",
      "html.fs-5s-fullscreen, html:has(:fullscreen) { --fs-5s-bar-h: 0px !important; }",
      "html.fs-5s-fullscreen #fs-5s-topbar, html:has(:fullscreen) #fs-5s-topbar { display: none !important; }",
      siteCss
    ].join("\n");

    const target = document.head || document.documentElement;
    if (target) {
      target.appendChild(style);
    }
  }

  injectOffsetStyle();

  function syncFullscreenState() {
    const fs = !!(document.fullscreenElement || document.webkitFullscreenElement);
    if (document.documentElement) {
      document.documentElement.classList.toggle("fs-5s-fullscreen", fs);
    }
  }

  document.addEventListener("fullscreenchange", syncFullscreenState);
  document.addEventListener("webkitfullscreenchange", syncFullscreenState);

  const ICONS = {
    gmail: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="1.75" y="3" width="12.5" height="10" rx="1.5"/><path d="M2 4l6 4.5L14 4"/></svg>',
    youtube: '<svg viewBox="0 0 16 16" fill="currentColor"><path d="M5.5 3.8v8.4L12.5 8l-7-4.2z"/></svg>',
    disc: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5"><circle cx="8" cy="8" r="6"/><circle cx="8" cy="8" r="1.8"/></svg>',
    wifi: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"><path d="M2.2 6.2a8.5 8.5 0 0 1 11.6 0"/><path d="M4.6 8.9a5.2 5.2 0 0 1 6.8 0"/><circle cx="8" cy="12" r="1" fill="currentColor" stroke="none"/></svg>'
  };

  function mountBar() {
    if (document.getElementById("fs-5s-topbar") || !document.documentElement) return;
    injectOffsetStyle();

    const hostEl = document.createElement("div");
    hostEl.id = "fs-5s-topbar";
    hostEl.style.cssText = [
      "all:initial",
      "position:fixed",
      "top:0",
      "left:0",
      "right:0",
      "height:" + BAR_HEIGHT + "px",
      "z-index:2147483647",
      "display:block",
      "pointer-events:auto"
    ].join(";");

    const shadow = hostEl.attachShadow({ mode: "open" });
    const activeTab = isYouTube ? "youtube" : "gmail";

    const style = document.createElement("style");
    style.textContent = [
      ":host { all: initial; display: block; }",
      ".bar { height: " + BAR_HEIGHT + "px; background: #0f172a; border-bottom: 1px solid rgba(255, 255, 255, 0.08); color: #e2e8f0; display: flex; align-items: center; justify-content: space-between; padding: 0 10px; box-sizing: border-box; font-family: system-ui, -apple-system, 'Segoe UI', Roboto, sans-serif; font-size: 12px; user-select: none; }",
      ".tabs { display: flex; align-items: center; gap: 6px; }",
      ".tab-btn { display: inline-flex; align-items: center; gap: 6px; height: 24px; padding: 0 10px; border: 1px solid transparent; border-radius: 6px; background: rgba(255, 255, 255, 0.06); color: #cbd5e1; font-family: inherit; font-size: 12px; font-weight: 500; cursor: pointer; transition: background 0.15s ease, color 0.15s ease, border-color 0.15s ease; outline: none; }",
      ".tab-btn:hover { background: rgba(255, 255, 255, 0.12); color: #f8fafc; }",
      ".tab-btn.active { background: #2563eb; border-color: rgba(255, 255, 255, 0.15); color: #ffffff; font-weight: 600; box-shadow: 0 1px 2px rgba(0, 0, 0, 0.25); }",
      ".tab-btn svg, .wifi svg { width: 14px; height: 14px; flex-shrink: 0; display: block; }",
      "kbd { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 10px; line-height: 1; padding: 2px 5px; border-radius: 4px; background: rgba(0, 0, 0, 0.25); border: 1px solid rgba(255, 255, 255, 0.12); color: inherit; opacity: 0.85; }",
      ".right { display: flex; align-items: center; gap: 10px; }",
      ".wifi { display: inline-flex; align-items: center; gap: 5px; color: #94a3b8; font-size: 11px; white-space: nowrap; }",
      ".clock { color: #e2e8f0; font-size: 11px; font-variant-numeric: tabular-nums; white-space: nowrap; }",
      ".diag-btn { display: inline-flex; align-items: center; gap: 4px; height: 22px; padding: 0 8px; border-radius: 5px; border: 1px solid rgba(255, 255, 255, 0.1); background: transparent; color: #94a3b8; font-family: inherit; font-size: 11px; cursor: pointer; transition: background 0.15s ease, color 0.15s ease; }",
      ".diag-btn:hover { background: rgba(255, 255, 255, 0.08); color: #e2e8f0; }",
      ".pill { display: inline-flex; align-items: center; gap: 5px; font-size: 11px; font-weight: 500; color: #4ade80; padding: 2px 8px; border-radius: 999px; background: rgba(74, 222, 128, 0.1); border: 1px solid rgba(74, 222, 128, 0.2); white-space: nowrap; }",
      ".pill.offline { color: #f87171; background: rgba(248, 113, 113, 0.1); border-color: rgba(248, 113, 113, 0.2); }",
      ".dot { width: 6px; height: 6px; border-radius: 50%; background: currentColor; }"
    ].join("\n");

    const bar = document.createElement("div");
    bar.className = "bar";

    function mkBtn(id, iconSvg, label, keyHint, tab) {
      const b = document.createElement("button");
      b.id = id;
      b.type = "button";
      b.className = tab === activeTab ? "tab-btn active" : "tab-btn";
      b.innerHTML = iconSvg + "<span>" + label + "</span><kbd>" + keyHint + "</kbd>";
      b.addEventListener("click", function () { sendSwitch(tab); });
      return b;
    }

    const left = document.createElement("div");
    left.className = "tabs";
    const btnGmail = mkBtn("fs-5s-gmail", ICONS.gmail, "Gmail", "F1", "gmail");
    const btnYt = mkBtn("fs-5s-yt", ICONS.youtube, "YouTube", "F2", "youtube");
    const btnDisc = mkBtn("fs-5s-disc", ICONS.disc, "Disc", "F3", "disc");
    left.appendChild(btnGmail);
    left.appendChild(btnYt);
    left.appendChild(btnDisc);

    try {
      chrome.runtime.sendMessage({ type: "get_features" }, function (resp) {
        if (resp && resp.features) {
          if (resp.features.gmail === false) btnGmail.style.display = "none";
          if (resp.features.youtube === false) btnYt.style.display = "none";
          if (resp.features.disc === false) btnDisc.style.display = "none";
        }
      });
    } catch (_) {}

    const right = document.createElement("div");
    right.id = "fs-5s-right";
    right.className = "right";

    const wifiEl = document.createElement("div");
    wifiEl.id = "fs-5s-wifi";
    wifiEl.className = "wifi";
    wifiEl.innerHTML = ICONS.wifi + '<span id="fs-5s-wifi-text">Wi-Fi</span>';
    const wifiTextEl = wifiEl.querySelector("#fs-5s-wifi-text");

    const clockEl = document.createElement("div");
    clockEl.id = "fs-5s-clock";
    clockEl.className = "clock";
    clockEl.textContent = "--:--";
    clockEl.title = "Local Time";

    const diagBtn = document.createElement("button");
    diagBtn.type = "button";
    diagBtn.className = "diag-btn";
    diagBtn.innerHTML = "<span>Diag</span><kbd>F12</kbd>";
    diagBtn.addEventListener("click", function () { sendSwitch("diag"); });

    const pill = document.createElement("div");
    pill.id = "fs-5s-pill";
    pill.className = "pill";
    pill.innerHTML = '<span class="dot"></span><span id="fs-5s-pill-text">Live</span>';
    const pillTextEl = pill.querySelector("#fs-5s-pill-text");

    right.appendChild(wifiEl);
    right.appendChild(clockEl);
    right.appendChild(diagBtn);
    right.appendChild(pill);

    bar.appendChild(left);
    bar.appendChild(right);
    shadow.appendChild(style);
    shadow.appendChild(bar);
    document.documentElement.appendChild(hostEl);
    syncFullscreenState();

    function updateClock() {
      try {
        clockEl.textContent = new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
      } catch (_) {
        const d = new Date();
        clockEl.textContent = String(d.getHours()).padStart(2, "0") + ":" + String(d.getMinutes()).padStart(2, "0");
      }
    }

    function applyStatus(st) {
      if (!st) return;
      if (st.ssid && st.signal_percent !== null && st.signal_percent !== undefined) {
        wifiTextEl.textContent = st.ssid + " (" + st.signal_percent + "%)";
        wifiEl.title = st.signal_dbm !== null && st.signal_dbm !== undefined
          ? (st.ssid + " (" + st.signal_percent + "%, " + st.signal_dbm + " dBm)")
          : (st.ssid + " (" + st.signal_percent + "%)");
      } else if (st.ssid) {
        wifiTextEl.textContent = st.ssid;
        wifiEl.title = st.ssid;
      } else {
        wifiTextEl.textContent = "No Wi-Fi";
        wifiEl.title = "Wi-Fi Network & Signal";
      }
      if (st.online) {
        pill.classList.remove("offline");
        pillTextEl.textContent = "Live";
      } else {
        pill.classList.add("offline");
        pillTextEl.textContent = st.net_error ? st.net_error : "Offline";
      }
    }

    function refreshStatus() {
      try {
        chrome.runtime.sendMessage({ type: "get_status" }, function (resp) {
          if (resp && resp.status) {
            applyStatus(resp.status);
          }
        });
      } catch (_) {}
    }

    updateClock();
    setInterval(updateClock, 1000);
    refreshStatus();
    setInterval(refreshStatus, 3000);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", mountBar, { once: true });
  } else {
    mountBar();
  }
})();
