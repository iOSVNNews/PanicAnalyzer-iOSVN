// The Linh kiện tab for reports of several iPhone generations: every row
// renders, nothing is invented, and "not published" never reads as an error.
// The iPhone 14 Pro Max report is a real one (iOS 27, app 2.9).
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

function element(tag) {
  return {
    tag, style: {}, children: [], className: '', textContent: '', innerHTML: '', dataset: {},
    append(...items) { this.children.push(...items); }, appendChild(item) { this.children.push(item); },
    replaceChildren() { this.children = []; }, remove() {}, classList: { add() {}, remove() {} }
  };
}

function load(model, privileged) {
  const host = element('div');
  const posted = [];
  const context = {
    console, setTimeout, clearTimeout, navigator: { language: 'vi' },
    localStorage: { data: {}, getItem(k) { return this.data[k] || null; }, setItem(k, v) { this.data[k] = v; } },
    document: {
      addEventListener() {}, getElementById: id => (id === 'partsHistoryResults' ? host : null),
      querySelector: () => null, querySelectorAll: () => [], createElement: element, documentElement: {},
      body: element('body')
    },
    webkit: { messageHandlers: { nativeBridge: { postMessage: m => posted.push(m) } } },
    __DEVICE_MODEL__: model, __PRIVILEGED__: privileged
  };
  context.window = context;
  vm.createContext(context);
  for (const file of ['i18n.js', 'parts.js', 'app.js']) {
    vm.runInContext(fs.readFileSync(path.join(__dirname, '..', 'web', file), 'utf8'), context, { filename: file });
  }
  return { context, host, posted };
}

const text = node => [node.textContent, ...(node.children || []).map(text)].filter(Boolean).join(' | ');

function render(model, report, privileged = false) {
  const page = load(model, privileged);
  page.context.onNativeHardwareReport(report);
  const rows = page.host.children.map(text);
  const overview = vm.runInContext('PartsHistory', page.context)
    .partsOverview(report, [], model, []);
  return { rows, status: Object.fromEntries(overview.map(item => [item.part, item.status])), posted: page.posted };
}

// iPhone 14 Pro Max, iOS 27 — as sent by app 2.9 build 59.
const iphone14 = {
  display: { panelId: 'GVC31971YGZ14YFAK+A2CH343K26A118111K10' },
  battery: { healthPercent: 79.1, fullChargeCapacity: 3397, cycleCount: 1317, designCapacity: 4297,
    nominalChargeCapacity: 3265, serial: 'F5D3266045420J8A5', auth: { driver: true }, settingsHealthPercent: 75 },
  parts: [],
  components: [{ part: 'face_id', nodes: 6 }, { part: 'camera', nodes: 3 }],
  biometrics: { part: 'face_id', state: 'ok' },
  syscfg: [],
  cameras: [
    { module: 'back', expected: true, active: false, serial: 'DN83156CUMN1CDK2U', node: 'AppleH13CamIn' },
    { module: 'back_depth', expected: true, active: false },
    { module: 'back_super_wide', expected: true, active: false, serial: 'DNL32163BAJ15FY1X' },
    { module: 'back_tele', expected: true, active: false, serial: 'GCF320245WL1CY057' },
    { module: 'front', expected: true, active: false, serial: 'GCF31712HJU1CXC37' },
    { module: 'front_ir', expected: true, active: false, serial: 'HNQ3191058P15F81B' }],
  cameraSerials: [],
  cameraValidation: { FCClValidationStatus: 'Pass', CmPMValidationStatus: 'Invalid', CmClValidationStatus: 'Pass' },
  raw: [{ name: 'AppleBatteryAuth', props: { PackIndex: '0', TrustedBatteryEnabled: '0' } }],
  errors: []
};
let r = render('iPhone15,3', iphone14);
assert.deepEqual(r.status, { display: 'no_flag', battery: 'no_flag', face_id: 'working',
  rear_camera: 'validated', front_camera: 'validated', speaker: 'not_authenticated' });
assert.ok(r.rows.some(row => row.includes('Màn hình') && row.includes('chưa thấy kết quả xác thực')), r.rows.join('\n'));
assert.ok(r.rows.some(row => row.includes('Dung lượng tối đa 75%') && row.includes('1317 chu kỳ')));
// Build 59 sends TrustedBatteryEnabled only in the raw data: still explained.
assert.ok(r.rows.some(row => row.includes('Pin') && row.includes('TrustedBatteryEnabled = 0')), r.rows.join('\n'));
assert.ok(r.rows.some(row => row.includes('Camera sau') && row.includes('Chính hãng') && row.includes('DN83156CUMN1CDK2U')));
assert.ok(r.rows.some(row => row.includes('Góc siêu rộng: DNL32163BAJ15FY1X') && row.includes('Tele: GCF320245WL1CY057')));
assert.ok(r.rows.some(row => row.includes('Camera hồng ngoại TrueDepth: HNQ3191058P15F81B')));
// CmPM "Invalid" belongs to no known module: no alert, no notification.
assert.ok(!r.rows.some(row => row.includes('Có linh kiện đã thay')), r.rows.join('\n'));
assert.equal(r.posted.filter(m => m.action === 'notifyParts').length, 0);

// Same phone with the next native build: trusted battery data reported off,
// projector and LiDAR serials.
const iphone14next = Object.assign({}, iphone14, {
  battery: Object.assign({}, iphone14.battery, { auth: { driver: true, trustedEnabled: false } }),
  cameras: iphone14.cameras.concat([
    { module: 'front_ir_structured_light', serial: 'A227C700044012480' }, { module: 'lidar', serial: 'HNQ31934U82Q7PX1D' }])
});
r = render('iPhone15,3', iphone14next);
assert.ok(r.rows.some(row => row.includes('Pin') && row.includes('TrustedBatteryEnabled = 0')), r.rows.join('\n'));
assert.ok(r.rows.some(row => row.includes('LiDAR: HNQ31934U82Q7PX1D')));
assert.ok(r.rows.some(row => row.includes('Máy chiếu điểm TrueDepth: A227C700044012480')));

// Camera data iOS rejects → alert and notification.
r = render('iPhone15,3', Object.assign({}, iphone14, { cameraValidation: { CmClValidationStatus: 'Fail' } }));
assert.equal(r.status.rear_camera, 'validation_fail');
assert.equal(r.posted.filter(m => m.action === 'notifyParts').length, 1);

// iPhone 17 Pro Max (iPhone18,2): display and battery both authenticated.
r = render('iPhone18,2', {
  display: { authPassed: true, panelSerial: 'G9N1234567890ABCDE', node: 'mogul-display' },
  battery: { serial: 'F1', cycleCount: 12, auth: { driver: true, trustedEnabled: true, passed: true } },
  biometrics: { part: 'face_id', state: 'ok' },
  cameras: [{ module: 'back', serial: 'DNL3375372Z1V6P4V' }]
});
assert.equal(r.status.display, 'genuine');
assert.equal(r.status.battery, 'genuine');
assert.equal(r.status.rear_camera, 'serial_only');
assert.ok(r.rows.some(row => row.includes('chỉ đọc được ở bản TrollStore/JB')));

// iPhone 11 (iPhone12,1): roswell failed → display not genuine.
r = render('iPhone12,1', { display: { authPassed: false, node: 'roswell' }, battery: { cycleCount: 300 } });
assert.equal(r.status.display, 'authfail');

// iPhone XS (iPhone11,2): Apple has no display check on this model; the
// battery auth chip does not answer.
r = render('iPhone11,2', { display: { panelId: 'C0K123456789ABCDE+XYZ' }, battery: { cycleCount: 900, auth: { driver: true, commError: 3 } } });
assert.equal(r.status.display, 'no_flag');
assert.ok(r.rows.some(row => row.includes('Apple không xác thực màn hình') && row.includes('C0K123456789ABCDE')), r.rows.join('\n'));
// Battery auth chip does not answer → not genuine.
assert.equal(r.status.battery, 'nongenuine');
assert.ok(r.rows.some(row => row.includes('Không chính hãng') && row.includes('không phản hồi (mã 3)')), r.rows.join('\n'));
// Same XS on the TrollStore build: panel serial vs the factory LCM#.
r = render('iPhone11,2', { display: { panelId: 'C0K123456789ABCDE+XYZ' },
  syscfg: [{ part: 'display', key: 'LCM#', factory: 'C0K123456789ABCDE' }] }, true);
assert.equal(r.status.display, 'serial_match');
r = render('iPhone11,2', { display: { panelId: 'F7X000000000000AA+XYZ' },
  syscfg: [{ part: 'display', key: 'LCM#', factory: 'C0K123456789ABCDE' }] }, true);
assert.equal(r.status.display, 'replaced');
assert.ok(r.rows.some(row => row.includes('Đã thay') && row.includes('C0K123456789ABCDE') && row.includes('F7X000000000000AA')), r.rows.join('\n'));

// iPhone SE (2nd gen, iPhone12,8): Touch ID row, no display check.
r = render('iPhone12,8', { biometrics: { part: 'touch_id', state: 'ok' } });
assert.equal(r.status.touch_id, 'working');
assert.equal(r.status.face_id, undefined);

// TrollStore build: fitted camera serial differs from the factory one → replaced.
r = render('iPhone15,3', Object.assign({}, iphone14, {
  cameraSerials: [{ module: 'rear_main', factory: 'DN80000000000000A', factoryKey: 'BCMS' }] }), true);
assert.equal(r.status.rear_camera, 'replaced');
assert.ok(r.rows.some(row => row.includes('Đã thay') && row.includes('DN80000000000000A') && row.includes('DN83156CUMN1CDK2U')),
  r.rows.join('\n'));

// An empty or failed read still renders.
render('iPhone14,7', { errors: ['D1 diagnostics_relay: timeout'] });
render('iPhone14,7', {});

console.log('Parts tab: iPhone XS, SE 2, 11, 14 Pro Max, 17 Pro Max — passed');
