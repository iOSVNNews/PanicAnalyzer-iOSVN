const assert = require('node:assert/strict');
const PartsHistory = require('../web/parts.js');

const vietnamese = PartsHistory.fromSettings([
  'Giới thiệu', 'Lịch sử linh kiện và dịch vụ',
  'Màn hình', 'Không xác định', 'Pin Chính hãng',
  'Camera trước', 'Đã qua sử dụng'
]);
assert.equal(vietnamese.sectionFound, true);
assert.deepEqual(vietnamese.findings.map(({ part, status }) => [part, status]), [
  ['display', 'unknown'], ['battery', 'genuine'], ['front_camera', 'used']
]);

const english = PartsHistory.fromSettings([
  'Parts & Service History', 'Logic Board', 'Unverified', 'Rear Camera', 'Finish Repair'
]);
assert.deepEqual(english.findings.map(({ part, status }) => [part, status]), [
  ['logic_board', 'unverified'], ['rear_camera', 'finish_repair']
]);

assert.deepEqual(PartsHistory.fromSettings(['Settings', 'Battery', 'Genuine']),
  { sectionFound: false, findings: [] });
assert.deepEqual(PartsHistory.fromSettings(['Parts and Service History', 'Display', 'Battery', 'Genuine'])
  .findings.map(({ part, status }) => [part, status]), [['battery', 'genuine']]);

const unknownBatteryDetail = PartsHistory.fromSettings([
  'Linh kiện không xác định',
  'Không thể xác định xem pin iPhone của bạn có',
  'phải là linh kiện Apple chính hãng hay không.',
  'Việc này có thể do linh kiện không chính hãng',
  'hoặc không hoạt động như dự kiến.',
  'Tìm hiểu thêm về linh kiện và sửa chữa...'
]);
assert.deepEqual(unknownBatteryDetail, { sectionFound: true,
  findings: [{ part: 'battery', status: 'unknown', source: 'settings' }] });
assert.deepEqual(PartsHistory.fromSettings([
  'Linh kiện', 'không xác định',
  'Không thể xác định xem màn hình iPhone của bạn có phải là',
  'linh kiện Apple chính hãng hay không.'
]).findings.map(({ part, status }) => [part, status]), [['display', 'unknown']]);
assert.deepEqual(PartsHistory.fromSettings([
  'Unknown Part', 'Unable to verify this iPhone has a genuine Apple battery.'
]).findings.map(({ part, status }) => [part, status]), [['battery', 'unknown']]);
assert.deepEqual(PartsHistory.fromSettings([
  'Unknown Part', 'Battery level is unknown', 'Learn more about Apple parts'
]), { sectionFound: true, findings: [] });

const logs = PartsHistory.fromLogs([
  { name: 'panic-full.ips', content: 'DCP display timing element\nBattery voltage unknown\n' },
  { name: 'parts_history.ips', content: 'Display: Unknown\nBattery: Genuine\n' },
  { name: 'other.ips', content: 'Front Camera: Unknown Part\n' }
]);
assert.deepEqual(logs.map(({ part, status }) => [part, status]), [
  ['display', 'unknown'], ['battery', 'genuine'], ['front_camera', 'unknown']
]);
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
console.log('Parts history: explicit Settings labels and cautious log signals passed');
