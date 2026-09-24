// Đọc dấu hiệu linh kiện đã thay/không chính hãng TỪ LOG RIÊNG CỦA THIẾT BỊ.
// Không dùng ảnh/OCR. Triệu chứng panic đơn thuần KHÔNG chứng minh đã thay linh
// kiện — chỉ nhận khi log ghi rõ nhãn xác thực linh kiện (genuine / unknown /
// non-genuine / unauthorized…). Log CrashReporter không chứa đầy đủ "Lịch sử
// linh kiện" của iOS, nên đây là dấu hiệu, cần đối chiếu Cài đặt để chắc chắn.
const PartsHistory = (() => {
  const normalize = value => String(value || '').normalize('NFD')
    .replace(/[̀-ͯ]/g, '').replace(/đ/g, 'd').replace(/Đ/g, 'D')
    .toLowerCase().replace(/\s+/g, ' ').trim();

  const parts = [
    ['front_camera', /camera truoc|front ?camera|frontcamera|前置摄像头/],
    ['rear_camera', /camera sau|rear ?camera|back ?camera|后置摄像头/],
    ['battery', /\bpin\b|\bbattery\b|batt(?:ery)?[_ -]?serial|gasgauge|电池/],
    ['display', /man hinh|\bdisplay\b|\bscreen\b|\bpanel\b|lcd|oled|显示屏|屏幕/],
    ['face_id', /face ?id|truedepth|faceid|原深感|面容/],
    ['touch_id', /touch ?id|指纹|触控 id/],
    ['logic_board', /bang mach logic|logic ?board|main ?board|主板/],
    ['camera', /\bcamera\b|摄像头/]
  ];

  // Nhãn trạng thái xác thực linh kiện, sắp theo mức "đáng lưu ý" giảm dần.
  const statuses = [
    ['nongenuine', /non[_ -]?genuine|not[_ -]?genuine|khong chinh hang|unauthorized|counterfeit|aftermarket|fake ?part|hang gia|副厂|非原装|非正品|未授权/],
    ['unknown', /khong xac dinh|\bunknown(?:[_ -]?part)?\b|unknownpart|未知部件|未知零件|未知配件/],
    ['unverified', /chua xac minh|\bunverified\b|not[_ -]?verified|verification ?failed|未验证|未经验证|验证失败/],
    ['serial_mismatch', /serial ?mismatch|mismatch(?:ed)? ?serial|khong khop serial|序列号不匹配/],
    ['finish_repair', /hoan tat sua chua|finish ?repair|完成维修/],
    ['used', /da qua su dung|\bused[_ -]?part\b|refurbished|二手|翻新/],
    ['genuine', /\bgenuine(?: ?apple)?(?: ?part)?\b|chinh hang|正品|原装/]
  ];

  const match = (text, choices) => {
    const n = normalize(text);
    return choices.find(([, pattern]) => pattern.test(n))?.[0] || null;
  };

  // File log/daemon liên quan tới xác thực linh kiện: khi trùng thì cả file
  // được coi là ngữ cảnh linh kiện.
  const partAuthFile = /parts?|history|repair|component|linh.?kien|gestalt|analytic|batteryhealth|gasgauge/i;
  // Ngữ cảnh xác thực trên chính dòng log — dùng để loại triệu chứng panic
  // (vd "battery voltage unknown") vốn không phải nhãn linh kiện.
  const partAuthLine = /genuine|non[_ -]?genuine|not ?genuine|unknown ?part|unauthorized|counterfeit|aftermarket|serial ?mismatch|part.?(?:status|auth)|component.?status|repair.?status|chinh hang|khong xac dinh|linh.?kien/i;

  function fromLogs(logs) {
    const findings = [];
    const seen = new Set();
    for (const item of Array.isArray(logs) ? logs : []) {
      const name = String(item?.name || item?.fileName || '').slice(0, 120);
      const content = String(typeof item === 'string' ? item :
        (item?.content || item?.rawText || '')).slice(0, 2_000_000);
      const fileIsPartAuth = partAuthFile.test(name);

      const lines = content.split(/\r?\n/);
      for (let i = 0; i < lines.length; i++) {
        const line = lines[i];
        const part = match(line, parts);
        if (!part) continue;
        // Trạng thái ưu tiên cùng dòng; nếu dòng chỉ có nhãn part thì lấy
        // trạng thái ở dòng kế — nhưng chỉ khi dòng kế KHÔNG phải một part khác
        // (tránh gán nhầm giữa hai linh kiện liền nhau).
        let status = match(line, statuses);
        let ctx = line;
        if (!status) {
          const next = lines[i + 1] || '';
          if (!match(next, parts)) { status = match(next, statuses); ctx = line + ' ' + next; }
        }
        if (!status) continue;
        if (!fileIsPartAuth && !partAuthLine.test(normalize(ctx))) continue;
        const key = part + '|' + status;
        if (seen.has(key)) continue;
        seen.add(key);
        findings.push({ part, status, source: 'log', file: name });
        if (findings.length >= 20) return findings;
      }
    }
    return findings;
  }

  // Gợi ý về cáp/socket từ kết quả chẩn đoán panic — KHÔNG phải bằng chứng thay
  // linh kiện, chỉ để kỹ thuật viên biết chỗ cần kiểm tra.
  function cableClues(records) {
    const clues = [];
    for (const record of Array.isArray(records) ? records : []) {
      const component = String(record?.suspectedComponent || '').trim();
      const advice = String(record?.repairAdvice || '');
      const mentionsCable = /\bcap\b|\bflex\b|\bconnector\b|\bsocket\b|ribbon cable|排线|连接器/.test(normalize(component + ' ' + advice));
      const hasTransportEvidence = (record?.missingSensors?.length || 0) > 0 ||
        (record?.i2cEvents?.length || 0) > 0 ||
        /dcp|display|touch/i.test(String(record?.panicFamily || ''));
      if (!component || !mentionsCable || !hasTransportEvidence) continue;
      clues.push({ component, file: String(record.filename || '').slice(0, 120),
        confidence: String(record.confidence || '') });
      if (clues.length >= 20) break;
    }
    return clues;
  }

  // Kết quả do CHÍNH thiết bị khai qua diagnostics_relay (không phải suy đoán):
  // - Màn hình: cờ auth-passed của IC xác thực — iOS đặt sau bước thách-đáp,
  //   cũng là cơ sở của cảnh báo "Linh kiện không xác định" cho màn hình.
  // - Pin: chỉ khi driver pin có cờ xác thực (0/1); số liệu pin không phải
  //   bằng chứng chính hãng.
  // Apple chỉ xác thực màn hình từ iPhone 11 (trừ SE 2/3) và pin từ
  // iPhone XS/XR (support.apple.com/102658). null = không rõ đời máy.
  function authSupport(model) {
    const m = /^iPhone(\d+),(\d+)$/.exec(String(model || ''));
    if (!m) return { display: null, battery: null };
    const major = Number(m[1]), minor = Number(m[2]);
    const se = (major === 12 && minor === 8) || (major === 14 && minor === 6);
    return {
      display: major >= 12 && !se,
      battery: major >= 12 || (major === 11 && [2, 4, 6, 8].includes(minor))
    };
  }

  // Dấu hiệu (không phải kết luận): pin đã dùng nhiều chu kỳ mà dung lượng đo
  // vẫn vượt dung lượng thiết kế — pin zin gần như không như vậy; hay gặp ở
  // pin thay thế hoặc chip đo đã bị can thiệp.
  function capacityClue(battery) {
    const design = Number(battery && battery.designCapacity);
    const full = Number(battery && battery.fullChargeCapacity);
    const cycles = Number(battery && battery.cycleCount);
    if (!(design > 0 && full > 0 && Number.isFinite(cycles))) return null;
    const percent = Math.round(full / design * 1000) / 10;
    return percent >= 102 && cycles >= 200 ? { percent, cycles } : null;
  }

  // Cùng một sê-ri viết khác nhau (hoa/thường, khoảng trắng, đệm).
  function sameSerial(a, b) {
    const clean = value => String(value || '').toUpperCase().replace(/[^A-Z0-9]/g, '');
    const x = clean(a), y = clean(b);
    if (x.length < 6 || y.length < 6) return false;
    return x === y || x.includes(y) || y.includes(x);
  }

  // Camera: mỗi module ghi riêng — sau chính / góc siêu rộng / tele, camera
  // trước RGB, và cụm TrueDepth (camera hồng ngoại, máy chiếu điểm). Mỗi
  // module có thể có tới ba nguồn, giữ nguyên nguồn nào nói gì:
  //  - factory: sê-ri ghi lúc xuất xưởng trong SysCfg (BCMS camera sau chính,
  //    FCMS camera trước) — chỉ bản TrollStore/JB đọc được;
  //  - ioreg: "…CameraModuleSerialNumString" của driver camera (qua ghép đôi);
  //  - gestalt: khoá MobileGestalt "…CameraModuleSerialNumber".
  // Chưa kiểm chứng trên máy đã thay camera rằng ioreg/gestalt là sê-ri module
  // ĐANG lắp, nên khác sê-ri gốc chỉ là "cần kiểm tra", không kết luận đã thay;
  // khớp sê-ri cũng không chứng minh cả cụm chưa từng sửa.
  const CAMERA_MODULES = ['rear_main', 'rear_ultra_wide', 'rear_tele', 'rear_lidar', 'front', 'truedepth_ir',
    'truedepth_projector'];
  const CAMERA_PART = { rear_main: 'rear_camera', rear_ultra_wide: 'rear_camera', rear_tele: 'rear_camera',
    rear_lidar: 'rear_camera', front: 'front_camera', truedepth_ir: 'face_id', truedepth_projector: 'face_id' };
  const MAIN_MODULE = { rear_camera: 'rear_main', front_camera: 'front' };
  // Tên module của driver camera (tiền tố trước "CameraModuleSerialNumString").
  const IOREG_MODULE = { back: 'rear_main', back_super_wide: 'rear_ultra_wide', back_tele: 'rear_tele',
    lidar: 'rear_lidar', front: 'front', front_ir: 'truedepth_ir', front_ir_structured_light: 'truedepth_projector' };

  // Kết quả iOS tự kiểm tra dữ liệu hiệu chuẩn của module camera với dữ liệu
  // niêm phong lúc xuất xưởng (driver camera AppleH1xCamIn; corerepaird đọc
  // "CmClValidationStatus" cho camera sau). CmCl = camera sau, FCCl = camera
  // trước. Các khoá khác (CmPM…) chưa rõ thuộc module nào: chỉ giữ ở dữ liệu thô.
  const VALIDATION_PART = { CmClValidationStatus: 'rear_camera', FCClValidationStatus: 'front_camera' };
  const validationFailed = value => /fail|mismatch|unauthori[sz]ed|invalid|swap/i.test(String(value || ''));

  function cameraValidation(report) {
    const out = [];
    const statuses = (report && report.cameraValidation) || {};
    for (const [key, part] of Object.entries(VALIDATION_PART)) {
      const value = statuses[key];
      if (typeof value !== 'string' || !value) continue;
      const status = /^pass/i.test(value) ? 'validated' : (validationFailed(value) ? 'validation_fail' : null);
      out.push({ part, key, value, status });
    }
    return out;
  }

  function cameraModules(report) {
    const byModule = {};
    const get = module => (byModule[module] = byModule[module] || { module, part: CAMERA_PART[module] });
    for (const item of Array.isArray(report && report.cameraSerials) ? report.cameraSerials : []) {
      if (!item || !CAMERA_PART[item.module]) continue;
      const entry = get(item.module);
      if (item.factory) { entry.factory = String(item.factory); entry.factoryKey = String(item.factoryKey || ''); }
      if (item.gestalt) entry.gestalt = String(item.gestalt);
    }
    for (const item of Array.isArray(report && report.cameras) ? report.cameras : []) {
      const module = item && IOREG_MODULE[item.module];
      if (!module) continue;
      const entry = get(module);
      if (item.serial) entry.ioreg = String(item.serial);
      if (typeof item.expected === 'boolean') entry.expected = item.expected;
    }
    return CAMERA_MODULES.filter(module => byModule[module] &&
      (byModule[module].factory || byModule[module].ioreg || byModule[module].gestalt)).map(module => {
      const entry = byModule[module];
      entry.current = entry.ioreg || entry.gestalt || '';
      if (entry.ioreg && entry.gestalt) entry.sourcesAgree = sameSerial(entry.ioreg, entry.gestalt);
      if (entry.factory && entry.current) {
        // Khác nếu BẤT KỲ nguồn đang lắp nào khác sê-ri gốc.
        entry.match = [entry.ioreg, entry.gestalt].filter(Boolean).every(v => sameSerial(entry.factory, v));
      }
      return entry;
    });
  }

  // Kết quả của camera chính cho một dòng (rear_camera / front_camera).
  function cameraCheck(report, part) {
    const module = MAIN_MODULE[part];
    return module ? cameraModules(report).find(entry => entry.module === module) || null : null;
  }

  // iOS không chạy kiểm tra "trusted battery" trên đời máy này (iPhone 14…):
  // AppleBatteryAuth có TrustedBatteryEnabled = 0 nên không bao giờ có cờ pass.
  // Bản native cũ chỉ gửi giá trị này trong dữ liệu thô.
  function batteryTrustedOff(report) {
    const auth = (report && report.battery && report.battery.auth) || {};
    if (typeof auth.trustedEnabled === 'boolean') return !auth.trustedEnabled;
    return (Array.isArray(report && report.raw) ? report.raw : []).some(entry => entry && entry.name === 'AppleBatteryAuth'
      && entry.props && String(entry.props.TrustedBatteryEnabled) === '0');
  }

  function fromHardware(report) {
    const findings = [];
    if (!report || typeof report !== 'object') return findings;
    const display = report.display || {};
    if (typeof display.authPassed === 'boolean') {
      findings.push({ part: 'display', status: display.authPassed ? 'genuine' : 'authfail',
        source: 'hardware', serial: display.panelSerial || '' });
    }
    // Cờ "auth-passed" tìm thấy trên node của linh kiện khác (dò theo thuộc
    // tính, không theo tên node): pin, camera, Face ID…
    for (const flag of Array.isArray(report.parts) ? report.parts : []) {
      if (!flag || typeof flag.authPassed !== 'boolean' || !flag.part) continue;
      if (findings.some(f => f.part === flag.part)) continue;
      findings.push({ part: flag.part, status: flag.authPassed ? 'genuine' : 'authfail',
        source: 'hardware', path: String(flag.path || '') });
    }
    // Driver xác thực pin AppleBatteryAuth (mã nguồn PowerManagement của Apple):
    // cờ "…Pass" sau bước thách-đáp là kết luận; "CommunicationError" /
    // "CoProcError" nghĩa là chip xác thực trong pin không phản hồi hoặc báo lỗi
    // — đúng chỗ pin thiếu chip xác thực của Apple bị loại.
    const battery = report.battery || {};
    const auth = battery.auth || {};
    const serial = battery.serial || '';
    if (typeof auth.passed === 'boolean' && !findings.some(f => f.part === 'battery')) {
      findings.push({ part: 'battery', status: auth.passed ? 'genuine' : 'authfail',
        source: 'hardware', serial });
    }
    // Face ID, Touch ID, camera, loa, cảm ứng: cờ pass trên driver của linh kiện.
    for (const item of Array.isArray(report.components) ? report.components : []) {
      if (!item || typeof item.authPassed !== 'boolean' || !item.part) continue;
      if (findings.some(f => f.part === item.part)) continue;
      findings.push({ part: item.part, status: item.authPassed ? 'genuine' : 'authfail',
        source: 'hardware', path: String(item.path || '') });
    }
    // Face ID / Touch ID: iOS tắt khi cảm biến hỏng hoặc không khớp máy.
    const bio = report.biometrics || {};
    if (bio.part && bio.state === 'not_available' && !findings.some(f => f.part === bio.part)) {
      findings.push({ part: bio.part, status: 'unavailable', source: 'hardware' });
    }
    // Sê-ri đang lắp khác sê-ri gốc ghi trong SysCfg: linh kiện đã được thay.
    for (const item of Array.isArray(report.syscfg) ? report.syscfg : []) {
      if (!item || item.match !== false || !item.part) continue;
      if (findings.some(f => f.part === item.part)) continue;
      findings.push({ part: item.part, status: 'replaced', source: 'hardware',
        factory: String(item.factory || ''), current: String(item.current || '') });
    }
    for (const part of Object.keys(MAIN_MODULE)) {
      const check = cameraCheck(report, part);
      if (!check || typeof check.match !== 'boolean' || findings.some(f => f.part === part)) continue;
      findings.push({ part, status: check.match ? 'serial_match' : 'serial_mismatch', source: 'hardware',
        factory: check.factory, current: check.current });
    }
    for (const item of cameraValidation(report)) {
      if (item.status) findings.push({ part: item.part, status: item.status, source: 'hardware', value: item.value });
    }
    const flags = battery.authFlags || {};
    const values = Object.values(flags).filter(v => v === 0 || v === 1);
    if (values.length && !findings.some(f => f.part === 'battery')) {
      findings.push({ part: 'battery', status: values.every(v => v === 1) ? 'genuine' : 'authfail',
        source: 'hardware', serial });
    }
    if ((auth.commError || auth.coprocError) && !findings.some(f => f.part === 'battery')) {
      findings.push({ part: 'battery', status: 'auth_error', source: 'hardware', serial,
        code: Number(auth.commError || auth.coprocError) || 0 });
    }
    if (capacityClue(report.battery)) {
      findings.push({ part: 'battery', status: 'capacity_anomaly', source: 'hardware' });
    }
    return findings;
  }

  // Không thấy nhãn trong log KHÔNG chứng minh mọi linh kiện còn nguyên bản.
  // Xác thực phần cứng chỉ nói về linh kiện đã đọc được, không phải toàn máy.
  function assessScan(logCount, statusSignals, cableSignals, hardwareSignals) {
    const hardware = Array.isArray(hardwareSignals) ? hardwareSignals : [];
    if (hardware.some(f => !['genuine', 'serial_match', 'validated'].includes(f.status))) return 'found';
    const hasLogs = Number.isFinite(logCount) && logCount > 0;
    if (hasLogs && Array.isArray(statusSignals) && statusSignals.length) return 'found';
    if (hardware.length) return 'verified';
    if (!hasLogs) return 'noLogs';
    if (Array.isArray(cableSignals) && cableSignals.length) return 'cable';
    return 'noEvidence';
  }

  // Một lần đọc phần cứng có thể hỏng giữa chừng (VPN/pairing chập chờn): giữ
  // phần đã đọc được ở lần trước thay vì làm mục Pin/Màn hình biến mất.
  function mergeHardwareReport(previous, next) {
    const has = value => !!value && typeof value === 'object' && Object.keys(value).length > 0;
    const filled = value => Array.isArray(value) && value.length > 0;
    if (!has(previous)) return next;
    if (!has(next)) return previous;
    // Mỗi nguồn (pairing, Face ID/Touch ID, SysCfg) gửi phần của mình: giữ phần
    // còn lại của lần trước; lỗi chỉ thuộc về lần đọc mới nhất.
    const merged = Object.assign({}, previous, next);
    if (next.errors) merged.errors = next.errors; else delete merged.errors;
    if (!has(next.display) && has(previous.display)) merged.display = previous.display;
    if (has(previous.battery)) merged.battery = Object.assign({}, previous.battery, next.battery || {});
    for (const key of ['parts', 'components', 'raw', 'syscfg', 'cameras', 'cameraSerials']) {
      if (!filled(next[key]) && filled(previous[key])) merged[key] = previous[key];
    }
    if (!filled(next.raw) && previous.probe) merged.probe = previous.probe;
    return merged;
  }

  // ---- Tổng quan toàn bộ linh kiện + phát hiện thay thế ----------------------
  // Trạng thái cần báo cho người dùng (thông báo iOS + băng cảnh báo).
  const ALERT = new Set(['authfail', 'nongenuine', 'replaced', 'unavailable', 'auth_error', 'changed', 'validation_fail',
    'unknown', 'serial_mismatch', 'used', 'finish_repair', 'unverified']);
  const isAlert = status => ALERT.has(status);

  // Linh kiện chính của đời máy: Face ID hay Touch ID theo mã máy.
  function expectedParts(model) {
    const m = /^iPhone(\d+),(\d+)$/.exec(String(model || ''));
    let bio = 'face_id';
    if (m) {
      const major = Number(m[1]), minor = Number(m[2]);
      if ((major === 12 && minor === 8) || (major === 14 && minor === 6) || major < 10 ||
          (major === 10 && [1, 2, 4, 5].includes(minor))) bio = 'touch_id';
    }
    return ['display', 'battery', bio, 'rear_camera', 'front_camera', 'speaker'];
  }

  // Sê-ri đang lắp của từng linh kiện (để nhận ra lần sau có bị thay không).
  function partIdentities(report) {
    const ids = {};
    if (report && report.display && report.display.panelSerial) ids.display = String(report.display.panelSerial);
    if (report && report.battery && report.battery.serial) ids.battery = String(report.battery.serial);
    for (const item of Array.isArray(report && report.syscfg) ? report.syscfg : []) {
      if (item && item.part && item.current && !ids[item.part]) ids[item.part] = String(item.current);
    }
    // Mỗi module camera một khoá, để nhận ra cả khi chỉ thay tele hay góc rộng.
    for (const entry of cameraModules(report)) {
      if (entry.current) ids['cam:' + entry.module] = entry.current;
    }
    return ids;
  }

  function changedParts(previousIds, currentIds) {
    if (!previousIds || typeof previousIds !== 'object') return [];
    const differs = (a, b) => String(a) !== String(b) && !sameSerial(a, b);
    return Object.keys(currentIds || {})
      .filter(part => previousIds[part] && differs(previousIds[part], currentIds[part]));
  }

  // Một dòng cho mỗi linh kiện: bằng chứng mạnh nhất từ phần cứng, SysCfg,
  // Face ID/Touch ID rồi mới tới log.
  function partsOverview(report, logFindings, model, changed) {
    const hardware = fromHardware(report).filter(f => f.status !== 'capacity_anomaly');
    const logs = Array.isArray(logFindings) ? logFindings : [];
    const syscfg = Array.isArray(report && report.syscfg) ? report.syscfg : [];
    const bio = (report && report.biometrics) || {};
    const moved = Array.isArray(changed) ? changed : [];
    const parts = expectedParts(model);
    for (const f of hardware) if (!parts.includes(f.part)) parts.push(f.part);
    return parts.map(part => {
      if (moved.some(key => key === part || CAMERA_PART[String(key).replace(/^cam:/, '')] === part)) {
        return { part, status: 'changed' };
      }
      const hw = hardware.filter(f => f.part === part);
      const bad = hw.find(f => isAlert(f.status));
      if (bad) return { part, status: bad.status };
      const sys = syscfg.find(item => item && item.part === part);
      if (sys && sys.match === false) return { part, status: 'replaced' };
      const logBad = logs.find(f => f.part === part && isAlert(f.status));
      if (logBad) return { part, status: logBad.status, source: 'log' };
      const validated = hw.find(f => f.status === 'validated');
      if (validated) return { part, status: 'validated', value: validated.value };
      if (hw.some(f => f.status === 'serial_match')) return { part, status: 'serial_match' };
      if (hw.some(f => f.status === 'genuine') || (sys && sys.match === true)) return { part, status: 'genuine' };
      if (bio.part === part && (bio.state === 'ok' || bio.state === 'not_enrolled')) {
        return { part, status: 'working', detail: bio.state };
      }
      const logAny = logs.find(f => f.part === part);
      if (logAny) return { part, status: logAny.status, source: 'log' };
      if (part === 'speaker') return { part, status: 'not_authenticated' };
      const camera = cameraCheck(report, part);
      if (camera && camera.current) return { part, status: 'serial_only', serial: camera.current };
      if (camera && camera.factory) return { part, status: 'no_flag', factory: camera.factory };
      return sys && sys.factory ? { part, status: 'no_flag', factory: String(sys.factory) } : { part, status: 'no_flag' };
    });
  }

  return { fromLogs, fromHardware, cableClues, assessScan, authSupport, capacityClue, mergeHardwareReport,
    isAlert, expectedParts, partIdentities, changedParts, partsOverview, sameSerial, cameraModules, cameraCheck,
    cameraValidation, batteryTrustedOff, CAMERA_PART };
})();

if (typeof module !== 'undefined') module.exports = PartsHistory;
