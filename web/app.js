/**
 * PANIC ANALYZER - iOS Hardware Diagnostic Engine
 * 100% Client-side & On-Device Analysis
 */

// Global State
let diagnosticRecords = [];
let incidentGroups = [];
let currentFilter = 'all';
let currentSearchQuery = '';
let logPartSignals = [];
// Báo cáo phần cứng do thiết bị tự khai qua lockdown (IC xác thực màn hình, pin).
let hardwareReport = null;
let hardwarePartSignals = [];
let partsScanState = 'idle';
let partsScanCount = 0;
let partsScanError = '';
let ruleDatabases = {
  panic_rules: [],
  i2c_rules: {},
  sensor_database: {},
  model_database: {},
  sample_logs: []
};

// Initialize app
document.addEventListener('DOMContentLoaded', async () => {
  // Báo native trang đã chạy (native hiện lỗi thay vì màn đen nếu không nhận được).
  try { window.webkit.messageHandlers.nativeBridge.postMessage({ action: 'pageReady' }); } catch (e) { /* trình duyệt */ }
  applyStaticI18n();
  setActiveTab('panic');
  updatePartsPairingRequirement();
  renderPartsScanSummary();
  // Nhãn phiên bản ở đầu trang lấy từ app đang cài, không ghi cứng.
  const badge = document.querySelector('.version-badge');
  if (badge && window.__APP_VERSION__) badge.textContent = `v${window.__APP_VERSION__} Pro`;
  const settingsVersion = document.getElementById('settingsVersion');
  if (settingsVersion) settingsVersion.textContent = (window.__APP_VERSION__
    || document.querySelector('.version-badge')?.textContent?.replace(/^v| Pro$/g, '') || '')
    + (window.__WEB_BUILD__ ? ` · ${t('webupd.version', { n: window.__WEB_BUILD__ })}` : '');
  showAppCrashes();
  await loadDatabases();
  updateDetectedModel();
  applyJailbreakMode();
  updatePairingButton(!!window.__PAIRING_CONFIGURED__);
  // Pairing file iLoader/Files đặt vào Documents đã được nhập lúc mở app
  if (window.__PAIRING_NOTICE__ && window.__PAIRING_NOTICE__.message) {
    const n = window.__PAIRING_NOTICE__;
    showToast(n.error ? `Pairing: ${n.message}` : `✓ ${n.message}`, n.error ? 6000 : 4500);
  }

  const hasBridge = !!(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.nativeBridge);
  if (hasBridge && (window.__CAN_READ_LOGS__ || window.__PAIRING_CONFIGURED__ || window.__AUTO_PAIRING__)) {
    setPartsScanState(window.__CAN_READ_LOGS__ || window.__PAIRING_CONFIGURED__
      ? 'scanning' : 'pairRequired');
    updateScanStatus(window.__CAN_READ_LOGS__
      ? t('s.readingDirect')
      : (window.__PAIRING_CONFIGURED__
        ? t('s.connecting')
        : (window.__AUTO_PAIRING__
          ? t('s.checkingPair')
          : t('s.readingSystem'))), true);
    armScanTimeout();
    resetHardwareReport();
    try {
      window.webkit.messageHandlers.nativeBridge.postMessage({ action: 'autoScanLogs' });
    } catch (e) {
      clearScanTimeout();
      showEmptyState();
      setPartsScanState('error');
    }
  } else {
    showEmptyState();
  }
});

// Trạng thái rỗng - KHÔNG BAO GIỜ hiện dữ liệu giả như thể là log máy người dùng
function showEmptyState() {
  diagnosticRecords = [];
  incidentGroups = [];
  logPartSignals = [];
  renderPartsHistory();
  setDemoBanner(false);
  updateDashboardStats();
  renderIncidentList();
  updateScanStatus(t(window.__CAN_READ_LOGS__ ? 's.noLogsJB' : 's.sandboxHint'), false);
}

// Banner cảnh báo khi đang xem dữ liệu mẫu
function setDemoBanner(on) {
  const id = 'demoBanner';
  let el = document.getElementById(id);
  if (!on) { if (el) el.remove(); return; }
  if (el) return;
  const list = document.getElementById('incidentList');
  if (!list || !list.parentNode) return;
  el = document.createElement('div');
  el.id = id;
  el.style.cssText = 'margin:0 0 12px;padding:12px 14px;border-radius:12px;'
    + 'background:rgba(255,107,0,.12);border:1px solid rgba(255,107,0,.38);'
    + 'color:#ffa02e;font-size:13px;font-weight:600;line-height:1.45';
  el.innerText = t('s.sampleBanner');
  list.parentNode.insertBefore(el, list);
}

// Nạp TẤT CẢ log mẫu - chỉ chạy khi người dùng chủ động bấm
function loadAllSamples() {
  const all = ruleDatabases.sample_logs || [];
  if (!all.length) return;
  closeSampleModal();
  setPartsScanState('idle');
  parseAndIngestLogs(all);
  setDemoBanner(true);
  updateScanStatus(t('s.viewingSamples', { n: all.length }), false);
}

// Update Scan Status in UI
function updateScanStatus(text, isSpinning) {
  const statusText = document.getElementById('scanStatusText');
  const spinIcon = document.getElementById('scanSpinIcon');
  if (statusText) statusText.innerText = text;
  if (spinIcon) {
    if (isSpinning) spinIcon.classList.add('active');
    else spinIcon.classList.remove('active');
  }
}

// Native Bridge Callback: called after direct, pairing, picker or Share Sheet import.
window.handleNativeLogsReceived = function(logsJsonStr) {
  clearScanTimeout();
  try {
    const logs = typeof logsJsonStr === 'string' ? JSON.parse(logsJsonStr) : logsJsonStr;
    if (!logs.length) {
      showEmptyState();
      return;
    }
    setDemoBanner(false);
    parseAndIngestLogs(logs);
  } catch (e) {
    console.error("Error parsing native logs:", e);
    setPartsScanState('error');
    updateScanStatus(t('s.readError'), false);
    showToast(t('s.readFailToast'), 4000);
  }
};

// Trigger Auto-Scan manually
function triggerAutoScan() {
  if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.nativeBridge) {
    setPartsScanState(window.__CAN_READ_LOGS__ || window.__PAIRING_CONFIGURED__
      ? 'scanning' : 'pairRequired');
    updateScanStatus(t('s.checking'), true);
    armScanTimeout();
    resetHardwareReport();
    window.webkit.messageHandlers.nativeBridge.postMessage({ action: 'autoScanLogs' });
  } else {
    showEmptyState();
    setPartsScanState('error');
  }
}

function triggerPairingImport() {
  if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.nativeBridge) {
    updateScanStatus(t('s.pairing'), true);
    armScanTimeout();
    window.webkit.messageHandlers.nativeBridge.postMessage({ action: 'pairDevice' });
    return;
  }
  showToast(t('s.iosOnly'), 3500);
}

function setActiveTab(name) {
  for (const tab of ['panic', 'parts', 'settings']) {
    const selected = tab === name;
    const panel = document.getElementById(tab + 'Tab');
    const button = document.getElementById('tab' + tab[0].toUpperCase() + tab.slice(1));
    if (panel) panel.hidden = !selected;
    if (button) button.setAttribute('aria-selected', String(selected));
  }
}

function updatePartsPairingRequirement() {
  const hint = document.getElementById('partsPairingRequirement');
  const label = document.getElementById('partsScanLabel');
  const key = window.__CAN_READ_LOGS__ ? 'parts.directScan'
    : (window.__PAIRING_CONFIGURED__ ? 'parts.paired' : 'parts.pairRequired');
  if (hint) hint.textContent = t(key);
  if (label) label.textContent = t(window.__CAN_READ_LOGS__ ? 'parts.scanDirect' : 'parts.scan');
}

function scanPartsThroughPairing() {
  if (!window.__CAN_READ_LOGS__ && !window.__PAIRING_CONFIGURED__) {
    setPartsScanState('pairRequired');
    setActiveTab('panic');
    triggerPairingImport();
    return;
  }
  triggerAutoScan();
  showToast(t('parts.scanning'), 3500);
}

function setPartsScanState(state, count = 0, error = '') {
  partsScanState = state;
  partsScanCount = count;
  partsScanError = String(error || '').slice(0, 240);
  renderPartsScanSummary();
}

function renderPartsScanSummary() {
  const host = document.getElementById('partsScanSummary');
  const title = document.getElementById('partsScanTitle');
  const detail = document.getElementById('partsScanDetail');
  if (!host || !title || !detail) return;
  host.className = 'parts-scan-summary ' + partsScanState;
  title.textContent = t('parts.result.' + partsScanState + 'Title');
  detail.textContent = t('parts.result.' + partsScanState + 'Detail', {
    n: partsScanCount,
    message: partsScanError || t('parts.result.errorFallback')
  });
}

function triggerPairingFileImport() {
  if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.nativeBridge) {
    window.webkit.messageHandlers.nativeBridge.postMessage({ action: 'importPairing' });
    return;
  }
  showToast(t('s.iosOnly'), 3500);
}

function openLink(url) {
  if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.nativeBridge) {
    window.webkit.messageHandlers.nativeBridge.postMessage({ action: 'openURL', url: url });
  } else {
    window.open(url, '_blank');
  }
}

// Đổi ngôn ngữ: dịch lại giao diện và phân tích lại log đang xem theo ngôn ngữ mới
function onLanguageChanged() {
  renderPartsHistory();
  renderPartsScanSummary();
  updatePartsPairingRequirement();
  const banner = document.getElementById('demoBanner');
  if (banner) banner.innerText = t('s.sampleBanner');
  updateDetectedModel();
  applyJailbreakMode();
  updatePairingButton(!!window.__PAIRING_CONFIGURED__);
  renderRulesInfo(window.__RULES_INFO__);
  populateSampleLogsModal();
  if (diagnosticRecords.length) {
    reanalyzeStoredLogs();
  } else {
    renderIncidentList();
    updateScanStatus(t(window.__CAN_READ_LOGS__ ? 's.noLogsJB' : 's.sandboxHint'), false);
  }
}

function nativeAction(action) {
  if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.nativeBridge) {
    window.webkit.messageHandlers.nativeBridge.postMessage({ action: action });
  }
}

// Pairing steps + PIN stay visible on the main screen while the user is in Settings.
window.onNativePairingCard = function(info) {
  const card = document.getElementById('pairingCard');
  if (!card) return;
  if (info.stage === 'done') { card.hidden = true; return; }
  card.hidden = false;
  const title = document.getElementById('pairingCardTitle');
  const pinBox = document.getElementById('pairingPin');
  if (info.stage === 'permission') {
    title.innerText = t('pair.permission');
    pinBox.hidden = true;
  } else if (info.stage === 'advertising') {
    title.innerText = t('pair.waiting');
    pinBox.hidden = true;
  } else if (info.stage === 'pin' && info.pin) {
    title.innerText = t('pair.enterPin');
    pinBox.innerText = info.pin.replace(/(\d{3})(\d{3})/, '$1 $2');
    pinBox.hidden = false;
  }
  card.scrollIntoView({ behavior: 'smooth', block: 'center' });
};


// Load JSON Databases
async function loadDatabases() {
  const files = ['panic_rules', 'i2c_rules', 'sensor_database', 'model_database', 'sample_logs'];

  // Native (Swift) nạp sẵn DB vào window.__NATIVE_DB__ vì fetch() trên file://
  // bị CORS chặn trong WKWebView. Fallback fetch cho môi trường web/dev.
  if (window.__NATIVE_DB__) {
    for (const f of files) {
      if (window.__NATIVE_DB__[f]) ruleDatabases[f] = window.__NATIVE_DB__[f];
    }
    console.log('[PanicAnalyzer] Rule DB nap tu native:', files.filter(f => window.__NATIVE_DB__[f]).join(', '));
  } else {
    for (const f of files) {
      try {
        const resp = await fetch(`../assets/${f}.json`);
        if (resp.ok) ruleDatabases[f] = await resp.json();
      } catch (e) {
        console.warn(`Khong doc duoc ../assets/${f}.json`, e);
      }
    }
  }
  populateSampleLogsModal();
  renderRulesInfo(window.__RULES_INFO__);
}

function updateDetectedModel() {
  const badge = document.getElementById('detectedModelBadge');
  if (!badge) return;
  const id = window.__DEVICE_MODEL__ || '';   // mã máy THẬT do Swift bơm vào
  const ios = window.__IOS_VERSION__ || '';
  if (id) {
    const name = (ruleDatabases.model_database || {})[id] || id;
    badge.innerText = ios ? `${name} · iOS ${ios}` : name;
    badge.title = id;
  } else {
    badge.innerText = t('health.preview');
  }
}

// ---------------------------------------------------------------------------
// 1. IPSParser & FileClassifier
// ---------------------------------------------------------------------------
function parseTimestamp(raw) {
  if (!raw) return null;
  const s = String(raw).trim();
  const m = s.match(/^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2}):(\d{2})(?:\.\d+)?\s*([+-]\d{4})?/);
  if (m) {
    let iso = `${m[1]}-${m[2]}-${m[3]}T${m[4]}:${m[5]}:${m[6]}`;
    if (m[7]) iso += m[7].slice(0, 3) + ':' + m[7].slice(3);
    const d = new Date(iso);
    if (!isNaN(d.getTime())) return d.getTime();
  }
  const d2 = new Date(s);
  return isNaN(d2.getTime()) ? null : d2.getTime();
}

// Ngày giờ theo múi giờ của máy, ví dụ "20/09/2026 10:15:30".
function formatLogTime(ms) {
  if (!ms) return t('time.unknown');
  const d = new Date(ms);
  const p = n => String(n).padStart(2, '0');
  return `${p(d.getDate())}/${p(d.getMonth() + 1)}/${d.getFullYear()} ${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
}

// "3 giờ trước", "2 ngày trước"… để biết lỗi còn mới hay đã cũ.
function formatAgo(ms) {
  if (!ms) return '';
  const diff = Date.now() - ms;
  if (diff < 0) return '';
  const min = Math.floor(diff / 60000);
  if (min < 1) return t('time.now');
  if (min < 60) return t('time.min', { n: min });
  const h = Math.floor(min / 60);
  if (h < 24) return t('time.hour', { n: h });
  const day = Math.floor(h / 24);
  if (day < 60) return t('time.day', { n: day });
  return t('time.month', { n: Math.floor(day / 30) });
}

function sortedOccurrences(g) {
  return g.allRecords.slice().sort((a, b) => (b.timestampMs || 0) - (a.timestampMs || 0));
}

function normalizeI2CError(m) {
  if (!m) return t('i2c.unknown');
  const raw = m[1].toLowerCase();
  if (/stuck|checkbusstatus|bus busy/.test(raw)) return t('i2c.stuck');
  if (/nack/.test(raw)) return t('i2c.nack');
  if (/timeout|timed ?out/.test(raw)) return 'timeout';
  if (/arbitration/.test(raw)) return t('i2c.arb');
  return raw;
}

function extractI2CEvents(text) {
  const events = [];
  const re = /i2c[^\n]{0,200}/gi;
  let m;
  while ((m = re.exec(text)) !== null && events.length < 5) {
    const line = m[0];
    const busM  = line.match(/i2c[\s_\-]?([0-3])\b/i);
    const addrM = line.match(/0x[0-9a-f]{2,4}\b/i);
    const errM  = line.match(/\b(timeout|timed out|timedout|nack|arbitration|invalid response)\b/i)
                || line.match(/(S[CD]L is stuck \w+|stuck low|stuck high|bus busy|_checkBusStatus|_checkInterrupts)/i);
    // Trích tên thiết bị: "for device ad5860", "device roswell", "device_name=xxx"
    const devM = line.match(/(?:for device|device[_\s]+name[=:\s]+)\s*([a-zA-Z][a-zA-Z0-9_\-]+)/i)
               || line.match(/\b(ad5860|roswell|audio-speaker-(?:top|bottom)|mic\d+|prs\d+|als\d+|gyro\d+|accel\d+|orb|haptics)\b/i);
    if (!errM && !addrM && !devM) continue;
    events.push({
      bus: busM ? 'i2c' + busM[1] : 'unknown',
      address: addrM ? addrM[0].toLowerCase() : null,
      deviceName: devM ? devM[1].toLowerCase() : null,
      error: normalizeI2CError(errM),
      controller: 'AppleARMPlatform / SPU'
    });
  }
  return events;
}

function parseLogContent(rawText, filename = "log.ips") {
  const record = {
    filename, rawText,
    timestampMs: null, bugType: "unknown", incidentId: "",
    product: "", osVersion: "", build: "",
    panicString: "", panicFamily: "Unknown", panickedTask: "",
    panicInitiator: "", socId: "",
    processName: "", exceptionType: "",
    missingSensors: [], i2cEvents: [], backtrace: [],
    logType: "unknown", ruleId: null, rule: null,
    baseSeverity: "normal", severity: "normal",
    confidence: "Thấp", title: t('rec.defaultTitle'),
    suspectedComponent: t('rec.defaultSuspect'),
    repairAdvice: t('rec.defaultAdvice'),
    modelSpecific: false,
    resetCounter: null
  };

  const lines = rawText.split('\n');
  let head = null, body = null;
  try { if (lines[0] && lines[0].trim().startsWith('{')) head = JSON.parse(lines[0].trim()); } catch (e) {}

  if (head) {
    record.bugType    = head.bug_type || record.bugType;
    record.incidentId = head.incident_id || "";
    record.osVersion  = head.os_version || "";
    record.timestampMs = parseTimestamp(head.timestamp);
    const rest = lines.slice(1).join('\n').trim();
    if (rest.startsWith('{')) { try { body = JSON.parse(rest); } catch (e) {} }
  } else {
    try { body = JSON.parse(rawText.trim()); if (body.bug_type) record.bugType = body.bug_type; } catch (e) {}
  }

  if (body) {
    record.product      = body.product || "";
    record.build        = body.build || "";
    record.panicString  = body.panicString || "";
    record.panickedTask = body.panickedTask || "";
    if (!record.timestampMs) record.timestampMs = parseTimestamp(body.timestamp || body.captureTime);
    if (body.procName) record.processName = body.procName;
    record.panicInitiator = body.panicInitiator || "";
    record.socId = body.socId ? String(body.socId) : "";
    if (body.exception && body.exception.type) record.exceptionType = body.exception.type;
  }

  // Báo cáo crash của app (bug_type 309 = JSON từ iOS 15, 109 = .crash cũ):
  // app nào, lúc nào, vì sao — tách hẳn khỏi kernel panic.
  const crash = extractAppCrash(head, body, rawText, record.bugType, filename);
  if (crash) {
    record.appCrash = crash;
    record.processName = crash.procName || crash.name || record.processName;
    if (crash.exceptionType) record.exceptionType = crash.exceptionType;
    if (!record.timestampMs && crash.time) record.timestampMs = parseTimestamp(crash.time);
    record.panicString = crashSummaryText(crash);
  }

  if (!record.panicString) {
    const pm = rawText.match(/"panicString"\s*:\s*"([^"]+)"/);
    if (pm) {
      record.panicString = pm[1].replace(/\\n/g, '\n').replace(/\\"/g, '"');
    } else {
      const i = rawText.indexOf("panic(");
      record.panicString = i !== -1 ? rawText.substring(i, i + 1500) : rawText.substring(0, 1200);
    }
  }
  if (!record.processName) {
    const pn = rawText.match(/(?:Process|procName)["\s:]+([A-Za-z0-9_.\-]+)/);
    if (pn) record.processName = pn[1];
  }
  if (!record.exceptionType) {
    const et = rawText.match(/(EXC_[A-Z_]+)/);
    if (et) record.exceptionType = et[1];
  }
  if (!record.timestampMs) {
    const tm = rawText.match(/\b\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}[^"\n]*/);
    if (tm) record.timestampMs = parseTimestamp(tm[0]);
  }
  if (!record.timestampMs) {
    // iOS đặt tên file theo thời điểm: panic-full-2026-09-20-101530.000.ips
    const fm = String(filename).match(/(\d{4})-(\d{2})-(\d{2})-(\d{2})(\d{2})(\d{2})/);
    if (fm) record.timestampMs = parseTimestamp(`${fm[1]}-${fm[2]}-${fm[3]} ${fm[4]}:${fm[5]}:${fm[6]}`);
  }

  // CHỈ khớp luật trong panicString + panicInitiator + 4KB đầu file.
  // Quét cả file (có thể >1MB stackshot) gây dương tính giả nghiêm trọng:
  // chuỗi "ANS"/"nvme" nằm trong danh sách tiến trình của MỌI log.
  const matchText = crash
    ? record.panicString
    : [record.panicString, record.panicInitiator, rawText.slice(0, 4096)].join("\n");
  const text = matchText;

  // FileClassifier
  if (crash) {
    record.logType = "app_crash";
  } else if (record.bugType === "210" || /panic\(/.test(record.panicString) || filename.includes("panic-full")) {
    record.logType = "kernel_panic";
  } else if (/watchdog/i.test(text)) {
    record.logType = "watchdog";
  } else if (record.bugType === "298" || /JetsamEvent|largestProcess/.test(text)) {
    record.logType = "jetsam";
  } else if (/EXC_RESOURCE|cpu_usage|WAKEUPS/.test(text)) {
    record.logType = "cpu_resource";
  } else if (/DiskWrites|disk_writes|WRITES_CAUSE/.test(text)) {
    record.logType = "disk_writes";
  } else if (/ThermalTrap|thermal_trap|Thermal Event|thermalpressure/i.test(text)) {
    record.logType = "thermal";
  } else if (/EXC_CRASH|EXC_BAD_ACCESS|Termination Reason|SIGABRT/.test(text) || filename.endsWith(".crash")) {
    record.logType = "app_crash";
  }

  // Chỉ nhận danh sách phân tách bằng dấu phẩy trên CÙNG một dòng,
  // tránh nuốt nhầm chữ phía sau (vd "Prs0 thermalmonitord").
  const sm = record.panicString.match(/Missing sensor\(s\):[ \t]*([A-Za-z0-9_]+(?:[ \t]*,[ \t]*[A-Za-z0-9_]+)*)/i);
  if (sm) record.missingSensors = sm[1].split(/[ \t]*,[ \t]*/).filter(Boolean).slice(0, 8);

  record.i2cEvents = extractI2CEvents(text);
  // Đọc reset counter / panic count từ header log
  const rcm = rawText.match(/(?:panic count|reset counter|Num recent panics)[:\s]+?(\d+)/i);
  if (rcm) record.resetCounter = parseInt(rcm[1], 10);

  applyRules(record, text);
  if (crash) {
    record.title = t('crash.app.title', { app: crash.name || crash.procName || '?' });
    // Luật chung "lỗi app bên thứ ba" không đúng với app của Apple.
    if (crash.firstParty === true && record.ruleId === 'generic-app-crash') {
      record.suspectedComponent = t('crash.app.appleSuspect', { app: crash.name || crash.procName });
    }
  }
  markOwnCrash(record, head, body);
  return record;
}

// Mã kết thúc có ý nghĩa riêng (Apple: "Addressing watchdog terminations",
// "Understanding the exception types in a crash report").
const TERMINATION_CODES = {
  '8badf00d': 'crash.term.watchdog', 'dead10cc': 'crash.term.dead10cc',
  'c00010ff': 'crash.term.thermal', 'bad22222': 'crash.term.voip', 'deadfa11': 'crash.term.forceQuit'
};

function hexCode(value) {
  const n = Number(value);
  return Number.isFinite(n) && n >= 0 ? '0x' + n.toString(16) : String(value || '');
}

// Metadata của một báo cáo crash: tên/bundle ở dòng đầu, procName, exception,
// termination và ảnh (thư viện) chứa khung lệnh bị lỗi ở phần thân.
function extractAppCrash(head, body, rawText, bugType, filename) {
  const type = String(bugType || '');
  const legacyText = !body && /^(?:Process|Exception Type):\s/m.test(rawText.slice(0, 20000));
  const isCrash = type === '309' || type === '109' ||
    (legacyText && (/^Exception Type:/m.test(rawText) || String(filename).endsWith('.crash')));
  if (!isCrash) return null;
  const info = { name: '', bundleID: '', version: '', procName: '', exceptionType: '', signal: '',
    subtype: '', termination: '', terminationKey: '', reasons: '', crashedIn: '', firstParty: null, time: '' };
  if (head) {
    info.name = String(head.app_name || head.name || '');
    info.bundleID = String(head.bundleID || '');
    info.version = [head.app_version, head.build_version].filter(Boolean).join(' / ');
    if (head.is_first_party === 1 || head.is_first_party === true) info.firstParty = true;
    else if (head.is_first_party === 0 || head.is_first_party === false) info.firstParty = false;
    info.time = String(head.timestamp || '');
  }
  if (body) {
    info.procName = String(body.procName || '');
    const bundle = body.bundleInfo || {};
    info.bundleID = info.bundleID || String(bundle.CFBundleIdentifier || '');
    info.version = info.version || [bundle.CFBundleShortVersionString, bundle.CFBundleVersion].filter(Boolean).join(' / ');
    info.time = info.time || String(body.captureTime || '');
    const ex = body.exception || {};
    info.exceptionType = String(ex.type || '');
    info.signal = String(ex.signal || '');
    info.subtype = String(ex.subtype || '');
    const term = body.termination || {};
    if (term.namespace || term.code !== undefined) {
      const code = term.namespace === 'SIGNAL' ? String(term.code) : hexCode(term.code);
      info.termination = [term.namespace, code, term.indicator].filter(v => v !== undefined && v !== '').join(' ');
      info.terminationKey = TERMINATION_CODES[hexCode(term.code).replace(/^0x/, '')] || '';
      if (Array.isArray(term.reasons)) info.reasons = term.reasons.slice(0, 3).join(' | ').slice(0, 300);
      if (term.byProc) info.termination += ` (${term.byProc})`;
    }
    const threads = Array.isArray(body.threads) ? body.threads : [];
    const faulting = threads[Number(body.faultingThread)] || threads.find(th => th && th.triggered);
    const frame = faulting && Array.isArray(faulting.frames) ? faulting.frames[0] : null;
    const image = frame && Array.isArray(body.usedImages) ? body.usedImages[frame.imageIndex] : null;
    if (image && image.name) info.crashedIn = image.name + (frame.symbol ? ` · ${frame.symbol}` : '');
  } else {
    const line = rx => { const m = rawText.match(rx); return m ? m[1].trim() : ''; };
    info.procName = line(/^Process:\s+([^\[\n]+)/m);
    info.bundleID = line(/^Identifier:\s+(\S+)/m);
    info.version = line(/^Version:\s+(.+)$/m);
    info.time = line(/^Date\/Time:\s+(.+)$/m);
    const exc = rawText.match(/^Exception Type:\s+(\S+)(?:\s+\((\w+)\))?/m);
    if (exc) { info.exceptionType = exc[1]; info.signal = exc[2] || ''; }
    info.subtype = line(/^Exception (?:Subtype|Codes):\s+(.+)$/m);
    info.termination = line(/^Termination Reason:\s+(.+)$/m);
    const code = info.termination.match(/0x([0-9a-f]{8})/i);
    info.terminationKey = code ? TERMINATION_CODES[code[1].toLowerCase()] || '' : '';
    const crashed = rawText.match(/^Thread \d+ Crashed:[^\n]*\n\d+\s+(\S+)/m);
    if (crashed) info.crashedIn = crashed[1];
  }
  info.name = info.name || info.procName;
  if (!info.name && !info.exceptionType && !info.termination) return null;
  return info;
}

// Lý do ngắn: loại exception, tín hiệu, lý do kết thúc.
function crashReason(crash) {
  if (!crash) return '';
  const parts = [];
  if (crash.terminationKey) parts.push(t(crash.terminationKey));
  const exc = [crash.exceptionType, crash.signal && `(${crash.signal})`].filter(Boolean).join(' ');
  if (exc) parts.push(exc);
  if (crash.subtype) parts.push(crash.subtype.slice(0, 120));
  if (!parts.length && crash.termination) parts.push(crash.termination.slice(0, 160));
  return parts.join(' · ');
}

function crashSummaryText(crash) {
  const lines = [
    `App: ${crash.name}${crash.bundleID ? ` (${crash.bundleID})` : ''}${crash.version ? ` ${crash.version}` : ''} crash`,
    crash.procName && crash.procName !== crash.name ? `Process: ${crash.procName}` : '',
    crash.exceptionType ? `Exception: ${crash.exceptionType}${crash.signal ? ` (${crash.signal})` : ''}${crash.subtype ? ` ${crash.subtype}` : ''}` : '',
    crash.termination ? `Termination Reason: ${crash.termination}` : '',
    crash.reasons ? `Reasons: ${crash.reasons}` : '',
    crash.crashedIn ? `Crashed in: ${crash.crashedIn}` : ''
  ];
  return lines.filter(Boolean).join('\n');
}

// Crash của chính PanicAnalyzer (đọc được qua pairing hoặc bản TrollStore/JB):
// lỗi phần mềm của app, không phải phần cứng — tách riêng để gửi iOSVN sửa.
const OWN_BUNDLE_ID = 'com.iosvn.panicanalyzer';

function markOwnCrash(record, head, body) {
  const ids = [head && head.bundleID, head && head.app_name, body && body.bundleInfo && body.bundleInfo.CFBundleIdentifier,
    body && body.procName, record.processName].map(v => String(v || ''));
  const ours = ids.some(v => v === OWN_BUNDLE_ID || v === OWN_BUNDLE_ID + '.share' || v === 'PanicAnalyzer' || v === 'PanicAnalyzerShare');
  const crashLike = ['109', '309'].includes(String(record.bugType)) || record.logType === 'app_crash';
  if (!ours || !crashLike) return;
  record.ownCrash = true;
  record.logType = 'app_crash';
  record.ruleId = 'panicanalyzer-crash';
  record.rule = { id: record.ruleId, family: 'AppCrash', baseSeverity: 'normal', subsystemWeight: 0, escalateAt: 1000 };
  record.panicFamily = 'AppCrash';
  record.baseSeverity = record.severity = 'normal';
  record.title = t('crash.own.title');
  record.suspectedComponent = 'PanicAnalyzer';
  record.repairAdvice = t('crash.own.advice');
  record.confidence = 'Cao';
}

// ---------------------------------------------------------------------------
// 2. Rule Engine (dữ liệu nằm hoàn toàn trong panic_rules.json)
// ---------------------------------------------------------------------------
function ruleMatches(text, lower, m) {
  if (!m) return false;
  if (m.noneOf && m.noneOf.some(k => text.includes(k))) return false;
  let checked = false;
  if (m.allOf)    { checked = true; if (!m.allOf.every(k => lower.includes(k.toLowerCase()))) return false; }
  if (m.regexAny) { checked = true; if (!m.regexAny.some(rx => new RegExp(rx, 'i').test(text))) return false; }
  if (m.anyOf)    { checked = true; if (!m.anyOf.some(k => lower.includes(k.toLowerCase()))) return false; }
  return checked;
}

const FALLBACK_RULES = {
  kernel_panic: { id: 'kernel-panic-unknown', family: 'KernelPanic', baseSeverity: 'warning',
    subsystemWeight: 1, escalateAt: 3, windowHours: 48,
    titleKey: 'rule.kp.title', suspectedKey: 'rule.kp.s',
    subsystem: 'Kernel', adviceKey: 'rule.kp.a',
    confidence: 'Thấp' },
  unknown: { id: 'unknown-log', family: 'Unknown', baseSeverity: 'normal',
    subsystemWeight: 0, escalateAt: 10, windowHours: 24,
    titleKey: 'rule.gen.title', suspectedKey: 'rule.gen.s',
    subsystem: 'Diagnostics', adviceKey: 'rule.gen.a',
    confidence: 'Thấp' }
};

function applyRules(record, text) {
  const lower = text.toLowerCase();
  const rules = ruleDatabases.panic_rules || [];
  let hit = null;
  for (const r of rules) { if (ruleMatches(text, lower, r.match)) { hit = r; break; } }
  if (!hit) hit = FALLBACK_RULES[record.logType] || FALLBACK_RULES.unknown;

  record.rule = hit;
  record.ruleId = hit.id;
  record.panicFamily = hit.family;
  record.baseSeverity = hit.baseSeverity || 'normal';
  record.severity = record.baseSeverity;
  record.title = hit.titleKey ? t(hit.titleKey) : loc(hit, 'title');
  record.suspectedComponent = hit.suspectedKey ? t(hit.suspectedKey) : loc(hit, 'suspected');
  record.repairAdvice = hit.adviceKey ? t(hit.adviceKey) : loc(hit, 'advice');
  record.confidence = hit.confidence || 'Trung bình';

  // Làm giàu: cảm biến SMC
  if (record.missingSensors.length) {
    const s = record.missingSensors[0];
    const info = (ruleDatabases.sensor_database || {})[s];
    record.title = t('smc.title', { s: record.missingSensors.join(', ') });
    if (info) {
      record.suspectedComponent = `${info.name} (${loc(info, 'location')})`;
      record.repairAdvice = t('smc.advice', { m: loc(info, 'meaning'), a: loc(info, 'action') });
      record.confidence = 'Cao';
      record.modelSpecific = true;
    } else {
      record.suspectedComponent = t('smc.suspect', { s: s });
      record.confidence = 'Trung bình';
    }
  }

  // Làm giàu: I2C — ưu tiên tra theo tên thiết bị (ad5860, roswell…), sau đó mới theo địa chỉ hex
  if (record.i2cEvents.length && record.panicFamily === 'I2C') {
    const ev = record.i2cEvents[0];
    const db = ruleDatabases.i2c_rules || {};
    const devLabel = ev.deviceName
      ? t('i2c.devLabel', { d: ev.deviceName })
      : (ev.address ? ` @ ${ev.address}` : '');
    record.title = t('i2c.title', { bus: ev.bus, dev: devLabel, err: ev.error });

    // Tra theo tên thiết bị trước (độ chính xác cao hơn địa chỉ hex)
    const devEntry = ev.deviceName ? ((db.device_names || {})[ev.deviceName]) : null;
    if (devEntry) {
      const byModel = devEntry.models && record.product ? devEntry.models[record.product] : null;
      if (byModel) {
        record.suspectedComponent = loc(devEntry, 'component');
        record.confidence = devEntry.confidence || 'Cao';
        record.modelSpecific = true;
        record.repairAdvice = `${byModel} — ${loc(devEntry, 'advice')}`;
      } else {
        record.suspectedComponent = loc(devEntry, 'component');
        record.confidence = devEntry.confidence || 'Cao';
        record.repairAdvice = loc(devEntry, 'advice');
      }
      if (devEntry.priority) {
        record.repairAdvice += '\n\n' + t('i2c.order', { p: loc(devEntry, 'priority') });
      }
    } else {
      // Fallback tra theo địa chỉ hex
      const bus = (db.buses || {})[ev.bus];
      const addr = bus && ev.address ? (bus.addresses || {})[ev.address] : null;
      if (addr) {
        const byModel = addr.models && record.product ? addr.models[record.product] : null;
        if (byModel) {
          record.suspectedComponent = t('i2c.suspect', { c: loc(byModel, 'component') });
          record.confidence = byModel.confidence || 'Cao';
          record.modelSpecific = true;
          record.repairAdvice = loc(byModel, 'advice') || loc(addr, 'advice');
        } else {
          record.suspectedComponent = t('i2c.suspectUnverified', { c: loc(addr, 'component') });
          record.confidence = addr.confidence || 'Trung bình';
          record.repairAdvice = t('i2c.addrNote', { a: loc(addr, 'advice') });
        }
      } else {
        record.suspectedComponent = t('i2c.unknownIc', { bus: ev.bus });
        record.confidence = 'Thấp';
      }
    }
  }
}

// ---------------------------------------------------------------------------
// 3. SignatureEngine + SeverityEngine
// ---------------------------------------------------------------------------
function computeSignature(rec) {
  if (rec.missingSensors.length) {
    return 'SMC::' + rec.missingSensors.slice().sort().join(',');
  }
  if (rec.panicFamily === 'I2C' && rec.i2cEvents.length) {
    const e = rec.i2cEvents[0];
    return `I2C::${e.bus}::${e.address || 'noaddr'}::${e.error}`;
  }
  if (rec.logType === 'app_crash') {
    return `AppCrash::${rec.processName || 'unknown'}::${rec.exceptionType || ''}`;
  }
  // Log không phải kernel panic (nhiệt, SpringBoard, watchdog…): phần đầu file
  // chứa id/giờ/đếm riêng từng lần nên không dùng làm chữ ký, gom theo luật.
  if (!rec.panicString && rec.ruleId) {
    return `Rule::${rec.ruleId}::${rec.processName || ''}`;
  }
  let s = rec.panicString || rec.rawText.slice(0, 600);
  s = s.replace(/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/g, 'UUID')
       .replace(/0x[0-9a-fA-F]+/g, 'ADDR')
       .replace(/\b\d{4}-\d{2}-\d{2}[ T][\d:.]+/g, 'TS')
       .replace(/\b\d+\b/g, 'N')
       .replace(/\s+/g, ' ').trim();
  return `${rec.ruleId}::${s.slice(0, 260)}`;
}

const TIER_ORDER = { normal: 0, warning: 1, critical: 2 };

function countInWindow(records, hours) {
  const stamped = records.filter(r => r.timestampMs);
  const unstamped = records.length - stamped.length;
  if (!stamped.length) return records.length;
  const newest = Math.max.apply(null, stamped.map(r => r.timestampMs));
  const cutoff = newest - hours * 3600 * 1000;
  return stamped.filter(r => r.timestampMs >= cutoff).length + unstamped;
}

// severityScore = signatureWeight + recurrenceWeight + subsystemWeight + modelSpecificWeight
function computeSeverity(group) {
  const rule = group.rule || {};
  const base = TIER_ORDER[group.baseSeverity] || 0;
  let score = base * 2;
  score += rule.subsystemWeight || 0;
  const esc = rule.escalateAt || 3;
  if (group.windowCount >= esc) score += 2;
  if (group.windowCount >= esc * 2) score += 1;
  if (group.modelSpecific) score += 1;
  group.score = score;
  if (score >= 5) return 'critical';
  if (score >= 2) return 'warning';
  return 'normal';
}

function groupDiagnosticRecords(records) {
  const map = new Map();
  records.forEach(rec => {
    const sig = computeSignature(rec);
    if (!map.has(sig)) {
      map.set(sig, {
        signature: sig, family: rec.panicFamily, title: rec.title,
        baseSeverity: rec.baseSeverity, rule: rec.rule,
        suspectedComponent: rec.suspectedComponent, repairAdvice: rec.repairAdvice,
        confidence: rec.confidence, modelSpecific: rec.modelSpecific,
        count: 1, windowCount: 1, score: 0,
        latestRecord: rec, allRecords: [rec]
      });
    } else {
      const g = map.get(sig);
      g.count += 1;
      g.allRecords.push(rec);
      if (rec.timestampMs && (!g.latestRecord.timestampMs || rec.timestampMs > g.latestRecord.timestampMs)) {
        g.latestRecord = rec;
      }
      if (rec.modelSpecific) g.modelSpecific = true;
    }
  });

  const list = Array.from(map.values());
  list.forEach(g => {
    const hours = (g.rule && g.rule.windowHours) || 48;
    g.windowCount = countInWindow(g.allRecords, hours);
    g.windowHours = hours;
    g.severity = computeSeverity(g);
  });

  list.sort((a, b) => {
    if (TIER_ORDER[b.severity] !== TIER_ORDER[a.severity]) return TIER_ORDER[b.severity] - TIER_ORDER[a.severity];
    if (b.score !== a.score) return b.score - a.score;
    return b.count - a.count;
  });
  return list;
}

// Ingest and Render logs
function parseAndIngestLogs(rawLogsArray) {
  diagnosticRecords = [];
  logPartSignals = PartsHistory.fromLogs(rawLogsArray);
  rawLogsArray.forEach((item, idx) => {
    const content = typeof item === 'string' ? item : (item.content || item.rawText || "");
    const name = item.name || item.fileName || `log_${idx + 1}.ips`;
    if (content) {
      const parsed = parseLogContent(content, name);
      diagnosticRecords.push(parsed);
    }
  });

  incidentGroups = groupDiagnosticRecords(diagnosticRecords);
  renderPartsHistory();
  updateDashboardStats();
  renderIncidentList();
}

function resetHardwareReport() {
  hardwareReport = null;
  hardwarePartSignals = [];
  renderPartsHistory();
}

// Native gửi báo cáo phần cứng TRƯỚC log, nên kết luận ở onNativeScanMode đã
// tính cả phần cứng.
const HARDWARE_CACHE_KEY = 'panic.hardwareReport';

function loadCachedHardwareReport() {
  try {
    const saved = JSON.parse(localStorage.getItem(HARDWARE_CACHE_KEY) || 'null');
    return saved && saved.model === (window.__DEVICE_MODEL__ || '') ? saved.report : null;
  } catch (_) { return null; }
}

// Sê-ri linh kiện lần trước (theo đời máy) để phát hiện linh kiện bị thay, và
// các linh kiện đã đổi sê-ri (giữ 30 ngày) để tab Linh kiện còn hiện sau đó.
const PARTS_BASELINE_KEY = 'panic.partsBaseline';
const CHANGED_DAYS = 30;
let changedPartsNow = [];

function readStore(key) {
  try { return JSON.parse(localStorage.getItem(key) || 'null'); } catch (_) { return null; }
}
function writeStore(key, value) {
  try { localStorage.setItem(key, JSON.stringify(value)); } catch (_) {}
}

function trackPartChanges(report) {
  const model = window.__DEVICE_MODEL__ || '';
  const saved = readStore(PARTS_BASELINE_KEY);
  const baseline = saved && saved.model === model ? saved : { model, ids: {}, changed: {}, notified: '' };
  const ids = PartsHistory.partIdentities(report);
  const now = Date.now();
  for (const part of PartsHistory.changedParts(baseline.ids, ids)) {
    baseline.changed[part] = { from: baseline.ids[part], to: ids[part], at: now };
  }
  for (const [part, info] of Object.entries(baseline.changed)) {
    if (!info || now - Number(info.at) > CHANGED_DAYS * 86400000) delete baseline.changed[part];
  }
  baseline.ids = Object.assign({}, baseline.ids, ids);
  changedPartsNow = Object.keys(baseline.changed);
  const overview = PartsHistory.partsOverview(report, logPartSignals, model, changedPartsNow);
  const alerts = overview.filter(item => PartsHistory.isAlert(item.status));
  const key = alerts.map(item => item.part + ':' + item.status).join('|');
  if (key && key !== baseline.notified) notifyReplacedParts(alerts);
  baseline.notified = key;
  writeStore(PARTS_BASELINE_KEY, baseline);
}

// Thông báo iOS: "Phát hiện linh kiện đã thay" kèm danh sách.
function notifyReplacedParts(alerts) {
  const list = alerts.map(item => `${t('parts.part.' + item.part)}: ${t('parts.status.' + item.status)}`).join(' · ');
  const bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.nativeBridge;
  if (bridge) bridge.postMessage({ action: 'notifyParts', title: t('parts.alert.title'), body: list });
}

window.onNativeHardwareReport = function(report) {
  const incoming = report && typeof report === 'object' ? report : null;
  hardwareReport = PartsHistory.mergeHardwareReport(hardwareReport || loadCachedHardwareReport(), incoming);
  writeStore(HARDWARE_CACHE_KEY, { model: window.__DEVICE_MODEL__ || '', report: hardwareReport });
  hardwarePartSignals = PartsHistory.fromHardware(hardwareReport);
  trackPartChanges(hardwareReport);
  renderPartsHistory();
};

function renderHardwareReport(host, paragraph) {
  if (!hardwareReport) return;
  const addRow = (label, text, status) => {
    const node = document.createElement('div');
    node.className = 'parts-row';
    const part = document.createElement('b');
    part.textContent = label;
    const detail = document.createElement('span');
    detail.className = 'parts-status' + (status ? ' ' + status : '');
    detail.textContent = text;
    node.append(part, detail);
    host.appendChild(node);
  };
  const overview = PartsHistory.partsOverview(hardwareReport, logPartSignals,
    window.__DEVICE_MODEL__, changedPartsNow);
  const alerts = overview.filter(item => PartsHistory.isAlert(item.status));
  if (alerts.length) {
    const banner = document.createElement('div');
    banner.className = 'parts-alert';
    const title = document.createElement('b');
    title.textContent = t('parts.alert.title');
    const list = document.createElement('span');
    list.textContent = alerts.map(item => t('parts.part.' + item.part)).join(', ');
    banner.append(title, list);
    host.appendChild(banner);
  }
  paragraph(t('parts.overviewTitle'), 'parts-source');
  const battery = hardwareReport.battery || {};
  for (const item of overview) {
    addRow(t('parts.part.' + item.part), overviewText(item), item.status);
    if (item.part === 'battery') {
      const facts = batteryFacts(battery);
      if (facts.length) addRow('', facts.join(' · '), '');
    }
    if (item.part === 'rear_camera' || item.part === 'front_camera' || item.part === 'face_id') {
      const facts = cameraFacts(item.part);
      if (facts.length) addRow('', facts.join(' · '), '');
    }
  }
  if (PartsHistory.cameraModules(hardwareReport).length) paragraph(t('parts.cam.caution'), 'parts-note');
  const authError = hardwarePartSignals.find(f => f.part === 'battery' && f.reason === 'chip');
  if (authError) paragraph(t('parts.hw.batteryAuthError', { n: authError.code || '?' }), 'parts-note parts-error');
  const clue = PartsHistory.capacityClue(battery);
  if (clue) paragraph(t('parts.hw.capacityClue', { p: clue.percent, c: clue.cycles }), 'parts-note parts-error');
  if (Array.isArray(hardwareReport.errors) && hardwareReport.errors.length) {
    paragraph(t('parts.hw.error', { e: String(hardwareReport.errors[0]).slice(0, 200) }), 'parts-note parts-error');
  }
  paragraph(t('parts.hwCaution'));
  renderHardwareRaw(host, paragraph, addRow);
}

// Chữ của một dòng tổng quan: trạng thái + chi tiết ngắn.
function overviewText(item) {
  const support = PartsHistory.authSupport(window.__DEVICE_MODEL__);
  const display = hardwareReport.display || {};
  if (item.status === 'no_flag' && item.part === 'display' && support.display === false) {
    return t(PartsHistory.displaySerial(hardwareReport) ? 'parts.hw.displayWatch' : 'parts.hw.displayNotSupported',
      { s: PartsHistory.displaySerial(hardwareReport) });
  }
  if (item.status === 'no_flag' && item.part === 'battery' && support.battery === false) {
    return t('parts.hw.batteryNotSupported');
  }
  if (item.status === 'working') return t('parts.bio.' + item.detail);
  if (item.status === 'unavailable') return t('parts.bio.not_available');
  if (item.status === 'serial_only') {
    return t(window.__PRIVILEGED__ ? 'parts.status.serial_only' : 'parts.status.serial_onlyIpa', { s: item.serial || '' });
  }
  // Có dữ liệu nhưng iOS không công bố kết quả xác thực trên đời máy này.
  if (item.status === 'no_flag' && item.part === 'battery' && PartsHistory.batteryTrustedOff(hardwareReport)) {
    return t('parts.hw.batteryTrustedOff');
  }
  if (item.status === 'no_flag' && item.part === 'display' && display.panelId) return t('parts.hw.displayNoResult');
  let text = t('parts.status.' + item.status);
  if (item.part === 'display' && display.panelSerial && item.status === 'genuine') text += ` · ${display.panelSerial}`;
  const camera = PartsHistory.cameraCheck(hardwareReport, item.part);
  if ((item.status === 'serial_match' || item.status === 'validated') && camera && camera.current) text += ` · ${camera.current}`;
  if (item.status === 'validation_fail') text = t('parts.status.validation_fail', { v: item.value || '' });
  if (item.status === 'serial_mismatch' && camera && camera.factory && camera.current) {
    text = t('parts.cam.mismatch', { f: camera.factory, c: camera.current });
  }
  if (item.status === 'nongenuine' && item.reason === 'chip') {
    return t('parts.hw.batteryChipNoAnswer', { n: item.code || '?' });
  }
  if (item.status === 'serial_match' && item.part === 'display') text += ` · ${PartsHistory.displaySerial(hardwareReport)}`;
  if (item.status === 'replaced') {
    const sys = (hardwareReport.syscfg || []).find(entry => entry && entry.part === item.part) || {};
    const factory = item.factory || sys.factory;
    const current = item.current || sys.current;
    if (factory && current) return t('parts.sys.mismatch', { f: factory, c: current });
  }
  if (item.factory && item.status !== 'replaced') text += ' · ' + t('parts.sys.factory', { s: item.factory });
  if (item.source === 'log') text += ' ' + t('parts.fromLog');
  return text;
}

// Từng module camera của một dòng: sê-ri đọc được và nguồn của nó, để lần
// sau nhận ra module nào đổi (camera chính đã nằm ở dòng trên).
function cameraFacts(part) {
  const main = { rear_camera: 'rear_main', front_camera: 'front' }[part];
  return PartsHistory.cameraModules(hardwareReport)
    .filter(entry => entry.part === part && entry.module !== main && entry.current)
    .map(entry => `${t('parts.cam.' + entry.module)}: ${entry.current}`)
    .concat(PartsHistory.cameraModules(hardwareReport)
      .filter(entry => entry.part === part && entry.sourcesAgree === false)
      .map(entry => t('parts.cam.sourcesDiffer', { m: t('parts.cam.' + entry.module), a: entry.ioreg, b: entry.gestalt })));
}

function batteryFacts(battery) {
  const facts = [];
  if (Number.isFinite(battery.settingsHealthPercent)) facts.push(t('parts.hw.health', { n: battery.settingsHealthPercent }));
  else if (Number.isFinite(battery.healthPercent)) facts.push(t('parts.hw.healthMeasured', { n: battery.healthPercent }));
  if (Number.isFinite(battery.cycleCount)) facts.push(t('parts.hw.cycles', { n: battery.cycleCount }));
  const capacity = battery.nominalChargeCapacity || battery.fullChargeCapacity;
  if (capacity && battery.designCapacity) facts.push(`${capacity}/${battery.designCapacity} mAh`);
  return facts;
}

// Dữ liệu thô của các node xác thực: không hiện trong app (tên node dài, chỉ
// dành cho iOSVN), chỉ giữ nút gửi để nhận diện đời máy mới.
// Toàn bộ báo cáo phần cứng (kể cả dữ liệu thô của các node) — để iOSVN nhận
// diện đời máy mới.
function hardwarePayload() {
  const report = hardwareReport || {};
  return Object.assign({
    app: window.__APP_VERSION__ || '', web: window.__WEB_BUILD__ || 0, model: window.__DEVICE_MODEL__ || '',
    ios: window.__IOS_VERSION__ || '', privileged: !!window.__PRIVILEGED__
  }, report);
}

// Bảng linh kiện dạng chữ, giống tab Linh kiện.
function hardwareSummaryText() {
  if (!hardwareReport) return t('export.none') + '\n';
  const lines = [];
  for (const item of PartsHistory.partsOverview(hardwareReport, logPartSignals, window.__DEVICE_MODEL__, changedPartsNow)) {
    lines.push(`${t('parts.part.' + item.part)}: ${overviewText(item)}`);
    if (item.part === 'battery') {
      const facts = batteryFacts(hardwareReport.battery || {});
      if (facts.length) lines.push('   ' + facts.join(' · '));
    }
    if (['rear_camera', 'front_camera', 'face_id'].includes(item.part)) {
      const facts = cameraFacts(item.part);
      if (facts.length) lines.push('   ' + facts.join(' · '));
    }
  }
  for (const error of hardwareReport.errors || []) lines.push(t('parts.hw.error', { e: error }));
  return lines.join('\n') + '\n';
}

function renderHardwareRaw(host, paragraph, addRow) {
  const button = document.createElement('button');
  button.className = 'action-btn secondary';
  button.textContent = t('parts.hw.rawShare');
  button.onclick = () => exportTextFile('linh-kien', partsExportText());
  host.appendChild(button);
  const send = document.createElement('button');
  send.className = 'action-btn primary';
  send.textContent = t('btn.sendIosvn');
  send.onclick = () => sendToIosvn('linh-kien', partsExportText);
  host.appendChild(send);
}

function renderPartsHistory() {
  const host = document.getElementById('partsHistoryResults');
  if (!host) return;
  host.replaceChildren();
  const paragraph = (text, className = 'parts-note') => {
    const node = document.createElement('p');
    node.className = className;
    node.textContent = text;
    host.appendChild(node);
  };
  renderHardwareReport(host, paragraph);
  const row = finding => {
    const node = document.createElement('div');
    node.className = 'parts-row';
    const part = document.createElement('b');
    part.textContent = t('parts.part.' + finding.part);
    const detail = document.createElement('span');
    detail.textContent = t('parts.status.' + finding.status)
      + (finding.source === 'log' && finding.file ? ` (${finding.file})` : '');
    detail.className = 'parts-status ' + finding.status;
    node.append(part, detail);
    host.appendChild(node);
  };
  if (logPartSignals.length) {
    paragraph(t('parts.logSource'), 'parts-source');
    logPartSignals.forEach(row);
    paragraph(t('parts.logCaution'));
  }
  const cableClues = PartsHistory.cableClues(diagnosticRecords);
  if (cableClues.length) {
    paragraph(t('parts.cableSource'), 'parts-source');
    for (const clue of cableClues) {
      const node = document.createElement('div');
      node.className = 'parts-row';
      const component = document.createElement('b');
      component.textContent = clue.component;
      const file = document.createElement('span');
      file.className = 'parts-status';
      file.textContent = clue.file;
      node.append(component, file);
      host.appendChild(node);
    }
    paragraph(t('parts.cableCaution'));
  }
}

// ---------------------------------------------------------------------------
// 4. Dashboard Stats & Render
// ---------------------------------------------------------------------------
function updateDashboardStats() {
  let criticalCount = 0;
  let warningCount = 0;
  let normalCount = 0;

  incidentGroups.forEach(g => {
    if (g.severity === 'critical') criticalCount += g.count;
    else if (g.severity === 'warning') warningCount += g.count;
    else normalCount += g.count;
  });

  const elCrit = document.getElementById('statCriticalCount');
  const elWarn = document.getElementById('statWarningCount');
  const elNorm = document.getElementById('statNormalCount');
  const pulse = document.getElementById('statusPulse');

  if (elCrit) elCrit.innerText = criticalCount;
  if (elWarn) elWarn.innerText = warningCount;
  if (elNorm) elNorm.innerText = normalCount;

  if (pulse) {
    if (criticalCount > 0) {
      pulse.classList.add('danger');
    } else {
      pulse.classList.remove('danger');
    }
  }

  // Badge luôn là máy THẬT, không lấy từ log
}

function renderIncidentList() {
  const container = document.getElementById('incidentList');
  const countBadge = document.getElementById('resultsCountBadge');
  if (!container) return;

  let filtered = incidentGroups.filter(g => {
    // Filter by severity chip
    if (currentFilter === 'critical' && g.severity !== 'critical') return false;
    if (currentFilter === 'warning' && g.severity !== 'warning') return false;
    if (currentFilter === 'normal' && g.severity !== 'normal') return false;
    if (currentFilter === 'i2c' && g.family !== 'I2C') return false;
    if (currentFilter === 'smc' && g.family !== 'SMC') return false;
    if (currentFilter === 'apps' && !(g.latestRecord && g.latestRecord.appCrash)) return false;
    if (currentFilter === 'panics' && !(g.latestRecord && g.latestRecord.logType === 'kernel_panic')) return false;

    // Search Query
    if (currentSearchQuery) {
      const q = currentSearchQuery.toLowerCase();
      const match = g.title.toLowerCase().includes(q) ||
                    g.suspectedComponent.toLowerCase().includes(q) ||
                    g.repairAdvice.toLowerCase().includes(q) ||
                    g.family.toLowerCase().includes(q);
      if (!match) return false;
    }
    return true;
  });

  if (countBadge) countBadge.innerText = t('results.count', { n: filtered.length });

  if (filtered.length === 0) {
    container.innerHTML = `
      <div class="empty-state">
        <svg viewBox="0 0 24 24" width="40" height="40" stroke="currentColor" stroke-width="1.5" fill="none" class="empty-icon">
          <circle cx="12" cy="12" r="10"/>
          <line x1="8" y1="12" x2="16" y2="12"/>
        </svg>
        <h4>${t('empty.noMatch')}</h4>
        <p>${t('empty.noMatchHint')}</p>
      </div>
    `;
    return;
  }

  let html = '';
  filtered.forEach((g, idx) => {
    const confClass = g.confidence === 'Cao' ? 'confidence-high' : (g.confidence === 'Trung bình' ? 'confidence-med' : 'confidence-low');
    const freqText = g.windowCount > 1 ? t('card.freqWindow', { n: g.windowCount, h: g.windowHours }) : t('card.freqOnce');
    const rec = g.latestRecord;

    html += `
      <div class="incident-card ${g.severity}" onclick="openDetailModal(${incidentGroups.indexOf(g)})">
        <div class="incident-card-header">
          <div class="incident-title">${escapeHtml(g.title)}</div>
          <span class="freq-badge">${freqText}</span>
        </div>

        <div class="suspect-line">
          <span>${t('card.suspect')}</span>
          <span class="suspect-highlight">${escapeHtml(g.suspectedComponent)}</span>
        </div>
        ${rec.appCrash ? `<div class="suspect-line"><span>${t('crash.reason')}</span><span>${escapeHtml(crashReason(rec.appCrash) || '—')}</span></div>` : ''}

        <div class="time-line">
          <span>${t('card.latest')}</span>
          <b>${formatLogTime(rec.timestampMs)}</b>
          ${rec.timestampMs ? `<span class="time-ago">${formatAgo(rec.timestampMs)}</span>` : ''}
        </div>

        <div class="meta-row">
          <span class="meta-item">${escapeHtml(rec.product || "iPhone")}</span>
          <span class="meta-item">${escapeHtml(rec.build || rec.osVersion || "iOS 15+")}</span>
          <span class="confidence-badge ${confClass}">${t('card.confidence', { c: confLabel(g.confidence) })}</span>
        </div>
      </div>
    `;
  });

  container.innerHTML = html;
}

// ---------------------------------------------------------------------------
// 5. Detail Modal & Sanitize Export
// ---------------------------------------------------------------------------
let selectedGroupIndex = null;

function openDetailModal(index) {
  selectedGroupIndex = index;
  const g = incidentGroups[index];
  if (!g) return;

  const rec = g.latestRecord;
  const modal = document.getElementById('detailModal');
  const modalTitle = document.getElementById('modalTitle');
  const badge = document.getElementById('modalSeverityBadge');
  const body = document.getElementById('modalBody');

  if (modalTitle) modalTitle.innerText = g.title;
  if (badge) {
    badge.className = `badge ${g.severity}`;
    badge.innerText = t('sev.' + g.severity);
  }

  let i2cHtml = '';
  if (rec.i2cEvents && rec.i2cEvents.length > 0) {
    const ev0 = rec.i2cEvents[0];
    const devRow = ev0.deviceName
      ? `<b>${t('d.device')}</b> <span style="color:var(--accent);font-weight:700;">${escapeHtml(ev0.deviceName)}</span><br>` : '';
    const addrRow = ev0.address ? `<b>${t('d.addr')}</b> ${ev0.address}<br>` : '';
    i2cHtml = `
      <div class="detail-section">
        <div class="detail-label">${t('d.i2cTitle')}</div>
        <div class="detail-text">
          <b>Bus:</b> ${ev0.bus}<br>
          ${devRow}${addrRow}
          <b>${t('d.errType')}</b> ${ev0.error}<br>
          <b>${t('d.controller')}</b> ${ev0.controller}
        </div>
      </div>
    `;
  }
  // Hiện reset counter nếu có
  const rcMatch = (rec.panicString || rec.rawText || '').match(/(?:panic count|reset counter)[:\s]+?(\d+)/i);
  const resetCountHtml = rcMatch
    ? `<div class="detail-section"><div class="detail-label">${t('d.resetTitle')}</div><div class="detail-text">${t('d.resetBody', { n: rcMatch[1] })}</div></div>`
    : '';

  const occurrences = sortedOccurrences(g);
  const shown = occurrences.slice(0, 30);
  const timelineRows = shown.map(r => `
      <div class="timeline-row">
        <span class="timeline-time">${formatLogTime(r.timestampMs)}</span>
        <span class="timeline-file">${escapeHtml(r.filename || '')}</span>
      </div>`).join('');
  const stamped = occurrences.filter(r => r.timestampMs);
  const span = stamped.length > 1
    ? t('d.span', { a: formatLogTime(stamped[stamped.length - 1].timestampMs), b: formatLogTime(stamped[0].timestampMs) }) + '<br>'
    : '';
  const timelineHtml = `
      <div class="detail-section">
        <div class="detail-label">${t('d.timeline', { n: occurrences.length })}</div>
        <div class="detail-text">${span}${timelineRows}${occurrences.length > shown.length ? `<div class="timeline-more">${t('d.older', { n: occurrences.length - shown.length })}</div>` : ''}</div>
      </div>`;

  let sensorHtml = '';
  if (rec.missingSensors && rec.missingSensors.length > 0) {
    sensorHtml = `
      <div class="detail-section">
        <div class="detail-label">${t('d.sensorTitle')}</div>
        <div class="detail-text">
          <b>${t('d.sensorCode')}</b> <span style="color:var(--sev-critical); font-weight:700;">${rec.missingSensors.join(', ')}</span>
        </div>
      </div>
    `;
  }

  if (body) {
    body.innerHTML = `
      <div class="detail-section">
        <div class="detail-label">${t('d.suspect')}</div>
        <div class="detail-text" style="font-size:15px; font-weight:600; color:#fff;">
          ${escapeHtml(g.suspectedComponent)}
        </div>
      </div>

      <div class="detail-section">
        <div class="detail-label">${t('d.advice')}</div>
        <div class="detail-text" style="color:var(--text-primary);">
          ${escapeHtml(g.repairAdvice)}
        </div>
      </div>

      ${appCrashHtml(rec.appCrash)}
      ${sensorHtml}
      ${resetCountHtml}
      ${i2cHtml}

      ${timelineHtml}

      <div class="detail-section">
        <div class="detail-label">${t('d.specs')}</div>
        <div class="detail-text">
          <b>${t('d.model')}</b> ${escapeHtml(rec.product)}<br>
          <b>${t('d.os')}</b> ${escapeHtml(rec.osVersion || rec.build || "iOS")}<br>
          <b>${t('d.repeat')}</b> ${t('d.repeatVal', { n: g.count, w: g.windowCount, h: g.windowHours })}<br>
          <b>${t('d.score')}</b> ${g.score}<br>
          <b>${t('d.conf')}</b> ${confLabel(g.confidence)}
        </div>
      </div>

      <div class="detail-section">
        <div class="detail-label">${t('d.raw')}</div>
        <div class="raw-log-block">${escapeHtml(rec.panicString || rec.rawText.substring(0, 1200))}</div>
      </div>
    `;
  }

  const adminBtn = document.getElementById('adminBtn');
  if (adminBtn) adminBtn.style.display = '';

  if (modal) modal.classList.add('open');
}

function appCrashHtml(crash) {
  if (!crash) return '';
  const row = (label, value) => value ? `<b>${label}</b> ${escapeHtml(String(value))}<br>` : '';
  const origin = crash.firstParty === true ? t('crash.app.apple') : (crash.firstParty === false ? t('crash.app.thirdParty') : '');
  return `
      <div class="detail-section">
        <div class="detail-label">${t('crash.info')}</div>
        <div class="detail-text">
          ${row(t('crash.app'), crash.name + (origin ? ` · ${origin}` : ''))}
          ${row('Bundle ID', crash.bundleID)}
          ${row(t('crash.version'), crash.version)}
          ${row(t('crash.time'), crash.time)}
          ${row(t('crash.reason'), crashReason(crash))}
          ${row('Termination', crash.termination)}
          ${row(t('crash.crashedIn'), crash.crashedIn)}
        </div>
      </div>`;
}

function closeDetailModal() {
  const modal = document.getElementById('detailModal');
  if (modal) modal.classList.remove('open');
}

function closeModalOnOverlay(e) {
  if (e.target.id === 'detailModal') closeDetailModal();
}

// Export Sanitized Report (No serial / UDID / Personal Info)
function selectedGroup() {
  return selectedGroupIndex === null ? null : incidentGroups[selectedGroupIndex] || null;
}

// Báo cáo một lỗi: tóm tắt + nguyên văn mọi lần xảy ra (UUID được che).
function logReportText(g) {
  const rec = g.latestRecord;
  // Mọi file gửi đi bắt đầu bằng "PanicAnalyzer" (máy chủ nhận log kiểm tra).
  let report = exportHeader(t('export.logTitle')) + '\n';
  report += `${t('r.device')}: ${rec.product || "iPhone"}\n`;
  report += `${t('r.os')}: ${rec.osVersion || rec.build || "iOS"}\n\n`;
  report += `${t('r.main')}\n`;
  report += ` - ${t('r.title')}: ${g.title}\n`;
  report += ` - ${t('r.sev')}: ${t('sev.' + g.severity)}\n`;
  report += ` - ${t('r.suspect')}: ${g.suspectedComponent}\n`;
  report += ` - ${t('r.conf')}: ${confLabel(g.confidence)}\n`;
  report += ` - ${t('r.freq')}: ${t('r.times', { n: g.count })}\n`;
  report += ` - ${t('r.latest')}: ${formatLogTime(rec.timestampMs)}\n`;
  const times = sortedOccurrences(g).filter(r => r.timestampMs).slice(0, 20)
    .map(r => `   • ${formatLogTime(r.timestampMs)}`).join('\n');
  if (times) report += ` - ${t('r.allTimes')}:\n${times}\n`;
  report += `\n`;
  report += `${t('r.advice')}\n${g.repairAdvice}\n\n`;
  // File .txt: kèm nguyên văn mọi lần xảy ra (UUID được che).
  report += `=== ${t('export.logs')} ===\n` + fullLogsText(sortedOccurrences(g));
  return report;
}

function exportSanitizedReport() {
  const g = selectedGroup();
  if (g) exportTextFile('log', logReportText(g));
}

// ---------------------------------------------------------------------------
// 6. Native File Input Handling
// ---------------------------------------------------------------------------
let scanTimeoutId = null;

// Native side bounds every connection step and reports progress, which
// re-arms this deadline; it only fires if native goes silent.
const SCAN_TIMEOUT_MS = 100000;

function armScanTimeout() {
  clearTimeout(scanTimeoutId);
  scanTimeoutId = setTimeout(() => {
    scanTimeoutId = null;
    showEmptyState();
    updateScanStatus(t('s.timeout'), false);
    setPartsScanState('error', 0, t('s.timeout'));
    showToast(t('s.timeout'), 4500);
  }, SCAN_TIMEOUT_MS);
}
function clearScanTimeout() { clearTimeout(scanTimeoutId); scanTimeoutId = null; }

// Progress lines while native tries LocalDevVPN routes one by one.
window.onNativeScanProgress = function(message) {
  if (message) updateScanStatus(message, true);
  if (scanTimeoutId !== null || partsScanState === 'scanning') armScanTimeout();
};

function triggerFilePicker() {
  if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.nativeBridge) {
    window.webkit.messageHandlers.nativeBridge.postMessage({ action: 'pickFiles' });
    return;
  }
  const input = document.getElementById('nativeFileInput');
  if (input) input.click();
}

window.onNativeScanMode = function(isAutoScan, count, source, summary) {
  clearScanTimeout();
  if (partsScanState === 'error') return;
  if (count > 0) {
    setDemoBanner(false);
    const sourceLabel = t(source === 'pairing' ? 's.src.pairing'
      : (source === 'share' ? 's.src.share' : (source === 'file' ? 's.src.file' : 's.src.device')));
    let status = t('s.analyzed', { n: count, src: sourceLabel });
    // Quá giới hạn một lần quét: nói rõ đã đọc bao nhiêu trong số tìm thấy.
    if (summary && summary.truncated) {
      status += ' ' + t('scan.limited', { r: summary.read, n: summary.found, f: summary.maxFiles, mb: summary.maxMB });
    }
    updateScanStatus(status, false);
    showToast(t('s.readToast', { n: count, src: sourceLabel }), 3000);
  } else {
    showEmptyState();
    if (source === 'pairing') {
      updateScanStatus(t('s.noPairingLogs'), false);
      showToast(t('s.noPairingLogs'), 4000);
    } else if (window.__CAN_READ_LOGS__ || source === 'filesystem') {
      showToast(t('s.noLogsJB'), 4500);
    } else {
      showToast(t('s.sandboxBlocked'), 4500);
    }
  }
  if (isAutoScan && (source === 'pairing' || source === 'filesystem')) {
    const outcome = PartsHistory.assessScan(count, logPartSignals,
      PartsHistory.cableClues(diagnosticRecords), hardwarePartSignals);
    setPartsScanState(outcome, count);
    showToast(t('parts.result.' + outcome + 'Title'), 4500);
  } else if (isAutoScan && source === 'sandbox') {
    setPartsScanState('pairRequired');
  } else if (!isAutoScan) {
    setPartsScanState('idle');
  }
};

function updatePairingButton(configured) {
  const label = document.getElementById('pairingButtonLabel');
  if (label) label.innerText = t(configured ? 'btn.repair' : 'btn.pair');
}

// Máy JB / TrollStore đọc thẳng log nên không cần ghép đôi:
// ẩn nút ghép đôi và gắn nhãn "Đọc trực tiếp" cạnh model.
function applyJailbreakMode() {
  if (!window.__CAN_READ_LOGS__) return;
  const pairBtn = document.getElementById('btnPairing');
  if (pairBtn) pairBtn.style.display = 'none';
  const badge = document.getElementById('detectedModelBadge');
  if (badge && !badge.querySelector('.jb-tag')) {
    const tag = document.createElement('span');
    tag.className = 'jb-tag';
    tag.innerText = t('jb.tag');
    badge.appendChild(document.createTextNode(' '));
    badge.appendChild(tag);
  }
}

window.onNativePairingStatus = function(status) {
  window.__PAIRING_CONFIGURED__ = !!status.configured;
  updatePairingButton(!!status.configured);
  updatePartsPairingRequirement();
  if (status.error) {
    clearScanTimeout();
    if (partsScanState === 'scanning' || partsScanState === 'pairRequired') {
      setPartsScanState('error', 0, status.message);
    }
  } else if (status.configured && partsScanState === 'pairRequired') {
    setPartsScanState('scanning');
    armScanTimeout();
  }
  if (status.message) updateScanStatus(status.message, false);
  showToast(status.error ? `Pairing: ${status.message}` : `✓ ${status.message}`,
    status.error ? 6000 : 4000);
};


function handleNativeFileSelect(event) {
  const files = event.target.files;
  if (!files || files.length === 0) return;

  const readPromises = Array.from(files).map(file => {
    return new Promise((resolve) => {
      const reader = new FileReader();
      reader.onload = (e) => resolve({ name: file.name, content: e.target.result });
      reader.readAsText(file);
    });
  });

  Promise.all(readPromises).then(results => {
    updateScanStatus(t('s.imported', { n: results.length }), false);
    setPartsScanState('idle');
    parseAndIngestLogs(results);
  });
}

// ---------------------------------------------------------------------------
// 7. Search & Filter Handlers
// ---------------------------------------------------------------------------
function setChipFilter(type) {
  currentFilter = type;
  document.querySelectorAll('.filter-chip').forEach(btn => {
    if (btn.dataset.filter === type) btn.classList.add('active');
    else btn.classList.remove('active');
  });
  renderIncidentList();
}

function filterBySeverity(type) {
  setChipFilter(type);
}

function handleSearch(e) {
  currentSearchQuery = e.target.value.trim();
  const clearBtn = document.getElementById('btnClearSearch');
  if (clearBtn) clearBtn.style.display = currentSearchQuery ? 'block' : 'none';
  renderIncidentList();
}

function clearSearch() {
  const input = document.getElementById('searchInput');
  if (input) input.value = '';
  currentSearchQuery = '';
  document.getElementById('btnClearSearch').style.display = 'none';
  renderIncidentList();
}

// ---------------------------------------------------------------------------
// 8. Sample Logs Library
// ---------------------------------------------------------------------------
function openSampleLogsModal() {
  const modal = document.getElementById('sampleModal');
  if (modal) modal.classList.add('open');
}

function closeSampleModal() {
  const modal = document.getElementById('sampleModal');
  if (modal) modal.classList.remove('open');
}

function closeSampleModalOnOverlay(e) {
  if (e.target.id === 'sampleModal') closeSampleModal();
}

function populateSampleLogsModal() {
  const container = document.getElementById('sampleListContainer');
  if (!container || !ruleDatabases.sample_logs) return;

  let html = '';
  ruleDatabases.sample_logs.forEach((s, idx) => {
    html += `
      <div class="sample-item" onclick="loadSingleSample(${idx})">
        <div class="sample-item-title">${escapeHtml(s.type)}</div>
        <div class="sample-item-desc">${escapeHtml(s.name)}</div>
      </div>
    `;
  });
  container.innerHTML = html;
}

function loadSingleSample(idx) {
  const s = ruleDatabases.sample_logs[idx];
  if (!s) return;
  closeSampleModal();
  setPartsScanState('idle');
  parseAndIngestLogs([s]);
  setDemoBanner(true);
  updateScanStatus(t('s.viewingSample', { t: s.type }), false);
}

function escapeHtml(str) {
  if (!str) return '';
  return String(str)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

// Docs Modal Handlers




// ---------------------------------------------------------------------------
// 8. Bộ luật tải từ kho công khai + gửi log khó cho admin
// ---------------------------------------------------------------------------
const DB_FILES = ['panic_rules', 'i2c_rules', 'sensor_database', 'model_database', 'sample_logs'];

function rulesCount() {
  const r = ruleDatabases.panic_rules;
  return Array.isArray(r) ? r.length : 0;
}

function renderRulesInfo(info) {
  const el = document.getElementById('rulesInfo');
  if (!el) return;
  const src = (info && info.source) || 'bundle';
  const label = t('rules.' + (src === 'remote' || src === 'cache' ? src : 'bundle'));
  const when = info && info.updatedAt ? ` · ${info.updatedAt}` : '';
  el.innerHTML = `<span>${t('rules.info', { n: rulesCount(), label: label, when: when })}</span>`
    + `<button class="link-btn" onclick="refreshRulesNow()">${t('btn.update')}</button>`;
}

// Toast thông báo nhẹ ở đáy màn hình
function showToast(msg, durationMs) {
  let t = document.getElementById('appToast');
  if (!t) {
    t = document.createElement('div');
    t.id = 'appToast';
    t.style.cssText = [
      'position:fixed;bottom:calc(env(safe-area-inset-bottom,0px) + 72px)',
      'left:50%;transform:translateX(-50%)',
      'background:rgba(30,30,32,0.92);color:#f0f0f0;border:1px solid rgba(255,150,40,0.3)',
      'padding:10px 20px;border-radius:20px;font-size:14px;font-weight:500',
      'pointer-events:none;z-index:9999;max-width:90vw;text-align:center',
      'transition:opacity .3s;backdrop-filter:blur(8px)'
    ].join(';');
    document.body.appendChild(t);
  }
  t.innerText = msg;
  t.style.opacity = '1';
  clearTimeout(t._to);
  t._to = setTimeout(() => { t.style.opacity = '0'; }, durationMs || 3000);
}

function refreshRulesNow() {
  const el = document.getElementById('rulesInfo');
  if (el) el.innerHTML = `<span>${t('rules.loading')}</span>`;
  if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.nativeBridge) {
    window.webkit.messageHandlers.nativeBridge.postMessage({ action: 'refreshRules' });
  } else {
    renderRulesInfo(window.__RULES_INFO__);
  }
}

// Native gọi lại sau khi tải xong bộ luật
window.onNativeRulesUpdated = function (info) {
  if (window.__NATIVE_DB__) {
    for (const f of DB_FILES) {
      if (window.__NATIVE_DB__[f]) ruleDatabases[f] = window.__NATIVE_DB__[f];
    }
  }
  renderRulesInfo(info);
  if (info && info.changed) {
    reanalyzeStoredLogs();
    showToast(t('rules.updated', { n: rulesCount() }), 3500);
  } else {
    showToast(t('rules.latest', { n: rulesCount() }), 2500);
  }
};

// Phân tích lại các log đang giữ bằng bộ luật mới
function reanalyzeStoredLogs() {
  if (!diagnosticRecords.length) return;
  const raw = diagnosticRecords.map(r => ({ name: r.filename, content: r.rawText }));
  parseAndIngestLogs(raw);
}

// Log nào chưa tra được thì mời gửi cho admin
const UNRESOLVED_RULE_IDS = ['unknown-log', 'kernel-panic-unknown', 'kernel-data-abort'];

function needsAdminHelp(g) {
  if (!g) return false;
  const rec = g.latestRecord || {};
  return UNRESOLVED_RULE_IDS.includes(rec.ruleId) || g.confidence === 'Thấp';
}

function buildAdminReport(g) {
  const rec = g.latestRecord || {};
  const unknown = t('admin.unknown');
  let txt = `PANIC ANALYZER - iOSVN\n`;
  txt += `${t('admin.device')}: ${rec.product || window.__DEVICE_MODEL__ || unknown}\n`;
  txt += `iOS: ${rec.osVersion || rec.build || unknown}\n`;
  txt += `${t('admin.detected')}: ${g.title} (${t('admin.rule')}: ${rec.ruleId || t('admin.noRule')})\n`;
  txt += `${t('r.conf')}: ${confLabel(g.confidence)} · ${t('r.times', { n: g.count })}\n`;
  txt += `${t('admin.rules', { n: rulesCount() })}\n\n`;
  txt += `--- panicString ---\n`;
  txt += (rec.panicString || (rec.rawText || '').substring(0, 1500));
  return txt;
}

function sendToAdmin() {
  const g = selectedGroup();
  if (g) sendToIosvn('log', () => logReportText(g));
}


// ---------------------------------------------------------------------------
// 9. Báo có bản ứng dụng mới
// ---------------------------------------------------------------------------
let appUpdateInfo = null;

window.onNativeAppUpdate = function (info) {
  if (!info) { showToast(t('upd.latest'), 2500); return; }
  if (!info.version) { showToast(t('upd.latest'), 2500); return; }
  appUpdateInfo = info;
  const el = document.getElementById('updateBanner');
  if (!el) return;
  const notes = info.notes ? `<span>${escapeHtml(info.notes)}</span>` : '';
  el.innerHTML = t('upd.available', { v: escapeHtml(info.version) })
    + `<span>${t('upd.current', { v: escapeHtml(info.current || window.__APP_VERSION__ || '') })}</span>`
    + notes;
  el.style.display = '';
};

// Bản sửa giao diện (web/) đã tải xong: dùng từ lần mở sau, hoặc ngay khi bấm.
window.onWebUpdateReady = function (build) {
  if (document.getElementById('webUpdateBanner')) return;
  const el = document.createElement('div');
  el.id = 'webUpdateBanner';
  el.className = 'notice-banner';
  const text = document.createElement('span');
  text.textContent = t('webupd.ready');
  const apply = document.createElement('button');
  apply.className = 'link-btn';
  apply.textContent = t('webupd.apply');
  apply.onclick = () => postNative({ action: 'applyWebUpdate' }) || el.remove();
  el.append(text, apply);
  el.dataset.build = String(build || '');
  document.body.appendChild(el);
};

// ---- Xuất file .txt -------------------------------------------------------
const EXPORT_LIMIT_BYTES = 20 * 1024 * 1024;
const UUID_PATTERN = /[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/g;

function exportStamp() {
  const d = new Date();
  const p = n => String(n).padStart(2, '0');
  return `${window.__DEVICE_MODEL__ || 'iPhone'}-${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}-${p(d.getHours())}${p(d.getMinutes())}`;
}

// "iPhone 14 Pro Max (iPhone15,3)": tên thương mại kèm mã máy.
function deviceLabel() {
  const id = window.__DEVICE_MODEL__ || '';
  const name = (ruleDatabases.model_database || {})[id];
  return name && name !== id ? `${name} (${id})` : (id || '?');
}

function exportHeader(title) {
  return [
    `PanicAnalyzer — ${title}`,
    `${t('export.app')}: ${window.__APP_VERSION__ || '?'} · web ${window.__WEB_BUILD__ || 0}`
      + ` · ${window.__PRIVILEGED__ ? 'TrollStore/JB' : 'IPA'}`,
    `${t('export.device')}: ${deviceLabel()} · iOS ${window.__IOS_VERSION__ || '?'}`,
    `${t('r.exported')}: ${new Date().toLocaleString(dateLocale())}`
  ].join('\n') + '\n';
}

// Nguyên văn các log (UUID được che), dừng ở giới hạn dung lượng.
function fullLogsText(records) {
  let out = '';
  let size = 0;
  const list = Array.isArray(records) ? records : [];
  for (let i = 0; i < list.length; i++) {
    const rec = list[i];
    const raw = String(rec.rawText || '').replace(UUID_PATTERN, '<UUID>');
    const block = `\n--- ${i + 1}/${list.length} · ${rec.filename || ''} · ${formatLogTime(rec.timestampMs)} ---\n${raw}\n`;
    if (size + block.length > EXPORT_LIMIT_BYTES) {
      out += `\n${t('export.truncated', { n: list.length - i, mb: EXPORT_LIMIT_BYTES / 1048576 })}\n`;
      break;
    }
    out += block;
    size += block.length;
  }
  return out || t('export.none') + '\n';
}

// Mở bảng chia sẻ với file .txt (bản app mới); bản cũ chia sẻ dạng chữ.
function exportTextFile(kind, text) {
  const name = `PanicAnalyzer-${kind}-${exportStamp()}.txt`;
  if (Number(window.__NATIVE_API__ || 1) >= 2 && postNative({ action: 'shareFile', name, text })) return;
  if (postNative({ action: 'shareText', text })) return;
  if (navigator.clipboard) navigator.clipboard.writeText(text).then(() => showToast(t('r.copied'), 2500)).catch(() => {});
}

// Mọi thứ app đang có: máy, linh kiện, kết quả phân tích, nguyên văn log.
function exportAllData() {
  exportTextFile('toan-bo', allDataText());
}

function partsExportText() {
  return exportHeader(t('export.partsTitle'))
    + `\n=== ${t('export.parts')} ===\n` + hardwareSummaryText()
    + `\n=== ${t('export.raw')} ===\n` + JSON.stringify(hardwarePayload(), null, 2) + '\n';
}

function allDataText() {
  let text = exportHeader(t('export.allTitle'));
  text += `\n=== ${t('export.parts')} ===\n` + hardwareSummaryText();
  text += `\n=== ${t('export.incidents')} (${incidentGroups.length}) ===\n`;
  if (!incidentGroups.length) text += t('export.none') + '\n';
  for (const g of incidentGroups) {
    const rec = g.latestRecord || {};
    text += `\n• [${t('sev.' + g.severity)}] ${g.title}\n`
      + `  ${t('r.suspect')}: ${g.suspectedComponent} · ${t('r.conf')}: ${confLabel(g.confidence)} · ${t('r.times', { n: g.count })}\n`
      + `  ${t('r.latest')}: ${formatLogTime(rec.timestampMs)} · ${rec.filename || ''}\n`;
    if (rec.appCrash) text += `  ${t('crash.reason')} ${crashReason(rec.appCrash)}\n`;
  }
  const crashes = Array.isArray(window.__APP_CRASHES__) ? window.__APP_CRASHES__ : [];
  if (crashes.length) text += `\n=== ${t('export.ownCrashes')} ===\n` + appCrashReport(crashes);
  text += `\n=== ${t('export.raw')} ===\n` + JSON.stringify(hardwarePayload(), null, 2) + '\n';
  const records = diagnosticRecords.slice().sort((a, b) => (b.timestampMs || 0) - (a.timestampMs || 0));
  text += `\n=== ${t('export.logs')} (${records.length}) ===\n` + fullLogsText(records);
  return text;
}

// ---- Gửi thẳng cho iOSVN qua Telegram ----------------------------------------
// App gửi file lên máy chủ của iOSVN, máy chủ chuyển vào Telegram của iOSVN. Chưa có máy chủ hoặc bản app cũ:
// mở bảng chia sẻ file như nút Xuất.
const REPORT_URL = 'https://report.iosvn.com.vn/report.php';
const REPORT_CONTACT_KEY = 'panic.reportContact';

function canSendReport() {
  return !!REPORT_URL && Number(window.__NATIVE_API__ || 1) >= 3;
}

function sendToIosvn(kind, buildText) {
  if (!canSendReport()) {
    exportTextFile(kind, buildText());
    return;
  }
  openReportDialog(kind, buildText);
}

function closeReportDialog() {
  const old = document.getElementById('reportDialog');
  if (old) old.remove();
}

function openReportDialog(kind, buildText) {
  closeReportDialog();
  const overlay = document.createElement('div');
  overlay.id = 'reportDialog';
  overlay.className = 'modal-overlay open';
  overlay.innerHTML = `
    <div class="modal-card report-card">
      <div class="modal-header">
        <div class="modal-title-wrap"><h3>${escapeHtml(t('report.title'))}</h3></div>
        <button class="modal-close-btn" data-close>&times;</button>
      </div>
      <div class="modal-body">
        <p class="settings-hint">${escapeHtml(t('report.hint'))}</p>
        <label class="report-label" for="reportNote">${escapeHtml(t('report.note'))}</label>
        <textarea class="report-input" id="reportNote" rows="3" maxlength="600"></textarea>
        <label class="report-label" for="reportContact">${escapeHtml(t('report.contact'))}</label>
        <input class="report-input" id="reportContact" maxlength="80" autocomplete="off" placeholder="@telegram">
      </div>
      <div class="modal-footer">
        <button class="btn btn-outline" data-close>${escapeHtml(t('report.cancel'))}</button>
        <button class="btn btn-primary" id="reportSend">${escapeHtml(t('report.send'))}</button>
      </div>
    </div>`;
  document.body.appendChild(overlay);
  const contact = overlay.querySelector('#reportContact');
  try { contact.value = localStorage.getItem(REPORT_CONTACT_KEY) || ''; } catch (_) {}
  overlay.querySelectorAll('[data-close]').forEach(node => { node.onclick = closeReportDialog; });
  overlay.onclick = event => { if (event.target === overlay) closeReportDialog(); };
  const send = overlay.querySelector('#reportSend');
  send.onclick = () => {
    const text = buildText();
    const note = overlay.querySelector('#reportNote').value.trim();
    try { localStorage.setItem(REPORT_CONTACT_KEY, contact.value.trim()); } catch (_) {}
    send.disabled = true;
    send.textContent = t('report.sending');
    window.onReportSent = result => {
      window.onReportSent = null;
      closeReportDialog();
      if (result && result.ok) {
        showToast(t('report.sent'), 3500);
      } else {
        showToast(t('report.failed', { e: (result && result.error) || '?' }), 4500);
        exportTextFile(kind, text);
      }
    };
    postNative({
      action: 'sendReport', url: REPORT_URL, name: `PanicAnalyzer-${kind}-${exportStamp()}.txt`, text, note,
      contact: contact.value.trim(),
      meta: { app: window.__APP_VERSION__ || '', web: window.__WEB_BUILD__ || 0, model: deviceLabel(),
        ios: window.__IOS_VERSION__ || '', build: window.__PRIVILEGED__ ? 'TrollStore/JB' : 'IPA', kind }
    });
  };
}

function postNative(message) {
  const bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.nativeBridge;
  if (!bridge) return false;
  bridge.postMessage(message);
  return true;
}

// PanicAnalyzer bị dừng ở lần mở trước (native tự ghi lại): mời gửi iOSVN.
function appCrashReport(crashes) {
  let text = `PanicAnalyzer crash · app ${window.__APP_VERSION__ || '?'} · web ${window.__WEB_BUILD__ || 0}`
    + ` · ${window.__DEVICE_MODEL__ || '?'} · iOS ${window.__IOS_VERSION__ || '?'}\n`;
  for (const crash of crashes) {
    text += `\n=== ${crash.time || ''} · ${crash.kind || ''} · ${crash.title || ''}\n${crash.text || ''}\n`;
  }
  return text;
}

function showAppCrashes() {
  const crashes = Array.isArray(window.__APP_CRASHES__) ? window.__APP_CRASHES__ : [];
  if (!crashes.length || document.getElementById('appCrashBanner')) return;
  const el = document.createElement('div');
  el.id = 'appCrashBanner';
  el.className = 'notice-banner crash';
  const text = document.createElement('span');
  text.innerHTML = `<b>${escapeHtml(t('crash.title'))}</b> ${escapeHtml(t('crash.body'))}`;
  const send = document.createElement('button');
  send.className = 'link-btn';
  send.textContent = t('crash.send');
  send.onclick = () => {
    sendToIosvn('crash', () => appCrashReport(crashes));
    postNative({ action: 'clearAppCrashes' });
    el.remove();
  };
  const dismiss = document.createElement('button');
  dismiss.className = 'link-btn muted';
  dismiss.textContent = t('crash.dismiss');
  dismiss.onclick = () => { postNative({ action: 'clearAppCrashes' }); el.remove(); };
  el.append(text, send, dismiss);
  document.body.appendChild(el);
}

function openAppUpdate() {
  const url = (appUpdateInfo && appUpdateInfo.url)
    || 'https://github.com/iOSVNNews/PanicAnalyzer-iOSVN/releases/latest';
  if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.nativeBridge) {
    window.webkit.messageHandlers.nativeBridge.postMessage({ action: 'openURL', url: url });
  } else {
    window.open(url, '_blank');
  }
}
