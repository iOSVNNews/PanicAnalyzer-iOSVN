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

// Không còn API đọc ảnh/OCR.
assert.equal(typeof PartsHistory.fromSettings, 'undefined');

console.log('Parts history: log-only signals, cautious, no OCR — passed');
