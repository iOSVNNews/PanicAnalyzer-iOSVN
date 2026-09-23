// Read only explicit Parts & Service History labels. Panic symptoms alone do
// not establish that a component was replaced.
const PartsHistory = (() => {
  const normalize = value => String(value || '').normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '').replace(/đ/g, 'd').replace(/Đ/g, 'D')
    .toLowerCase().replace(/\s+/g, ' ').trim();
  const section = /parts\s*(?:&|and)?\s*service\s*history|lich su linh kien va dich vu|部件与维修历史|部件和维修历史/;
  const parts = [
    ['front_camera', /camera truoc|front camera|前置摄像头/],
    ['rear_camera', /camera sau|rear camera|后置摄像头/],
    ['logic_board', /bang mach logic|logic board|主板/],
    ['battery', /\bpin\b|\bbattery\b|电池/],
    ['display', /man hinh|\bdisplay\b|\bscreen\b|显示屏/],
    ['camera', /\bcamera\b|摄像头/]
  ];
  const statuses = [
    ['unverified', /chua xac minh|\bunverified\b|未经验证|未验证/],
    ['unknown', /khong xac dinh|\bunknown(?: part)?\b|未知/],
    ['finish_repair', /hoan tat sua chua|finish repair|完成维修/],
    ['used', /da qua su dung|\bused(?: part)?\b|二手/],
    ['genuine', /chinh hang|\bgenuine(?: apple part)?\b|正品/]
  ];
  const match = (text, choices) => choices.find(([, pattern]) => pattern.test(normalize(text)))?.[0] || null;

  function fromSettings(lines) {
    const rows = (Array.isArray(lines) ? lines : []).map(s => String(s).trim()).filter(Boolean);
    const heading = rows.findIndex(line => section.test(normalize(line)));
    if (heading < 0) return { sectionFound: false, findings: [] };
    const findings = [];
    for (let index = heading + 1; index < Math.min(rows.length, heading + 30); index++) {
      const part = match(rows[index], parts);
      if (!part) continue;
      let status = match(rows[index], statuses);
      if (!status) {
        // iOS often puts the status immediately below the part label.
        for (let next = index + 1; next < Math.min(rows.length, index + 3); next++) {
          if (match(rows[next], parts)) break;
          status = match(rows[next], statuses);
          if (status) break;
        }
      }
      if (status && !findings.some(finding => finding.part === part)) {
        findings.push({ part, status, source: 'settings' });
      }
    }
    return { sectionFound: true, findings };
  }

  function fromLogs(logs) {
    const findings = [];
    for (const item of Array.isArray(logs) ? logs : []) {
      const name = String(item?.name || item?.fileName || '').slice(0, 120);
      const content = String(typeof item === 'string' ? item :
        (item?.content || item?.rawText || '')).slice(0, 2_000_000);
      const historyFile = /parts?[_ -]?history|repair|components?[_ -]?history|linh.kien/i.test(name);
      for (const line of content.split(/\r?\n/)) {
        const part = match(line, parts);
        const status = match(line, statuses);
        const explicit = /part.?status|component.?status|repair.?status|unknown part|genuine|linh kien|chinh hang|khong xac dinh/i.test(normalize(line));
        if (!part || !status || !(historyFile || explicit)) continue;
        if (!findings.some(f => f.part === part && f.status === status && f.file === name)) {
          findings.push({ part, status, source: 'log', file: name });
        }
        if (findings.length >= 20) return findings;
      }
    }
    return findings;
  }

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

  return { fromSettings, fromLogs, cableClues };
})();

if (typeof module !== 'undefined') module.exports = PartsHistory;
