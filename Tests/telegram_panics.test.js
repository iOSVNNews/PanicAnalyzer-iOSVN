const assert = require('assert');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const noop = () => {};
const element = () => null;
const context = {
  console, setTimeout, clearTimeout,
  navigator: { language: 'vi', clipboard: null },
  localStorage: { getItem: () => null, setItem: noop },
  document: {
    addEventListener: noop, getElementById: element, querySelector: element,
    querySelectorAll: () => [], createElement: () => ({ style: {}, append: noop, appendChild: noop }),
    documentElement: { lang: 'vi' }, body: { appendChild: noop }
  }
};
context.window = context;
vm.createContext(context);
for (const file of ['i18n.js', 'parts.js', 'app.js']) {
  vm.runInContext(fs.readFileSync(path.join(__dirname, '..', 'web', file), 'utf8'), context, { filename: file });
}

context.__rules = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'assets', 'panic_rules.json'), 'utf8'));
context.__sensors = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'assets', 'sensor_database.json'), 'utf8'));
context.__i2c = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'assets', 'i2c_rules.json'), 'utf8'));
context.__models = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'assets', 'model_database.json'), 'utf8'));

vm.runInContext(`
  ruleDatabases.panic_rules = __rules;
  ruleDatabases.sensor_database = __sensors;
  ruleDatabases.i2c_rules = __i2c;
  ruleDatabases.model_database = __models;
`, context);

const parse = (text, name) => vm.runInContext('parseLogContent', context)(text, name);

// Test 1: SEP monitor error (iPhone 12 Pro Max real panic)
const sepText = `{"bug_type":"210","timestamp":"2026-10-06 00:42:58.00 +0700","os_version":"iPhone OS 27.0.1 (24A446)"}
{
  "product" : "iPhone13,4",
  "panicString" : "panic(cpu 0 caller 0xfffffff04bd34530): \\"SEP monitor error: INACCESSIBLE SEP REGISTERS SOC_PERF_STATE_CTL 0x00000555 VOLMAN_SOC_VOLTAGE 0x01737673\\" @AppleT8101PlatformErrorHandler.cpp:917\\nDebugger message: panic"
}`;
const sepRecord = parse(sepText, 'panic-full-2026-10-06-004258.0002.ips');
assert.equal(sepRecord.logType, 'kernel_panic');
assert.equal(sepRecord.ruleId, 'sep-monitor-error');
assert.equal(sepRecord.severity, 'critical');
assert.ok(sepRecord.title.includes('SEP Monitor Error'));
assert.ok(sepRecord.suspectedComponent.includes('interposer') || sepRecord.suspectedComponent.includes('bo ghép'));

// Test 2: panic-base+socd format must be classified as kernel_panic and not springboard-crash
const socdText = `{"bug_type":"210","timestamp":"2026-10-05 20:33:05.00 +0700","os_version":"iPhone OS 27.0.1 (24A446)"}
{
  "product" : "iPhone13,4",
  "panicString" : "panic(cpu 0 caller 0xfffffff031648530): \\"SEP monitor error: INACCESSIBLE SEP REGISTERS SOC_PERF_STATE_CTL 0x00000555 VOLMAN_SOC_VOLTAGE 0x01737673\\" @AppleT8101PlatformErrorHandler.cpp:917"
}`;
const socdRecord = parse(socdText, 'panic-base+socd-2026-10-05-203305.000.ips');
assert.equal(socdRecord.logType, 'kernel_panic');
assert.equal(socdRecord.ruleId, 'sep-monitor-error');

// Test 3: Kernel Virtual Memory (pmap_tte_remove) on iPhone XS
const pmapText = `{"bug_type":"210","timestamp":"2026-09-26 02:51:39.00 +0700","os_version":"iPhone OS 16.5.1 (20F75)"}
{
  "product" : "iPhone11,2",
  "panicString" : "panic(cpu 1 caller 0xfffffff01dc89214): pmap_tte_remove: Found inconsistent state in soon to be deleted L3 table: 0 valid, 0 compressed, 0 non-empty, refcnt=65534, L2 tte=0x8e4b58003, pmap=0xfffffff09762b260, bpte=0xfffffff13a00c000 @pmap.c:5453"
}`;
const pmapRecord = parse(pmapText, 'panic-full-2026-09-26-025139.000.ips');
assert.equal(pmapRecord.logType, 'kernel_panic');
assert.equal(pmapRecord.ruleId, 'kernel-pmap-corruption');
assert.notEqual(pmapRecord.ruleId, 'dcp-display-panic', 'Must NOT match DCP on iPhone XS pmap panic');

// Test 4: Userspace watchdog with healthy thermalmonitord and hung SpringBoard
const wdtText = `{"bug_type":"210","timestamp":"2026-09-27 02:57:47.00 +0700"}
{
  "product" : "iPhone15,3",
  "panicString" : "panic(cpu 0 caller 0xfffffff047e1cd54): userspace watchdog timeout: no successful checkins from SpringBoard (2 induced crashes) in 180 seconds\\nservice: backboardd, total successful checkins in 1297 seconds: 126, last successful checkin: 0 seconds ago\\nservice: thermalmonitord, total successful checkins in 39821 seconds: 3964, last successful checkin: 0 seconds ago"
}`;
const wdtRecord = parse(wdtText, 'panic-full-2026-09-27-025747.000.ips');
assert.equal(wdtRecord.ruleId, 'watchdog-springboard');
assert.notEqual(wdtRecord.ruleId, 'watchdog-thermalmonitord', 'Must NOT falsely accuse thermalmonitord when it was healthy');

// Test 5: DiskWrites resource log from analyticsd must NOT trigger Baseband Panic
const diskText = `{"duration_ms":"20951211","bug_type":"145","app_name":"analyticsd","name":"analyticsd"}
Command: analyticsd
On Behalf Of: 1 sample originated by CommCenter [104], 1 sample OTACrash`;
const diskRecord = parse(diskText, 'analyticsd.diskwrites_resource-2026-09-26-074533.ips');
assert.equal(diskRecord.logType, 'disk_writes');
assert.equal(diskRecord.ruleId, 'disk-writes');
assert.equal(diskRecord.severity, 'normal');

// Test 6: CPU resource log with thermalpressure status must NOT trigger Thermal Panic
const cpuText = `{"bug_type":"140","app_name":"CoreRoutineHelperService","name":"CoreRoutineHelperService"}
Command: CoreRoutineHelperService
thermalpressure: 0
cpu_usage: 95%`;
const cpuRecord = parse(cpuText, 'CoreRoutineHelperService.cpu_resource-2026-09-20-181925.ips');
assert.equal(cpuRecord.logType, 'cpu_resource');
assert.equal(cpuRecord.ruleId, 'cpu-resource');
assert.equal(cpuRecord.severity, 'normal');

// Test 7: SpringBoard hang report (bug_type 409) must NOT trigger DCP display panic
const sbHangText = `{"name":"SpringBoard","bug_type":"409","app_name":"SpringBoard","bundleID":"com.apple.springboard"}
{
  "variant" : "stackshot",
  "modelCode" : "iPhone17,2",
  "procName" : "SpringBoard"
}`;
const sbRecord = parse(sbHangText, 'SpringBoard-2026-09-29-222439.ips');
assert.notEqual(sbRecord.ruleId, 'dcp-display-panic');
assert.notEqual(sbRecord.severity, 'critical');

// Test 8: ResetCounter watchdog boot faults
const rstText = `{"os_version":"iPhone OS 27.0.1 (24A446)","bug_type":"115","name":"Reset count"}
Reset count: 1
Boot failure count: 0
Boot faults: rst wdog,reset_in_1`;
const rstRecord = parse(rstText, 'ResetCounter-2026-10-06-004359.ips');
assert.equal(rstRecord.logType, 'watchdog');

// Test 9: I2C device_names database lookup
assert.ok(context.__i2c.device_names.ad5860, 'ad5860 must be in device_names');
assert.ok(context.__i2c.device_names.roswell, 'roswell must be in device_names');
assert.ok(context.__i2c.device_names.bcm5976, 'bcm5976 must be in device_names');
assert.ok(context.__i2c.device_names.s2dos05, 's2dos05 must be in device_names');

// Test 10: Sensor database enrichment
assert.ok(context.__sensors.TG0T, 'TG0T must be in sensor database');
assert.ok(context.__sensors.TB1T, 'TB1T must be in sensor database');
assert.ok(context.__sensors.ALST, 'ALST must be in sensor database');
assert.ok(context.__sensors.SoC, 'SoC must be in sensor database');

console.log('Telegram Panics & Diagnostic Verification: All 10 tests passed flawlessly!');
