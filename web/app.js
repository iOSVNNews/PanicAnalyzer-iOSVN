/**
 * PANIC ANALYZER - iOS Hardware Diagnostic Engine
 * 100% Client-side & On-Device Analysis
 */

// Global State
let diagnosticRecords = [];
let incidentGroups = [];
let currentFilter = 'all';
let currentSearchQuery = '';
let ruleDatabases = {
  panic_rules: [],
  i2c_rules: {},
  sensor_database: {},
  model_database: {},
  sample_logs: []
};

// Initialize app
document.addEventListener('DOMContentLoaded', async () => {
  await loadDatabases();
  updateDetectedModel();
  updatePairingButton(!!window.__PAIRING_CONFIGURED__);

  const hasBridge = !!(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.nativeBridge);
  if (hasBridge && (window.__CAN_READ_LOGS__ || window.__PAIRING_CONFIGURED__ || window.__AUTO_PAIRING__)) {
    updateScanStatus(window.__PAIRING_CONFIGURED__
      ? "Đang kết nối CrashReporter qua pairing..."
      : (window.__AUTO_PAIRING__
        ? "Đang tự ghép đôi qua LocalDevVPN..."
        : "Đang đọc log hệ thống..."), true);
    armScanTimeout();
    try {
      window.webkit.messageHandlers.nativeBridge.postMessage({ action: 'autoScanLogs' });
    } catch (e) {
      clearScanTimeout();
      showEmptyState();
    }
  } else {
    showEmptyState();
  }
});

// Trạng thái rỗng - KHÔNG BAO GIỜ hiện dữ liệu giả như thể là log máy người dùng
function showEmptyState() {
  diagnosticRecords = [];
  incidentGroups = [];
  setDemoBanner(false);
  updateDashboardStats();
  renderIncidentList();
  updateScanStatus(SANDBOX_HINT, false);
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
  el.innerText = 'DỮ LIỆU MẪU \u2014 đây KHÔNG phải log của máy bạn, chỉ để xem thử giao diện.';
  list.parentNode.insertBefore(el, list);
}

// Nạp TẤT CẢ log mẫu - chỉ chạy khi người dùng chủ động bấm
function loadAllSamples() {
  const all = ruleDatabases.sample_logs || [];
  if (!all.length) return;
  closeSampleModal();
  parseAndIngestLogs(all);
  setDemoBanner(true);
  updateScanStatus(`Đang xem ${all.length} log MẪU (không phải máy bạn).`, false);
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
    updateScanStatus("Lỗi đọc log từ hệ thống.", false);
    showToast('Đọc log thất bại — thử nạp file thủ công', 4000);
  }
};

// Trigger Auto-Scan manually
function triggerAutoScan() {
  if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.nativeBridge) {
    updateScanStatus("Đang kiểm tra log hệ thống...", true);
    armScanTimeout();
    window.webkit.messageHandlers.nativeBridge.postMessage({ action: 'autoScanLogs' });
  } else {
    showEmptyState();
  }
}

function triggerPairingImport() {
  if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.nativeBridge) {
    updateScanStatus('Đang ghép đôi trên thiết bị qua LocalDevVPN...', true);
    armScanTimeout();
    window.webkit.messageHandlers.nativeBridge.postMessage({ action: 'pairDevice' });
    return;
  }
  showToast('Tính năng pairing chỉ có trong ứng dụng iOS.', 3500);
}

function triggerVPNSettings() {
  if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.nativeBridge) {
    window.webkit.messageHandlers.nativeBridge.postMessage({ action: 'vpnSettings' });
    return;
  }
  showToast('Cấu hình LocalDevVPN chỉ có trong ứng dụng iOS.', 3500);
}

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
    badge.innerText = 'Chế độ xem trước';
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

function normalizeI2CError(m) {
  if (!m) return 'không rõ';
  const raw = m[1].toLowerCase();
  if (/stuck|checkbusstatus|bus busy/.test(raw)) return 'bus kẹt (SCL/SDA giữ mức thấp)';
  if (/nack/.test(raw)) return 'NACK (thiết bị không phản hồi)';
  if (/timeout|timed ?out/.test(raw)) return 'timeout';
  if (/arbitration/.test(raw)) return 'mất quyền điều khiển bus';
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
    confidence: "Thấp", title: "Log chẩn đoán iOS",
    suspectedComponent: "Chưa xác định",
    repairAdvice: "Xem thông tin kỹ thuật trong raw log.",
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

  // CHỈ khớp luật trong panicString + panicInitiator + 4KB đầu file.
  // Quét cả file (có thể >1MB stackshot) gây dương tính giả nghiêm trọng:
  // chuỗi "ANS"/"nvme" nằm trong danh sách tiến trình của MỌI log.
  const matchText = [record.panicString, record.panicInitiator, rawText.slice(0, 4096)].join("\n");
  const text = matchText;

  // FileClassifier
  if (record.bugType === "210" || /panic\(/.test(record.panicString) || filename.includes("panic-full")) {
    record.logType = "kernel_panic";
  } else if (record.bugType === "309" || /watchdog/i.test(text)) {
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
  return record;
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
    title: 'Kernel Panic chưa phân loại', suspected: 'Cần đọc chi tiết raw log',
    subsystem: 'Kernel', advice: 'Mở "Thông tin kỹ thuật" để xem panicString và backtrace.',
    confidence: 'Thấp' },
  unknown: { id: 'unknown-log', family: 'Unknown', baseSeverity: 'normal',
    subsystemWeight: 0, escalateAt: 10, windowHours: 24,
    title: 'Log chẩn đoán thông thường', suspected: 'Không xác định',
    subsystem: 'Diagnostics', advice: 'Không có dấu hiệu lỗi phần cứng rõ ràng.',
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
  record.title = hit.title;
  record.suspectedComponent = hit.suspected;
  record.repairAdvice = hit.advice;
  record.confidence = hit.confidence || 'Trung bình';

  // Làm giàu: cảm biến SMC
  if (record.missingSensors.length) {
    const s = record.missingSensors[0];
    const info = (ruleDatabases.sensor_database || {})[s];
    record.title = `SMC Panic - Thiếu cảm biến ${record.missingSensors.join(', ')}`;
    if (info) {
      record.suspectedComponent = `${info.name} (${info.location})`;
      record.repairAdvice = `${info.meaning}. Khuyến nghị: ${info.action}.`;
      record.confidence = 'Cao';
      record.modelSpecific = true;
    } else {
      record.suspectedComponent = `Cảm biến ${s} trên cụm cáp ngoại vi`;
      record.confidence = 'Trung bình';
    }
  }

  // Làm giàu: I2C — ưu tiên tra theo tên thiết bị (ad5860, roswell…), sau đó mới theo địa chỉ hex
  if (record.i2cEvents.length && record.panicFamily === 'I2C') {
    const ev = record.i2cEvents[0];
    const db = ruleDatabases.i2c_rules || {};
    const devLabel = ev.deviceName
      ? ` (thiết bị: ${ev.deviceName})`
      : (ev.address ? ` @ ${ev.address}` : '');
    record.title = `Lỗi I2C - ${ev.bus}${devLabel} (${ev.error})`;

    // Tra theo tên thiết bị trước (độ chính xác cao hơn địa chỉ hex)
    const devEntry = ev.deviceName ? ((db.device_names || {})[ev.deviceName]) : null;
    if (devEntry) {
      const byModel = devEntry.models && record.product ? devEntry.models[record.product] : null;
      if (byModel) {
        record.suspectedComponent = `${devEntry.component}`;
        record.confidence = devEntry.confidence || 'Cao';
        record.modelSpecific = true;
        record.repairAdvice = `${byModel} — ${devEntry.advice}`;
      } else {
        record.suspectedComponent = devEntry.component;
        record.confidence = devEntry.confidence || 'Cao';
        record.repairAdvice = devEntry.advice;
      }
      if (devEntry.priority) {
        record.repairAdvice += `\n\nThứ tự kiểm tra: ${devEntry.priority}`;
      }
    } else {
      // Fallback tra theo địa chỉ hex
      const bus = (db.buses || {})[ev.bus];
      const addr = bus && ev.address ? (bus.addresses || {})[ev.address] : null;
      if (addr) {
        const byModel = addr.models && record.product ? addr.models[record.product] : null;
        if (byModel) {
          record.suspectedComponent = `Nghi ngờ: ${byModel.component}`;
          record.confidence = byModel.confidence || 'Cao';
          record.modelSpecific = true;
          record.repairAdvice = byModel.advice || addr.advice;
        } else {
          record.suspectedComponent = `Nghi ngờ: ${addr.component} (chưa xác minh cho model này)`;
          record.confidence = addr.confidence || 'Trung bình';
          record.repairAdvice = `${addr.advice} Lưu ý: cùng địa chỉ có thể là linh kiện khác trên đời máy khác.`;
        }
      } else {
        record.suspectedComponent = `IC ngoại vi trên bus ${ev.bus} (chưa xác định)`;
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
  rawLogsArray.forEach((item, idx) => {
    const content = typeof item === 'string' ? item : (item.content || item.rawText || "");
    const name = item.name || item.fileName || `log_${idx + 1}.ips`;
    if (content) {
      const parsed = parseLogContent(content, name);
      diagnosticRecords.push(parsed);
    }
  });

  incidentGroups = groupDiagnosticRecords(diagnosticRecords);
  updateDashboardStats();
  renderIncidentList();
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

  if (countBadge) countBadge.innerText = `${filtered.length} cụm lỗi`;

  if (filtered.length === 0) {
    container.innerHTML = `
      <div class="empty-state">
        <svg viewBox="0 0 24 24" width="40" height="40" stroke="currentColor" stroke-width="1.5" fill="none" class="empty-icon">
          <circle cx="12" cy="12" r="10"/>
          <line x1="8" y1="12" x2="16" y2="12"/>
        </svg>
        <h4>Không tìm thấy lỗi phù hợp</h4>
        <p>Thử đổi bộ lọc hoặc xóa ô tìm kiếm.</p>
      </div>
    `;
    return;
  }

  let html = '';
  filtered.forEach((g, idx) => {
    const confClass = g.confidence === 'Cao' ? 'confidence-high' : (g.confidence === 'Trung bình' ? 'confidence-med' : 'confidence-low');
    const freqText = g.windowCount > 1 ? `${g.windowCount} lần / ${g.windowHours} giờ` : `1 lần phát hiện`;
    const rec = g.latestRecord;

    html += `
      <div class="incident-card ${g.severity}" onclick="openDetailModal(${idx})">
        <div class="incident-card-header">
          <div class="incident-title">${escapeHtml(g.title)}</div>
          <span class="freq-badge">${freqText}</span>
        </div>

        <div class="suspect-line">
          <span>Nghi ngờ:</span>
          <span class="suspect-highlight">${escapeHtml(g.suspectedComponent)}</span>
        </div>

        <div class="meta-row">
          <span class="meta-item">${escapeHtml(rec.product || "iPhone")}</span>
          <span class="meta-item">${escapeHtml(rec.build || rec.osVersion || "iOS 15+")}</span>
          <span class="confidence-badge ${confClass}">Độ tin cậy: ${g.confidence}</span>
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
    badge.innerText = g.severity === 'critical' ? 'NGHIÊM TRỌNG' : (g.severity === 'warning' ? 'CẦN THEO DÕI' : 'BÌNH THƯỜNG');
  }

  let i2cHtml = '';
  if (rec.i2cEvents && rec.i2cEvents.length > 0) {
    const ev0 = rec.i2cEvents[0];
    const devRow = ev0.deviceName
      ? `<b>Thiết bị:</b> <span style="color:var(--accent);font-weight:700;">${escapeHtml(ev0.deviceName)}</span><br>` : '';
    const addrRow = ev0.address ? `<b>Địa chỉ Hex:</b> ${ev0.address}<br>` : '';
    i2cHtml = `
      <div class="detail-section">
        <div class="detail-label">Thông tin giao tiếp I2C phát hiện</div>
        <div class="detail-text">
          <b>Bus:</b> ${ev0.bus}<br>
          ${devRow}${addrRow}
          <b>Loại lỗi:</b> ${ev0.error}<br>
          <b>Bộ điều khiển:</b> ${ev0.controller}
        </div>
      </div>
    `;
  }
  // Hiện reset counter nếu có
  const rcMatch = (rec.panicString || rec.rawText || '').match(/(?:panic count|reset counter)[:\s]+?(\d+)/i);
  const resetCountHtml = rcMatch
    ? `<div class="detail-section"><div class="detail-label">Số lần panic gần đây</div><div class="detail-text">Máy đã ghi nhận <b>${rcMatch[1]}</b> lần panic (theo bộ đếm của hệ thống)</div></div>`
    : '';

  let sensorHtml = '';
  if (rec.missingSensors && rec.missingSensors.length > 0) {
    sensorHtml = `
      <div class="detail-section">
        <div class="detail-label">Cảm biến nhiệt / áp suất bị mất tín hiệu</div>
        <div class="detail-text">
          <b>Mã cảm biến:</b> <span style="color:var(--sev-critical); font-weight:700;">${rec.missingSensors.join(', ')}</span>
        </div>
      </div>
    `;
  }

  if (body) {
    body.innerHTML = `
      <div class="detail-section">
        <div class="detail-label">Thành phần phần cứng nghi ngờ</div>
        <div class="detail-text" style="font-size:15px; font-weight:600; color:#fff;">
          ${escapeHtml(g.suspectedComponent)}
        </div>
      </div>

      <div class="detail-section">
        <div class="detail-label">Khuyến nghị kỹ thuật & Sửa chữa</div>
        <div class="detail-text" style="color:var(--text-primary);">
          ${escapeHtml(g.repairAdvice)}
        </div>
      </div>

      ${sensorHtml}
      ${resetCountHtml}
      ${i2cHtml}

      <div class="detail-section">
        <div class="detail-label">Thông số thiết bị & Tần suất</div>
        <div class="detail-text">
          <b>Model thiết bị:</b> ${escapeHtml(rec.product)}<br>
          <b>Hệ điều hành / Build:</b> ${escapeHtml(rec.osVersion || rec.build || "iOS")}<br>
          <b>Số lần lặp lại:</b> ${g.count} lần (${g.windowCount} lần trong ${g.windowHours} giờ)<br>
          <b>Điểm mức độ:</b> ${g.score}<br>
          <b>Độ tin cậy chẩn đoán:</b> ${g.confidence}
        </div>
      </div>

      <div class="detail-section">
        <div class="detail-label">Thông tin kỹ thuật (Raw Log Trích đoạn)</div>
        <div class="raw-log-block">${escapeHtml(rec.panicString || rec.rawText.substring(0, 1200))}</div>
      </div>
    `;
  }

  const adminBtn = document.getElementById('adminBtn');
  if (adminBtn) adminBtn.style.display = needsAdminHelp(g) ? '' : 'none';

  if (modal) modal.classList.add('open');
}

function closeDetailModal() {
  const modal = document.getElementById('detailModal');
  if (modal) modal.classList.remove('open');
}

function closeModalOnOverlay(e) {
  if (e.target.id === 'detailModal') closeDetailModal();
}

// Export Sanitized Report (No serial / UDID / Personal Info)
function exportSanitizedReport() {
  if (selectedGroupIndex === null) return;
  const g = incidentGroups[selectedGroupIndex];
  if (!g) return;

  const rec = g.latestRecord;
  let report = `=== BÁO CÁO CHẨN ĐOÁN PANIC ANALYZER (IOSVN) ===\n`;
  report += `Thời gian xuất: ${new Date().toLocaleString('vi-VN')}\n`;
  report += `Thiết bị: ${rec.product || "iPhone"}\n`;
  report += `Hệ điều hành: ${rec.osVersion || rec.build || "iOS"}\n\n`;
  report += `1. CHẨN ĐOÁN CHÍNH:\n`;
  report += ` - Tiêu đề: ${g.title}\n`;
  report += ` - Mức độ: ${g.severity.toUpperCase()}\n`;
  report += ` - Linh kiện nghi ngờ: ${g.suspectedComponent}\n`;
  report += ` - Độ tin cậy: ${g.confidence}\n`;
  report += ` - Tần suất xuất hiện: ${g.count} lần\n\n`;
  report += `2. HƯỚNG DẪN XỬ LÝ:\n${g.repairAdvice}\n\n`;
  report += `3. RAW LOG (ĐÃ SANITIZE):\n`;
  
  // Sanitize raw text
  let safeRaw = rec.panicString || rec.rawText.substring(0, 800);
  safeRaw = safeRaw.replace(/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/g, '<UUID>');
  report += safeRaw;

  // If in native iOS, trigger UIActivityViewController
  if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.nativeBridge) {
    window.webkit.messageHandlers.nativeBridge.postMessage({
      action: 'shareText',
      text: report
    });
  } else {
    // Web copy to clipboard or download file
    navigator.clipboard.writeText(report).then(() => {
      alert("Đã sao chép báo cáo chẩn đoán (Sanitized) vào bộ nhớ tạm!");
    }).catch(() => {
      alert("Báo cáo:\n\n" + report);
    });
  }
}

// ---------------------------------------------------------------------------
// 6. Native File Input Handling
// ---------------------------------------------------------------------------
let scanTimeoutId = null;
const SANDBOX_HINT = 'Chưa có log. Cách nhanh nhất: mở log trong Dữ liệu phân tích, bấm Chia sẻ '
  + '\u2192 PanicAnalyzer. Trên iOS 27, bật LocalDevVPN để app tự ghép đôi và quét CrashReporter.';

function armScanTimeout() {
  clearTimeout(scanTimeoutId);
  scanTimeoutId = setTimeout(() => {
    showEmptyState();
    showToast('Kết nối quá thời gian — kiểm tra LocalDevVPN rồi thử lại.', 4500);
  }, 45000);
}
function clearScanTimeout() { clearTimeout(scanTimeoutId); scanTimeoutId = null; }

function triggerFilePicker() {
  if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.nativeBridge) {
    window.webkit.messageHandlers.nativeBridge.postMessage({ action: 'pickFiles' });
    return;
  }
  const input = document.getElementById('nativeFileInput');
  if (input) input.click();
}

window.onNativeScanMode = function(isAutoScan, count, source) {
  clearScanTimeout();
  if (count > 0) {
    setDemoBanner(false);
    const sourceLabel = source === 'pairing' ? 'qua pairing'
      : (source === 'share' ? 'từ Share Sheet' : (source === 'file' ? 'từ tệp' : 'từ máy'));
    updateScanStatus(`Đã phân tích ${count} log thật ${sourceLabel}.`, false);
    showToast(`✓ Đọc được ${count} file log ${sourceLabel}`, 3000);
  } else {
    showEmptyState();
    if (source === 'pairing') {
      showToast('Không tìm thấy crash report qua pairing.', 4000);
    } else {
      showToast('iOS sandbox chặn đọc trực tiếp — hãy dùng Chia sẻ hoặc pairing.', 4500);
    }
  }
};

function updatePairingButton(configured) {
  const label = document.getElementById('pairingButtonLabel');
  if (label) label.innerText = configured
    ? 'Kết nối lại thiết bị này'
    : 'Ghép đôi thiết bị này';
}

window.onNativePairingStatus = function(status) {
  clearScanTimeout();
  updatePairingButton(!!status.configured);
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
    updateScanStatus(`Đã nhập và phân tích ${results.length} file .ips thành công!`, false);
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
  parseAndIngestLogs([s]);
  setDemoBanner(true);
  updateScanStatus(`Đang xem 1 log MẪU: ${s.type} (không phải máy bạn).`, false);
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
  const label = src === 'remote' ? 'đã cập nhật' : (src === 'cache' ? 'bản đã tải' : 'bản dựng sẵn');
  const when = info && info.updatedAt ? ` · ${info.updatedAt}` : '';
  el.innerHTML = `<span>Bộ luật: ${rulesCount()} lỗi · ${label}${when}</span>`
    + `<button class="link-btn" onclick="refreshRulesNow()">Cập nhật</button>`;
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
  if (el) el.innerHTML = '<span>Đang tải bộ luật mới…</span>';
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
    showToast(`✓ Bộ luật đã cập nhật — ${rulesCount()} lỗi`, 3500);
  } else {
    showToast('Đang dùng bộ luật mới nhất (' + rulesCount() + ' lỗi)', 2500);
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
  let t = `PANIC ANALYZER - iOSVN\n`;
  t += `Máy: ${rec.product || window.__DEVICE_MODEL__ || 'không rõ'}\n`;
  t += `iOS: ${rec.osVersion || rec.build || 'không rõ'}\n`;
  t += `Nhận diện: ${g.title} (luật: ${rec.ruleId || 'không khớp'})\n`;
  t += `Độ tin cậy: ${g.confidence} · ${g.count} lần\n`;
  t += `Bộ luật: ${rulesCount()} lỗi\n\n`;
  t += `--- panicString ---\n`;
  t += (rec.panicString || (rec.rawText || '').substring(0, 1500));
  return t;
}

function sendToAdmin() {
  if (selectedGroupIndex === null) return;
  const g = incidentGroups[selectedGroupIndex];
  if (!g) return;
  const report = buildAdminReport(g);
  try {
    if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(report);
  } catch (e) { /* bỏ qua */ }
  const url = window.__ADMIN_TELEGRAM__ || 'https://t.me/longdzqua';
  if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.nativeBridge) {
    window.webkit.messageHandlers.nativeBridge.postMessage({ action: 'openURL', url: url });
  } else {
    window.open(url, '_blank');
  }
}


// ---------------------------------------------------------------------------
// 9. Báo có bản ứng dụng mới
// ---------------------------------------------------------------------------
let appUpdateInfo = null;

window.onNativeAppUpdate = function (info) {
  if (!info) { showToast('Đang dùng bản mới nhất', 2500); return; }
  if (!info.version) { showToast('Đang dùng bản mới nhất', 2500); return; }
  appUpdateInfo = info;
  const el = document.getElementById('updateBanner');
  if (!el) return;
  const notes = info.notes ? `<span>${escapeHtml(info.notes)}</span>` : '';
  el.innerHTML = `Đã có bản ${escapeHtml(info.version)} — chạm để tải`
    + `<span>Bạn đang dùng bản ${escapeHtml(info.current || window.__APP_VERSION__ || '')}</span>`
    + notes;
  el.style.display = '';
};

function openAppUpdate() {
  const url = (appUpdateInfo && appUpdateInfo.url)
    || 'https://github.com/iOSVNNews/PanicAnalyzer-iOSVN/releases/latest';
  if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.nativeBridge) {
    window.webkit.messageHandlers.nativeBridge.postMessage({ action: 'openURL', url: url });
  } else {
    window.open(url, '_blank');
  }
}
