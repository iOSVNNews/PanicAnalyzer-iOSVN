// Crash reports of apps (bug_type 309 JSON, 109 / .crash text) are app
// crashes — which app, when, why — never watchdog or kernel panics.
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
vm.runInContext('ruleDatabases.panic_rules = __rules', context);
const parse = (text, name) => vm.runInContext('parseLogContent', context)(text, name);

// iOS 15+ JSON crash report: one metadata line, then the body.
const header = { app_name: 'Zalo', timestamp: '2026-09-20 10:15:30.00 +0700', app_version: '25.9.1',
  build_version: '1234', bundleID: 'vn.com.vng.zingalo', is_first_party: 0, bug_type: '309',
  os_version: 'iPhone OS 27.0 (24A437)', name: 'Zalo', incident_id: '1111-2222' };
const body = { procName: 'Zalo', captureTime: '2026-09-20 10:15:30.1234 +0700',
  exception: { type: 'EXC_BAD_ACCESS', signal: 'SIGSEGV', subtype: 'KERN_INVALID_ADDRESS at 0x0000000000000010' },
  termination: { namespace: 'SIGNAL', code: 11, indicator: 'Segmentation fault: 11', byProc: 'exc handler' },
  faultingThread: 0, threads: [{ triggered: true, frames: [{ imageIndex: 1, symbol: 'objc_msgSend' }] }],
  usedImages: [{ name: 'Zalo' }, { name: 'libobjc.A.dylib' }],
  // Other processes and words that used to trigger unrelated rules.
  note: 'watchdog SpringBoard baseband' };
const crash = parse(JSON.stringify(header) + '\n' + JSON.stringify(body, null, 2), 'Zalo-2026-09-20-101530.ips');
assert.equal(crash.logType, 'app_crash');
assert.equal(crash.bugType, '309');
assert.equal(crash.appCrash.name, 'Zalo');
assert.equal(crash.appCrash.bundleID, 'vn.com.vng.zingalo');
assert.equal(crash.appCrash.firstParty, false);
assert.equal(crash.appCrash.crashedIn, 'libobjc.A.dylib · objc_msgSend');
assert.equal(crash.ruleId, 'generic-app-crash');
assert.equal(crash.severity, 'normal');
assert.ok(crash.title.includes('Zalo'));
assert.ok(crash.timestampMs > 0);
const reason = vm.runInContext('crashReason', context)(crash.appCrash);
assert.ok(reason.includes('EXC_BAD_ACCESS') && reason.includes('SIGSEGV'), reason);

// Watchdog termination inside a crash report: still an app crash, reason says why.
const watchdog = parse(JSON.stringify(Object.assign({}, header, { app_name: 'Maps', bundleID: 'com.apple.Maps', is_first_party: 1 }))
  + '\n' + JSON.stringify({ procName: 'Maps', exception: { type: 'EXC_CRASH', signal: 'SIGKILL' },
    termination: { namespace: 'FRONTBOARD', code: 2343432205, indicator: 'scene-update watchdog transgression' } }),
'Maps-2026-09-21-080000.ips');
assert.equal(watchdog.logType, 'app_crash');
assert.equal(watchdog.appCrash.terminationKey, 'crash.term.watchdog');
assert.ok(watchdog.appCrash.termination.includes('0x8badf00d'));
assert.ok(vm.runInContext('crashReason', context)(watchdog.appCrash).includes('0x8badf00d'));

// Legacy text report (iOS 14 and earlier / .crash).
const legacy = parse(['{"bug_type":"109","os_version":"iPhone OS 14.8"}', 'Incident Identifier: X',
  'Process:             Facebook [1234]', 'Identifier:          com.facebook.Facebook',
  'Version:             300.0 (123)', 'Date/Time:           2021-05-01 10:00:00.000 +0700',
  'Exception Type:  EXC_BAD_ACCESS (SIGSEGV)', 'Termination Reason: SIGNAL 11 Segmentation fault: 11',
  'Thread 0 Crashed:', '0   libsystem_kernel.dylib        0x1 0x0 + 1'].join('\n'), 'Facebook-2021-05-01-100000.ips');
assert.equal(legacy.logType, 'app_crash');
assert.equal(legacy.appCrash.name, 'Facebook');
assert.equal(legacy.appCrash.signal, 'SIGSEGV');
assert.equal(legacy.appCrash.crashedIn, 'libsystem_kernel.dylib');

// SpringBoard crashes keep their own rule.
const springboard = parse(JSON.stringify(Object.assign({}, header, { app_name: 'SpringBoard', bundleID: 'com.apple.springboard' }))
  + '\n' + JSON.stringify({ procName: 'SpringBoard', exception: { type: 'EXC_BAD_ACCESS', signal: 'SIGSEGV' } }),
'SpringBoard-2026-09-22-090000.ips');
assert.equal(springboard.ruleId, 'springboard-crash');

// A kernel panic is still a kernel panic.
const panic = parse(JSON.stringify({ bug_type: '210', timestamp: '2026-09-23 11:00:00.00 +0700' }) + '\n'
  + JSON.stringify({ panicString: 'panic(cpu 0 caller 0x1): watchdog timeout: no checkins from watchdogd in 180 seconds' }),
'panic-full-2026-09-23-110000.000.ips');
assert.equal(panic.logType, 'kernel_panic');
assert.equal(panic.appCrash, undefined);

// Jetsam (298) is not a crash.
assert.notEqual(parse(JSON.stringify({ bug_type: '298' }) + '\n{"largestProcess":"Safari"}', 'JetsamEvent.ips').logType, 'app_crash');

console.log('App crash reports: bug_type 309/109 parsed as app crashes — passed');
