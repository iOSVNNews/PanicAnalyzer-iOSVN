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

// Không còn API đọc ảnh/OCR.
assert.equal(typeof PartsHistory.fromSettings, 'undefined');

console.log('Parts history: log-only signals, cautious, no OCR — passed');
