// PanicAnalyzer → Telegram report relay (AWS Lambda, Node.js 20+, Function URL).
//
// The app posts a compressed .txt report here; this function checks it and
// sends it as a document to the iOSVN Telegram chat. The bot token never
// ships in the app: it lives only in this function's environment.
//
// Environment variables (Lambda › Configuration › Environment variables):
//   BOT_TOKEN   token from @BotFather
//   CHAT_ID     numeric chat id that receives reports (several: comma-separated)
//   MAX_PER_HOUR  optional, reports per IP per hour per instance (default 10)
//
// Request (POST, JSON):
//   { name, note, contact, meta: {app, web, model, ios, build, kind},
//     encoding: "deflate-raw" | "gzip" | "none", data: <base64> }
// Response: { ok: true } or { ok: false, error }

import zlib from 'node:zlib';

const MAX_TEXT_BYTES = 40 * 1024 * 1024;   // after decompression
const TELEGRAM_FILE_LIMIT = 45 * 1024 * 1024;
const hitsByIp = new Map();

const reply = (status, body) => ({
  statusCode: status,
  headers: { 'content-type': 'application/json' },
  body: JSON.stringify(body)
});

function allowed(ip) {
  const limit = Number(process.env.MAX_PER_HOUR || 10);
  const now = Date.now();
  const recent = (hitsByIp.get(ip) || []).filter(t => now - t < 3600_000);
  if (recent.length >= limit) return false;
  recent.push(now);
  hitsByIp.set(ip, recent);
  return true;
}

const clean = (value, max) => String(value ?? '').replace(/[\u0000-\u0008\u000b-\u001f]/g, '').trim().slice(0, max);

export function decode(request) {
  const data = Buffer.from(String(request.data || ''), 'base64');
  const options = { maxOutputLength: MAX_TEXT_BYTES };
  switch (request.encoding) {
    case 'deflate-raw': return zlib.inflateRawSync(data, options).toString('utf8');
    case 'gzip': return zlib.gunzipSync(data, options).toString('utf8');
    case 'none': return data.toString('utf8');
    default: throw new Error('encoding');
  }
}

export function caption(request, ip) {
  const meta = request.meta && typeof request.meta === 'object' ? request.meta : {};
  const lines = [
    `📱 ${clean(meta.model, 40) || '?'} · iOS ${clean(meta.ios, 20) || '?'}`,
    `PanicAnalyzer ${clean(meta.app, 20) || '?'} · web ${clean(meta.web, 10) || '?'} · ${clean(meta.build, 20) || '?'}`,
    meta.kind ? `Loại: ${clean(meta.kind, 40)}` : '',
    request.contact ? `Liên hệ: ${clean(request.contact, 80)}` : '',
    request.note ? `Ghi chú: ${clean(request.note, 600)}` : '',
    `IP: ${ip}`
  ];
  return lines.filter(Boolean).join('\n').slice(0, 1000);
}

export function fileName(request) {
  const name = String(request.name || '').replace(/[^A-Za-z0-9._,-]/g, '').replace(/^\.+/, '').slice(0, 100)
    || 'PanicAnalyzer-report';
  return name.toLowerCase().endsWith('.txt') ? name : `${name}.txt`;
}

async function sendDocument(chatId, text, name, captionText) {
  const form = new FormData();
  form.append('chat_id', chatId);
  form.append('caption', captionText);
  const bytes = Buffer.from(text, 'utf8');
  if (bytes.length > TELEGRAM_FILE_LIMIT) {
    form.append('document', new Blob([zlib.gzipSync(bytes)], { type: 'application/gzip' }), `${name}.gz`);
  } else {
    form.append('document', new Blob([bytes], { type: 'text/plain' }), name);
  }
  const response = await fetch(`https://api.telegram.org/bot${process.env.BOT_TOKEN}/sendDocument`, {
    method: 'POST', body: form
  });
  const result = await response.json().catch(() => ({ ok: false, description: `HTTP ${response.status}` }));
  if (!result.ok) throw new Error(result.description || 'telegram');
}

export const handler = async (event) => {
  const method = event?.requestContext?.http?.method || 'POST';
  if (method === 'GET') return reply(200, { ok: true, service: 'panicanalyzer-report' });
  if (method !== 'POST') return reply(405, { ok: false, error: 'method' });
  if (!process.env.BOT_TOKEN || !process.env.CHAT_ID) return reply(500, { ok: false, error: 'not_configured' });

  const ip = event?.requestContext?.http?.sourceIp || '?';
  if (!allowed(ip)) return reply(429, { ok: false, error: 'rate_limited' });

  let request;
  try {
    const body = event.isBase64Encoded ? Buffer.from(event.body || '', 'base64').toString('utf8') : (event.body || '');
    request = JSON.parse(body);
  } catch {
    return reply(400, { ok: false, error: 'bad_json' });
  }

  let text;
  try {
    text = decode(request);
  } catch {
    return reply(400, { ok: false, error: 'bad_data' });
  }
  // Only PanicAnalyzer exports (they start with this header).
  if (!text.startsWith('PanicAnalyzer')) return reply(400, { ok: false, error: 'not_a_report' });

  const name = fileName(request);
  const captionText = caption(request, ip);
  try {
    for (const chatId of String(process.env.CHAT_ID).split(',').map(s => s.trim()).filter(Boolean)) {
      await sendDocument(chatId, text, name, captionText);
    }
  } catch (error) {
    return reply(502, { ok: false, error: 'telegram', detail: String(error.message || error).slice(0, 200) });
  }
  return reply(200, { ok: true });
};
