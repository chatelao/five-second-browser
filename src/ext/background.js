"use strict";

const PROXY_BASE = "http://127.0.0.1:8555";
const GMAIL_URL = "https://mail.google.com/";
const YOUTUBE_URL = "https://www.youtube.com/";
const DISC_URL = `${PROXY_BASE}/app?tab=disc`;
const DIAG_URL = `${PROXY_BASE}/diag`;

const tabIds = {
  gmail: null,
  youtube: null,
  disc: null,
  diag: null
};

let onlineNotified = false;
let enabledFeatures = { gmail: true, youtube: true, disc: true };
let latestStatus = {
  online: true,
  ssid: "",
  signal_percent: null,
  signal_dbm: null,
  net_error: ""
};

function appLog(level, message, extra) {
  fetch(`${PROXY_BASE}/__5s__/app-log`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      level: level,
      source: "extension",
      message: message,
      extra: extra || {}
    })
  }).catch(() => {});
}

async function ensureTab(name, url, activate) {
  if (tabIds[name] !== null) {
    try {
      const existing = await chrome.tabs.get(tabIds[name]);
      if (existing) {
        if (activate) {
          await chrome.tabs.update(existing.id, { active: true });
        }
        return existing;
      }
    } catch (_) {
      tabIds[name] = null;
    }
  }
  const created = await chrome.tabs.create({ url: url, active: !!activate });
  tabIds[name] = created.id;
  appLog("info", `opened ${name} tab`, { tabId: created.id, url: url });
  return created;
}

async function switchTo(name) {
  if (name in enabledFeatures && !enabledFeatures[name]) {
    return;
  }
  if (name === "gmail") {
    const target = onlineNotified ? GMAIL_URL : `${PROXY_BASE}/app`;
    await ensureTab("gmail", target, true);
  } else if (name === "youtube") {
    await ensureTab("youtube", YOUTUBE_URL, true);
  } else if (name === "disc") {
    await ensureTab("disc", DISC_URL, true);
  } else if (name === "diag") {
    await ensureTab("diag", DIAG_URL, true);
  }
}

async function pollProxyOnline() {
  try {
    const res = await fetch(`${PROXY_BASE}/__5s__/status`);
    if (!res.ok) return;
    const st = await res.json();
    if (st.features && typeof st.features === "object") {
      enabledFeatures = {
        gmail: st.features.gmail !== false,
        youtube: st.features.youtube !== false,
        disc: st.features.disc !== false
      };
    }
    if (st.online && st.wifi_configured && !onlineNotified) {
      onlineNotified = true;
      appLog("info", "network online; launching enabled web tabs", {
        ssid: st.ssid || "",
        ip: st.ip || "",
        features: enabledFeatures
      });
      const allTabs = await chrome.tabs.query({});
      if (enabledFeatures.gmail) {
        if (tabIds.gmail === null && allTabs.length > 0) {
          const first = allTabs[0];
          if (first.url && first.url.startsWith(`${PROXY_BASE}/app`) && !first.url.includes("tab=disc")) {
            tabIds.gmail = first.id;
          }
        }
        if (tabIds.gmail !== null) {
          try {
            const gTab = await chrome.tabs.get(tabIds.gmail);
            if (gTab && gTab.url && gTab.url.startsWith(PROXY_BASE)) {
              await chrome.tabs.update(gTab.id, { url: GMAIL_URL });
            }
          } catch (_) {}
        } else {
          await ensureTab("gmail", GMAIL_URL, true);
        }
      }
      if (enabledFeatures.youtube && !enabledFeatures.gmail) {
        if (allTabs.length > 0 && allTabs[0].url && allTabs[0].url.startsWith(`${PROXY_BASE}/app`) && !allTabs[0].url.includes("tab=disc")) {
          await chrome.tabs.update(allTabs[0].id, { url: YOUTUBE_URL, active: true });
          tabIds.youtube = allTabs[0].id;
        } else {
          await ensureTab("youtube", YOUTUBE_URL, true);
        }
      }
    }
  } catch (_) {}
}

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (msg && msg.type === "get_features") {
    sendResponse({ features: enabledFeatures });
    return false;
  }
  if (msg && msg.type === "get_status") {
    sendResponse({ status: latestStatus });
    return false;
  }
  if (msg && msg.type === "switch_tab" && msg.tab) {
    if (sender && sender.tab && sender.tab.url) {
      if (sender.tab.url.startsWith(PROXY_BASE) && !sender.tab.url.includes("tab=disc")) {
        tabIds.gmail = sender.tab.id;
      } else if (sender.tab.url.includes("youtube.com")) {
        tabIds.youtube = sender.tab.id;
      } else if (sender.tab.url.includes("tab=disc")) {
        tabIds.disc = sender.tab.id;
      }
    }
    switchTo(msg.tab).catch((err) => {
      appLog("error", `switch_tab(${msg.tab}) failed: ${err}`);
    });
  }
  return false;
});

chrome.webNavigation.onErrorOccurred.addListener((details) => {
  if (details.frameId === 0) {
    appLog("error", `navigation failed: ${details.error}`, {
      url: details.url,
      tabId: details.tabId
    });
  }
});

chrome.webNavigation.onCompleted.addListener((details) => {
  if (details.frameId === 0 && !details.url.startsWith("chrome")) {
    appLog("info", `page loaded: ${details.url}`, { tabId: details.tabId });
  }
});

chrome.tabs.onRemoved.addListener((tabId) => {
  for (const k of Object.keys(tabIds)) {
    if (tabIds[k] === tabId) tabIds[k] = null;
  }
});

appLog("info", "5s-browser extension background worker started");
pollProxyOnline();
setInterval(pollProxyOnline, 1500);
