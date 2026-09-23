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

  // Không thấy nhãn trong log KHÔNG chứng minh mọi linh kiện còn nguyên bản.
  function assessScan(logCount, statusSignals, cableSignals) {
    if (!Number.isFinite(logCount) || logCount <= 0) return 'noLogs';
    if (Array.isArray(statusSignals) && statusSignals.length) return 'found';
    if (Array.isArray(cableSignals) && cableSignals.length) return 'cable';
    return 'noEvidence';
  }

  return { fromLogs, cableClues, assessScan };
})();

if (typeof module !== 'undefined') module.exports = PartsHistory;
