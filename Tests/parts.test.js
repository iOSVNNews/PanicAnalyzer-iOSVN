const assert = require('node:assert/strict');
const PartsHistory = require('../web/parts.js');

// fromLogs đọc dấu hiệu linh kiện TỪ LOG THIẾT BỊ (không dùng ảnh/OCR).
// Cùng dòng ưu tiên; dòng kế chỉ dùng khi không phải một part khác.
const logs = PartsHistory.fromLogs([
  // Triệu chứng panic KHÔNG được tính là "đã thay linh kiện".
  { name: 'panic-full.ips', content: 'DCP display timing element\nBattery voltage unknown\n' },
  // File lịch sử linh kiện: cả file là ngữ cảnh xác thực.
  { name: 'parts_history.ips', content: 'Display: Unknown\nBattery: Genuine\n' },
  // Nhãn "Unknown Part" ngay trên dòng là ngữ cảnh đủ dù tên file trung tính.
  { name: 'other.ips', content: 'Front Camera: Unknown Part\n' },
  // Nhãn không chính hãng.
  { name: 'analytics.ips', content: 'Battery non-genuine part detected\n' }
]);
assert.deepEqual(logs.map(({ part, status }) => [part, status]), [
  ['display', 'unknown'], ['battery', 'genuine'], ['front_camera', 'unknown'], ['battery', 'nongenuine']
]);
assert.ok(logs.every(f => f.source === 'log'));

// Không có ngữ cảnh xác thực -> không nhận (tránh dương tính giả).
assert.deepEqual(
  PartsHistory.fromLogs([{ name: 'crash.ips', content: 'display driver started\nbattery level low\n' }]),
  []);

// Serial mismatch + genuine trên máy JB đọc thẳng.
const jb = PartsHistory.fromLogs([
  { name: 'com.apple.MobileGestalt.log', content: 'display serial mismatch\ntouch id genuine apple part\n' }
]);
assert.deepEqual(jb.map(({ part, status }) => [part, status]), [
  ['display', 'serial_mismatch'], ['touch_id', 'genuine']
]);

// cableClues: chỉ gợi ý cáp/socket, KHÔNG khẳng định đã thay.
const cable = PartsHistory.cableClues([
  { filename: 'panic.ips', panicFamily: 'SMC', missingSensors: ['Prs0'],
    suspectedComponent: 'Cáp cổng sạc', confidence: 'Trung bình' },
  { filename: 'watchdog.ips', panicFamily: 'Watchdog', missingSensors: [], i2cEvents: [],
    suspectedComponent: 'Cáp cổng sạc' },
  { filename: 'i2c.ips', panicFamily: 'I2C', i2cEvents: [{}],
    suspectedComponent: 'Socket màn hình', confidence: 'Thấp' }
]);
assert.deepEqual(cable.map(item => item.file), ['panic.ips', 'i2c.ips']);

assert.equal(PartsHistory.assessScan(0, [], []), 'noLogs');
assert.equal(PartsHistory.assessScan(3, logs, []), 'found');
assert.equal(PartsHistory.assessScan(3, [], cable), 'cable');
assert.equal(PartsHistory.assessScan(3, [], []), 'noEvidence');

// fromHardware: chỉ nhận cờ thiết bị tự khai; số liệu pin không phải trạng thái.
assert.deepEqual(PartsHistory.fromHardware(null), []);
assert.deepEqual(PartsHistory.fromHardware({ battery: { serial: 'F8Y', cycleCount: 412 } }), []);
const hwPass = PartsHistory.fromHardware({ display: { authPassed: true, panelSerial: 'G9N123' } });
assert.deepEqual(hwPass.map(({ part, status, source }) => [part, status, source]), [['display', 'genuine', 'hardware']]);
const hwFail = PartsHistory.fromHardware({
  display: { authPassed: false },
  battery: { serial: 'X', authFlags: { BatteryAuthenticated: 0 } }
});
assert.deepEqual(hwFail.map(({ part, status }) => [part, status]), [['display', 'authfail'], ['battery', 'authfail']]);
assert.equal(PartsHistory.assessScan(3, [], [], hwPass), 'verified');
assert.equal(PartsHistory.assessScan(0, [], [], hwPass), 'verified');
assert.equal(PartsHistory.assessScan(3, [], [], hwFail), 'found');
assert.equal(PartsHistory.assessScan(3, logs, [], hwPass), 'found');
assert.equal(PartsHistory.assessScan(3, [], cable, []), 'cable');

// Đời máy: XS Max có xác thực pin, không có xác thực màn hình; SE 2 như vậy.
assert.deepEqual(PartsHistory.authSupport('iPhone11,6'), { display: false, battery: true });
assert.deepEqual(PartsHistory.authSupport('iPhone12,8'), { display: false, battery: true });
assert.deepEqual(PartsHistory.authSupport('iPhone10,6'), { display: false, battery: false });
assert.deepEqual(PartsHistory.authSupport('iPhone18,2'), { display: true, battery: true });
assert.deepEqual(PartsHistory.authSupport('iPad8,1'), { display: null, battery: null });

// Dung lượng vượt thiết kế sau nhiều chu kỳ (XS Max pin thay: 3307/3156, 471 chu kỳ).
assert.deepEqual(PartsHistory.capacityClue({ designCapacity: 3156, fullChargeCapacity: 3307, cycleCount: 471 }),
  { percent: 104.8, cycles: 471 });
assert.equal(PartsHistory.capacityClue({ designCapacity: 3156, fullChargeCapacity: 3200, cycleCount: 20 }), null);
assert.equal(PartsHistory.capacityClue({ designCapacity: 3156, fullChargeCapacity: 2900, cycleCount: 471 }), null);
const clue = PartsHistory.fromHardware({ battery: { designCapacity: 3156, fullChargeCapacity: 3307, cycleCount: 471 } });
assert.deepEqual(clue.map(({ part, status }) => [part, status]), [['battery', 'capacity_anomaly']]);
assert.equal(PartsHistory.assessScan(100, [], [], clue), 'found');

// Cờ auth-passed tìm theo thuộc tính trên node bất kỳ (dò không theo tên).
const scanned = PartsHistory.fromHardware({
  display: {},
  parts: [{ part: 'display', authPassed: true, path: 'device-tree/arm-io/x-display' },
          { part: 'battery', authPassed: false, path: 'device-tree/y-battery' },
          { part: 'rear_camera', authPassed: true, path: 'device-tree/rear-cam' }],
  battery: { authFlags: { authenticated: 1 } }
});
assert.deepEqual(scanned.map(({ part, status }) => [part, status]),
  [['display', 'genuine'], ['battery', 'authfail'], ['rear_camera', 'genuine']]);
assert.equal(PartsHistory.assessScan(10, [], [], scanned), 'found');

// Driver AppleBatteryAuth: cờ Pass là kết luận; lỗi chip xác thực là dấu hiệu riêng.
const trusted = PartsHistory.fromHardware({ battery: { auth: { driver: true, passed: false, commError: 2 } } });
assert.deepEqual(trusted.map(({ part, status }) => [part, status]), [['battery', 'authfail']]);
const trustedOk = PartsHistory.fromHardware({ battery: { auth: { passed: true }, authFlags: { authenticated: 0 } } });
assert.deepEqual(trustedOk.map(({ status }) => status), ['genuine']);
const chipError = PartsHistory.fromHardware({ battery: { serial: 'F8Y', auth: { driver: true, commError: 2 } } });
assert.deepEqual(chipError.map(({ part, status, code }) => [part, status, code]), [['battery', 'auth_error', 2]]);
assert.equal(PartsHistory.assessScan(0, [], [], chipError), 'found');
assert.deepEqual(PartsHistory.fromHardware({ battery: { auth: { driver: true } } }), []);

// Lần đọc hỏng không làm mất số liệu của lần đọc trước.
const good = { display: { authPassed: true }, battery: { serial: 'F8Y', settingsHealthPercent: 89, auth: { passed: true } },
  parts: [{ part: 'display', authPassed: true }], raw: [{ name: 'x', props: {} }], probe: { hits: 1 } };
const failed = PartsHistory.mergeHardwareReport(good, { errors: ['D1 diagnostics_relay: timeout'] });
assert.equal(failed.display.authPassed, true);
assert.equal(failed.battery.settingsHealthPercent, 89);
assert.deepEqual(failed.errors, ['D1 diagnostics_relay: timeout']);
const partial = PartsHistory.mergeHardwareReport(good, { battery: { serial: 'F8Y', cycleCount: 626 } });
assert.equal(partial.battery.settingsHealthPercent, 89);
assert.equal(partial.battery.cycleCount, 626);
assert.equal(PartsHistory.mergeHardwareReport(null, good), good);

// Cờ pass trên driver Face ID / loa… được báo như linh kiện khác.
const comps = PartsHistory.fromHardware({ components: [
  { part: 'face_id', nodes: 4, authPassed: true, path: 'Root/ApplePearlSEPDriver' },
  { part: 'speaker', nodes: 3 },
  { part: 'touch_id', nodes: 2, authPassed: false } ] });
assert.deepEqual(comps.map(({ part, status }) => [part, status]), [['face_id', 'genuine'], ['touch_id', 'authfail']]);

// Face ID bị iOS tắt và sê-ri khác sê-ri gốc SysCfg là dấu hiệu linh kiện.
const local = PartsHistory.fromHardware({
  biometrics: { part: 'face_id', state: 'not_available', code: -6 },
  syscfg: [{ part: 'battery', key: 'Batt', factory: 'F8Y111', current: 'ABC999', match: false },
           { part: 'touch_id', key: 'NSrN', factory: '0A0B0C0D', current: '0A0B0C0D', match: true },
           { part: 'rear_camera', key: 'BCMS', factory: 'DN8XYZ' }] });
assert.deepEqual(local.map(({ part, status }) => [part, status]), [['face_id', 'unavailable'], ['battery', 'replaced']]);
assert.equal(PartsHistory.assessScan(0, [], [], local), 'found');
assert.deepEqual(PartsHistory.fromHardware({ biometrics: { part: 'face_id', state: 'not_enrolled' } }), []);
// Báo cáo tại chỗ (Face ID/SysCfg) và báo cáo pairing ghép vào nhau.
const mergedLocal = PartsHistory.mergeHardwareReport(good, { biometrics: { part: 'face_id', state: 'ok' } });
assert.equal(mergedLocal.display.authPassed, true);
assert.equal(mergedLocal.biometrics.state, 'ok');
assert.equal(mergedLocal.errors, undefined);
const mergedPair = PartsHistory.mergeHardwareReport(mergedLocal, { display: { authPassed: false }, errors: ['x'] });
assert.equal(mergedPair.biometrics.state, 'ok');
assert.equal(mergedPair.display.authPassed, false);

// Tổng quan: mỗi linh kiện một dòng, bằng chứng mạnh nhất thắng.
const iphone17 = { display: { authPassed: true, panelSerial: 'G9N1' },
  battery: { serial: 'FG9A', auth: { driver: true, passed: true, passKey: 'BatteryAuthPassed' } },
  biometrics: { part: 'face_id', state: 'ok' } };
const view = PartsHistory.partsOverview(iphone17, [], 'iPhone18,2');
assert.deepEqual(view.map(({ part, status }) => [part, status]), [
  ['display', 'genuine'], ['battery', 'genuine'], ['face_id', 'working'],
  ['rear_camera', 'no_flag'], ['front_camera', 'no_flag'], ['speaker', 'not_authenticated']]);
assert.equal(view.filter(item => PartsHistory.isAlert(item.status)).length, 0);
assert.equal(PartsHistory.expectedParts('iPhone12,8')[2], 'touch_id');
// Pin chính hãng nhưng khác sê-ri gốc → Đã thay; log báo camera "unknown part".
const swapped = PartsHistory.partsOverview(
  { battery: { auth: { passed: true } }, syscfg: [{ part: 'battery', factory: 'AAA111', current: 'BBB222', match: false }] },
  [{ part: 'rear_camera', status: 'unknown', source: 'log' }], 'iPhone11,6');
assert.deepEqual(swapped.filter(item => PartsHistory.isAlert(item.status)).map(item => [item.part, item.status]),
  [['battery', 'replaced'], ['rear_camera', 'unknown']]);
// Sê-ri khác lần kiểm tra trước → "Đã thay đổi".
const ids = PartsHistory.partIdentities(iphone17);
assert.deepEqual(ids, { display: 'G9N1', battery: 'FG9A' });
assert.deepEqual(PartsHistory.changedParts({ display: 'G9N1', battery: 'OLD9' }, ids), ['battery']);
assert.deepEqual(PartsHistory.changedParts(null, ids), []);
assert.equal(PartsHistory.partsOverview(iphone17, [], 'iPhone18,2', ['battery'])[1].status, 'changed');

// Không còn API đọc ảnh/OCR.
assert.equal(typeof PartsHistory.fromSettings, 'undefined');

console.log('Parts history: log-only signals, cautious, no OCR — passed');
