(function () {
  "use strict";

  const isLocalShell = window.location.hostname === "127.0.0.1";

  function sendSwitch(tab) {
    try {
      chrome.runtime.sendMessage({ type: "switch_tab", tab: tab });
    } catch (_) {}
  }

  function proxyGet(path, cb) {
    try {
      chrome.runtime.sendMessage({ type: "proxy_get", path: path }, function (resp) {
        if (cb) cb(resp && resp.ok ? resp.data : null);
      });
    } catch (_) {
      if (cb) cb(null);
    }
  }

  function proxyPost(path, body, cb) {
    try {
      chrome.runtime.sendMessage({ type: "proxy_post", path: path, body: body || {} }, function (resp) {
        if (cb) cb(resp || { ok: false });
      });
    } catch (_) {
      if (cb) cb({ ok: false });
    }
  }

  let toggleFamilyOverlay = function () {};

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
    } else if (e.key === "F4" || (e.altKey && e.key === "4")) {
      e.preventDefault();
      toggleFamilyOverlay();
    } else if (e.key === "F12" || (e.altKey && (e.key === "d" || e.key === "D"))) {
      e.preventDefault();
      sendSwitch("diag");
    } else if (e.ctrlKey && !e.altKey && ["n", "N", "t", "T", "w", "W"].includes(e.key)) {
      e.preventDefault();
    } else if (e.ctrlKey && e.shiftKey && ["i", "I", "j", "J", "c", "C"].includes(e.key)) {
      e.preventDefault();
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
      "font-size:12px", "margin-right:6px", "border-radius:3px",
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
  right.style.cssText = "display:flex;align-items:center;gap:10px;font-size:12px;";

  const profBtn = document.createElement("button");
  profBtn.id = "fs-5s-profile-btn";
  profBtn.textContent = "\uD83D\uDC64 Standard (F4)";
  profBtn.title = "Switch Family Profile / Device Controls (F4)";
  profBtn.style.cssText = "border:none;height:20px;padding:0 8px;border-radius:3px;background:#334155;color:#f8fafc;cursor:pointer;font-size:11px;font-weight:bold;";

  const batEl = document.createElement("div");
  batEl.id = "fs-5s-battery";
  batEl.textContent = "";
  batEl.style.cssText = "color:#cbd5e1;white-space:nowrap;display:none;";

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

  right.appendChild(profBtn);
  right.appendChild(batEl);
  right.appendChild(wifiEl);
  right.appendChild(clockEl);
  right.appendChild(pill);

  bar.appendChild(left);
  bar.appendChild(right);

  // Family & Laptop Control Overlay
  const overlay = document.createElement("div");
  overlay.id = "fs-5s-overlay";
  overlay.style.cssText = [
    "position:fixed", "top:28px", "right:8px", "width:320px",
    "background:#0f172a", "color:#f1f5f9", "border:1px solid #334155",
    "border-radius:8px", "padding:12px", "box-shadow:0 10px 25px rgba(0,0,0,0.6)",
    "z-index:2147483647", "font:13px/1.4 sans-serif", "display:none"
  ].join(";");

  function renderOverlay() {
    overlay.innerHTML = "<div style='color:#94a3b8;font-size:12px;'>Loading...</div>";
    proxyGet("/__5s__/profiles", function (pdata) {
      proxyGet("/__5s__/hw/status", function (hw) {
        const profiles = (pdata && pdata.profiles) || [];
        const activeId = (pdata && pdata.active_id) || "p1";
        let html = "<div style='display:flex;justify-content:space-between;align-items:center;margin-bottom:8px;'>";
        html += "<b style='font-size:13px;'>\uD83D\uDC6A Family Profiles (" + profiles.length + "/5)</b>";
        html += "<button id='fs-5s-ov-close' style='background:none;border:none;color:#94a3b8;cursor:pointer;font-size:14px;'>\u2715</button></div>";
        html += "<div id='fs-5s-prof-list' style='display:flex;flex-direction:column;gap:6px;margin-bottom:10px;'>";
        for (const p of profiles) {
          const isAct = p.id === activeId;
          const lock = p.has_pin ? " \uD83D\uDD12" : "";
          html += "<button class='fs-5s-p-item' data-id='" + p.id + "' data-pin='" + (p.has_pin ? "1" : "0") + "' style='display:flex;align-items:center;justify-content:space-between;padding:7px 10px;border-radius:5px;border:1px solid " + (isAct ? "#3b82f6" : "#334155") + ";background:" + (isAct ? "#1e3a8a" : "#1e293b") + ";color:#fff;cursor:pointer;text-align:left;'>";
          html += "<span><span style='display:inline-block;width:10px;height:10px;border-radius:50%;background:" + (p.color || "#3b82f6") + ";margin-right:8px;'></span>" + p.name + lock + "</span>";
          html += "<span style='font-size:11px;color:#93c5fd;'>" + (isAct ? "Active" : "Switch") + "</span></button>";
        }
        html += "</div>";
        if (profiles.length < 5) {
          html += "<div style='display:flex;gap:6px;margin-bottom:10px;'>";
          html += "<input id='fs-5s-new-name' placeholder='New member name' maxlength='24' style='flex:1;padding:5px 8px;border-radius:4px;border:1px solid #334155;background:#1e293b;color:#fff;font-size:12px;' />";
          html += "<input id='fs-5s-new-pin' placeholder='PIN (opt)' maxlength='4' style='width:68px;padding:5px 6px;border-radius:4px;border:1px solid #334155;background:#1e293b;color:#fff;font-size:12px;' />";
          html += "<button id='fs-5s-add-prof' style='padding:5px 10px;border:none;border-radius:4px;background:#2563eb;color:#fff;cursor:pointer;font-size:12px;'>Add</button>";
          html += "</div>";
        }
        const vol = hw && typeof hw.volume === "number" ? hw.volume : 80;
        const bri = hw && typeof hw.brightness === "number" ? hw.brightness : 80;
        html += "<div style='border-top:1px solid #334155;padding-top:8px;margin-top:4px;font-size:12px;'>";
        html += "<div style='display:flex;align-items:center;justify-content:space-between;margin-bottom:6px;'><span>\uD83D\uDD0A Volume</span><input id='fs-5s-vol' type='range' min='0' max='100' value='" + vol + "' style='width:170px;'/></div>";
        html += "<div style='display:flex;align-items:center;justify-content:space-between;margin-bottom:8px;'><span>\u2600 Brightness</span><input id='fs-5s-bri' type='range' min='10' max='100' value='" + bri + "' style='width:170px;'/></div>";
        if (hw && typeof hw.overlay_usage_pct === "number" && hw.overlay_usage_pct >= 85) {
          html += "<div style='color:#fbbf24;font-size:11px;margin-bottom:6px;'>\u26A0 Storage " + hw.overlay_usage_pct + "% full</div>";
        }
        html += "<div style='display:flex;gap:8px;justify-content:flex-end;'>";
        html += "<button id='fs-5s-reboot' style='padding:5px 10px;border:none;border-radius:4px;background:#475569;color:#fff;cursor:pointer;font-size:12px;'>Reboot</button>";
        html += "<button id='fs-5s-poweroff' style='padding:5px 10px;border:none;border-radius:4px;background:#dc2626;color:#fff;cursor:pointer;font-size:12px;'>Power Off</button>";
        html += "</div></div>";
        overlay.innerHTML = html;

        const closeBtn = overlay.querySelector("#fs-5s-ov-close");
        if (closeBtn) closeBtn.addEventListener("click", function () { overlay.style.display = "none"; });

        overlay.querySelectorAll(".fs-5s-p-item").forEach(function (btn) {
          btn.addEventListener("click", function () {
            const id = btn.getAttribute("data-id");
            if (id === activeId) { overlay.style.display = "none"; return; }
            let pin = "";
            if (btn.getAttribute("data-pin") === "1") {
              pin = window.prompt("Enter 4-digit PIN:") || "";
              if (!pin) return;
            }
            proxyPost("/__5s__/profiles/switch", { id: id, pin: pin }, function (res) {
              if (!res || !res.ok) {
                window.alert((res && res.data && res.data.error) || "Profile switch failed");
              } else {
                overlay.style.display = "none";
              }
            });
          });
        });

        const addBtn = overlay.querySelector("#fs-5s-add-prof");
        if (addBtn) {
          addBtn.addEventListener("click", function () {
            const nm = (overlay.querySelector("#fs-5s-new-name").value || "").trim();
            const pn = (overlay.querySelector("#fs-5s-new-pin").value || "").trim();
            if (!nm) return;
            proxyPost("/__5s__/profiles/save", { name: nm, pin: pn }, function (res) {
              if (res && res.ok) renderOverlay();
              else window.alert((res && res.data && res.data.error) || "Could not add profile");
            });
          });
        }

        const volEl = overlay.querySelector("#fs-5s-vol");
        if (volEl) volEl.addEventListener("change", function () { proxyPost("/__5s__/hw/volume", { percent: Number(volEl.value) }); });
        const briEl = overlay.querySelector("#fs-5s-bri");
        if (briEl) briEl.addEventListener("change", function () { proxyPost("/__5s__/hw/brightness", { percent: Number(briEl.value) }); });
        const rebBtn = overlay.querySelector("#fs-5s-reboot");
        if (rebBtn) rebBtn.addEventListener("click", function () {
          if (window.confirm("Reboot laptop now?")) proxyPost("/__5s__/hw/power", { action: "reboot" });
        });
        const pwrBtn = overlay.querySelector("#fs-5s-poweroff");
        if (pwrBtn) pwrBtn.addEventListener("click", function () {
          if (window.confirm("Power off laptop now?")) proxyPost("/__5s__/hw/power", { action: "poweroff" });
        });
      });
    });
  }

  toggleFamilyOverlay = function () {
    if (overlay.style.display === "none") {
      overlay.style.display = "block";
      renderOverlay();
    } else {
      overlay.style.display = "none";
    }
  };

  profBtn.addEventListener("click", toggleFamilyOverlay);

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
    if (st.active_profile && st.active_profile.name) {
      profBtn.textContent = "\uD83D\uDC64 " + st.active_profile.name + " (F4)";
      if (st.active_profile.color) {
        profBtn.style.borderLeft = "3px solid " + st.active_profile.color;
      }
    }
    if (st.battery && st.battery.present) {
      batEl.style.display = "block";
      const icon = st.battery.status === "Charging" ? "\u26A1" : "\uD83D\uDD0B";
      batEl.textContent = icon + " " + st.battery.percent + "%";
      batEl.style.color = st.battery.percent <= 15 ? "#f87171" : "#cbd5e1";
    }
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
    document.documentElement.appendChild(overlay);
  }
})();
