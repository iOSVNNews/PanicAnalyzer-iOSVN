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
console.log('Parts history: explicit Settings labels and cautious log signals passed');
