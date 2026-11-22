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
  left.appendChild(mkBtn("fs-5s-gmail", "\u2709 Gmail (F1)", "gmail"));
  left.appendChild(mkBtn("fs-5s-yt", "\u25B6 YouTube (F2)", "youtube"));
  left.appendChild(mkBtn("fs-5s-disc", "\uD83D\uDCBF Disc (F3)", "disc"));

  const pill = document.createElement("div");
  pill.id = "fs-5s-pill";
  pill.textContent = "\u25CF Live";
  pill.style.cssText = "color:#4ade80;font-size:12px;";

  bar.appendChild(left);
  bar.appendChild(pill);

  if (document.documentElement) {
    document.documentElement.style.paddingTop = "24px";
    document.documentElement.appendChild(bar);
  }
})();
