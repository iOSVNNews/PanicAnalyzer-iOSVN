// Report relay: decodes the app's compressed report and sends it to Telegram
// without the network (fetch is replaced).
import assert from 'node:assert';
import zlib from 'node:zlib';
import { handler, caption, fileName, decode } from '../server/report-lambda/index.mjs';

const sent = [];
globalThis.fetch = async (url, options) => {
  const form = options.body;
  const document = form.get('document');
  sent.push({ url, chat: form.get('chat_id'), caption: form.get('caption'), name: document.name,
    text: Buffer.from(await document.arrayBuffer()).toString('utf8') });
  return { status: 200, json: async () => ({ ok: true }) };
};

process.env.BOT_TOKEN = 'TEST_TOKEN';
process.env.CHAT_ID = '111, 222';
process.env.MAX_PER_HOUR = '2';

const report = 'PanicAnalyzer — toàn bộ dữ liệu\nMáy: iPhone15,3 · iOS 27.0\n' + 'panic(cpu 0)\n'.repeat(2000);
const request = (ip, extra = {}) => ({
  requestContext: { http: { method: 'POST', sourceIp: ip } },
  body: JSON.stringify(Object.assign({
    name: 'PanicAnalyzer-toan-bo-iPhone15,3-20260925-1030.txt', note: 'Máy vào nước', contact: '@khach',
    meta: { app: '2.9', web: 48, model: 'iPhone15,3', ios: '27.0', build: 'IPA', kind: 'toan-bo' },
    encoding: 'deflate-raw', data: zlib.deflateRawSync(Buffer.from(report)).toString('base64')
  }, extra))
});

let res = await handler(request('1.1.1.1'));
assert.equal(res.statusCode, 200, res.body);
assert.equal(sent.length, 2, 'one document per chat');
assert.deepEqual(sent.map(s => s.chat), ['111', '222']);
assert.equal(sent[0].text, report, 'report arrives whole');
assert.equal(sent[0].name, 'PanicAnalyzer-toan-bo-iPhone15,3-20260925-1030.txt');
assert.ok(sent[0].url.endsWith('/botTEST_TOKEN/sendDocument'));
assert.ok(sent[0].caption.includes('iPhone15,3') && sent[0].caption.includes('Máy vào nước') && sent[0].caption.includes('@khach'));

// Rate limit per IP.
await handler(request('1.1.1.1'));
res = await handler(request('1.1.1.1'));
assert.equal(res.statusCode, 429);

// Only PanicAnalyzer reports, valid data, POST.
res = await handler(request('2.2.2.2', { encoding: 'none', data: Buffer.from('hello').toString('base64') }));
assert.equal(JSON.parse(res.body).error, 'not_a_report');
res = await handler(request('3.3.3.3', { data: 'bm90IGRlZmxhdGU=' }));
assert.equal(JSON.parse(res.body).error, 'bad_data');
res = await handler({ requestContext: { http: { method: 'GET' } } });
assert.equal(res.statusCode, 200);

// Not configured → clear error, nothing sent.
delete process.env.CHAT_ID;
const before = sent.length;
res = await handler(request('4.4.4.4'));
assert.equal(JSON.parse(res.body).error, 'not_configured');
assert.equal(sent.length, before);

// Helpers.
assert.equal(fileName({ name: '../../etc/passwd' }), 'etcpasswd.txt');
assert.equal(decode({ encoding: 'gzip', data: zlib.gzipSync('PanicAnalyzer x').toString('base64') }), 'PanicAnalyzer x');
assert.ok(caption({ meta: {}, note: 'a'.repeat(5000) }, '9.9.9.9').length <= 1000);

console.log('Report relay: decode, caption, rate limit, Telegram upload — passed');
