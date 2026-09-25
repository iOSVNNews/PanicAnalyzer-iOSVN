#!/usr/bin/env bash
# PHP report relay (server/report-php/report.php) against a fake Telegram:
# decode, forward to every chat, reject non-reports, rate limit.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$WORK"' EXIT

mkdir -p "$WORK/mock"
cat > "$WORK/mock/index.php" <<'EOF'
<?php
$doc = $_FILES['document'] ?? null;
file_put_contents(__DIR__ . '/../sent.jsonl', json_encode([
  'path' => $_SERVER['REQUEST_URI'], 'chat' => $_POST['chat_id'] ?? '', 'caption' => $_POST['caption'] ?? '',
  'name' => $doc['name'] ?? '', 'text' => $doc ? file_get_contents($doc['tmp_name']) : ''
]) . "\n", FILE_APPEND);
header('Content-Type: application/json');
echo json_encode(['ok' => true]);
EOF
cat > "$WORK/config.php" <<'EOF'
<?php return ['bot_token' => 'TEST_TOKEN', 'chat_id' => '111, 222', 'max_per_hour' => 3,
  'api_base' => 'http://127.0.0.1:18081'];
EOF

php -S 127.0.0.1:18081 -t "$WORK/mock" >/dev/null 2>&1 &
mkdir -p "$WORK/tmp"
TMPDIR="$WORK/tmp" PANIC_REPORT_CONFIG="$WORK/config.php" php -S 127.0.0.1:18080 "$ROOT/server/report-php/report.php" >/dev/null 2>&1 &
sleep 1

payload() {  # $1 = report text, $2 = encoding
  REPORT="$1" ENCODING="$2" python3 - <<'EOF'
import base64, json, os, zlib
text = os.environ['REPORT'].encode()
if os.environ['ENCODING'] == 'deflate-raw':
    c = zlib.compressobj(9, zlib.DEFLATED, -15); data = c.compress(text) + c.flush()
else:
    data = text
print(json.dumps({'name': 'PanicAnalyzer-toan-bo-iPhone15,3-20260925-1030.txt', 'note': 'Máy vào nước',
                  'contact': '@khach', 'meta': {'model': 'iPhone15,3', 'ios': '27.0', 'app': '2.9'},
                  'encoding': os.environ['ENCODING'], 'data': base64.b64encode(data).decode()}))
EOF
}
post() { curl -s -X POST -H 'Content-Type: application/json' --data-binary @- http://127.0.0.1:18080/; }

REPORT=$'PanicAnalyzer — toàn bộ dữ liệu\nMáy: iPhone15,3\n'"$(printf 'panic(cpu 0)\n%.0s' {1..500})"
out=$(payload "$REPORT" deflate-raw | post)
[ "$out" = '{"ok":true}' ] || { echo "send failed: $out"; exit 1; }
python3 - "$WORK/sent.jsonl" "$REPORT" <<'EOF'
import json, sys
sent = [json.loads(line) for line in open(sys.argv[1])]
assert [s['chat'] for s in sent] == ['111', '222'], sent
assert sent[0]['path'] == '/botTEST_TOKEN/sendDocument'
assert sent[0]['text'] == sys.argv[2] + '\n' or sent[0]['text'] == sys.argv[2], 'report arrives whole'
assert sent[0]['name'] == 'PanicAnalyzer-toan-bo-iPhone15,3-20260925-1030.txt'
assert 'iPhone15,3' in sent[0]['caption'] and 'Máy vào nước' in sent[0]['caption'] and '@khach' in sent[0]['caption']
EOF

out=$(payload "hello" none | post)
echo "$out" | grep -q not_a_report || { echo "accepted a non-report: $out"; exit 1; }
out=$(echo '{"encoding":"deflate-raw","data":"bm90"}' | post)
echo "$out" | grep -q bad_data || { echo "bad data: $out"; exit 1; }
out=$(payload "$REPORT" deflate-raw | post)
echo "$out" | grep -q rate_limited || { echo "no rate limit: $out"; exit 1; }
curl -s http://127.0.0.1:18080/ | grep -q '"ok":true'

echo "PHP report relay: decode, forward, reject, rate limit — passed"
