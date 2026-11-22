(function () {
  "use strict";

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
    const g = document.getElementById("tab-btn-gmail");
    const y = document.getElementById("tab-btn-youtube");
    const d = document.getElementById("tab-btn-disc");
    if (g) g.addEventListener("click", function () { sendSwitch("gmail"); });
    if (y) y.addEventListener("click", function () { sendSwitch("youtube"); });
    if (d) d.addEventListener("click", function () { sendSwitch("disc"); });
    return;
  }

  if (document.getElementById("fs-5s-topbar")) return;

  const bar = document.createElement("div");
  bar.id = "fs-5s-topbar";
  bar.style.cssText = [
    "position:fixed", "top:0", "left:0", "right:0", "height:24px",
    "background:#1e293b", "color:#eee", "display:flex", "align-items:center",
    "justify-content:space-between", "padding:0 8px", "font:12px/1 sans-serif",
    "z-index:2147483647", "box-sizing:border-box", "border-bottom:1px solid #334155"
  ].join(";");

  const host = window.location.hostname;
  const activeTab = host.indexOf("youtube.com") !== -1 ? "youtube" : "gmail";

  function mkBtn(id, label, tab) {
    const b = document.createElement("button");
    b.id = id;
    b.textContent = label;
    const isActive = tab === activeTab;
    b.style.cssText = [
      "border:none", "height:20px", "padding:0 10px", "cursor:pointer",
      "font-size:12px", "margin-right:6px",
      isActive ? "background:#3b82f6;color:#fff;font-weight:bold;" : "background:#334155;color:#e2e8f0;"
    ].join(";");
    b.addEventListener("click", function () { sendSwitch(tab); });
    return b;
  }

  const left = document.createElement("div");
  left.style.cssText = "display:flex;align-items:center;";
  const btnGmail = mkBtn("fs-5s-gmail", "\u2709 Gmail (F1)", "gmail");
  const btnYt = mkBtn("fs-5s-yt", "\u25B6 YouTube (F2)", "youtube");
  const btnDisc = mkBtn("fs-5s-disc", "\uD83D\uDCBF Disc (F3)", "disc");
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
  right.style.cssText = "display:flex;align-items:center;gap:12px;font-size:12px;";

  const wifiEl = document.createElement("div");
  wifiEl.id = "fs-5s-wifi";
  wifiEl.textContent = "\uD83D\uDCF6 Wi-Fi";
  wifiEl.style.cssText = "color:#94a3b8;white-space:nowrap;";

  const clockEl = document.createElement("div");
  clockEl.id = "fs-5s-clock";
  clockEl.textContent = "--:--";
  clockEl.title = "Local Time";
  clockEl.style.cssText = "color:#e2e8f0;font-variant-numeric:tabular-nums;white-space:nowrap;";

  const pill = document.createElement("div");
  pill.id = "fs-5s-pill";
  pill.textContent = "\u25CF Live";
  pill.style.cssText = "color:#4ade80;font-size:12px;white-space:nowrap;";

  right.appendChild(wifiEl);
  right.appendChild(clockEl);
  right.appendChild(pill);

  bar.appendChild(left);
  bar.appendChild(right);

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
      wifiEl.textContent = "\uD83D\uDCF6 " + st.ssid + " (" + st.signal_percent + "%)";
      wifiEl.title = st.signal_dbm !== null && st.signal_dbm !== undefined
        ? (st.ssid + " (" + st.signal_percent + "%, " + st.signal_dbm + " dBm)")
        : (st.ssid + " (" + st.signal_percent + "%)");
    } else if (st.ssid) {
      wifiEl.textContent = "\uD83D\uDCF6 " + st.ssid;
      wifiEl.title = st.ssid;
    } else {
      wifiEl.textContent = "\uD83D\uDCF6 No Wi-Fi";
      wifiEl.title = "Wi-Fi Network & Signal";
    }
    if (st.online) {
      pill.textContent = "\u25CF Live";
      pill.style.color = "#4ade80";
    } else {
      pill.textContent = st.net_error ? ("\u25CF " + st.net_error) : "\u25CF Offline";
      pill.style.color = "#f87171";
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

  if (document.documentElement) {
    document.documentElement.style.paddingTop = "24px";
    document.documentElement.appendChild(bar);
  }
})();
