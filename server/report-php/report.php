<?php
// PanicAnalyzer → Telegram report relay for PHP hosting (cPanel), same
// behaviour as server/report-lambda/index.mjs.
//
// Put this file in the web root of a subdomain (e.g. report.iosvn.com.vn/report.php)
// and the settings in panic-report-config.php ONE LEVEL ABOVE that web root,
// so they are never served:
//
//   <?php return ['bot_token' => '...', 'chat_id' => '123456789', 'max_per_hour' => 10];
//
// Request (POST, JSON): { name, note, contact, meta, encoding: "deflate-raw"|"gzip"|"none", data: base64 }
// Response: { "ok": true } or { "ok": false, "error": ... }

declare(strict_types=1);

const MAX_BODY_BYTES = 8 * 1024 * 1024;
const MAX_TEXT_BYTES = 40 * 1024 * 1024;
const TELEGRAM_FILE_LIMIT = 45 * 1024 * 1024;

function reply(int $status, array $body): void
{
    http_response_code($status);
    header('Content-Type: application/json');
    echo json_encode($body);
    exit;
}

function clean($value, int $max): string
{
    $text = preg_replace('/[\x00-\x08\x0B-\x1F]/u', '', (string)($value ?? '')) ?? '';
    return mb_substr(trim($text), 0, $max);
}

function allowed(string $ip, int $limit): bool
{
    $file = sys_get_temp_dir() . '/panic-report-' . md5($ip) . '.json';
    $now = time();
    $hits = is_file($file) ? (json_decode((string)file_get_contents($file), true) ?: []) : [];
    $hits = array_values(array_filter($hits, fn($t) => $now - (int)$t < 3600));
    if (count($hits) >= $limit) {
        return false;
    }
    $hits[] = $now;
    file_put_contents($file, json_encode($hits), LOCK_EX);
    return true;
}

function decode_report(array $request): ?string
{
    $data = base64_decode((string)($request['data'] ?? ''), true);
    if ($data === false) {
        return null;
    }
    switch ($request['encoding'] ?? '') {
        case 'deflate-raw':
            $text = @gzinflate($data, MAX_TEXT_BYTES);
            break;
        case 'gzip':
            $text = @gzdecode($data, MAX_TEXT_BYTES);
            break;
        case 'none':
            $text = $data;
            break;
        default:
            return null;
    }
    return is_string($text) ? $text : null;
}

function file_name(array $request): string
{
    $name = preg_replace('/[^A-Za-z0-9._,-]/', '', (string)($request['name'] ?? '')) ?? '';
    $name = substr(ltrim($name, '.'), 0, 100) ?: 'PanicAnalyzer-report';
    return strtolower(substr($name, -4)) === '.txt' ? $name : $name . '.txt';
}

function caption(array $request, string $ip): string
{
    $meta = is_array($request['meta'] ?? null) ? $request['meta'] : [];
    $lines = [
        '📱 ' . (clean($meta['model'] ?? '', 40) ?: '?') . ' · iOS ' . (clean($meta['ios'] ?? '', 20) ?: '?'),
        'PanicAnalyzer ' . (clean($meta['app'] ?? '', 20) ?: '?') . ' · web ' . (clean($meta['web'] ?? '', 10) ?: '?')
            . ' · ' . (clean($meta['build'] ?? '', 20) ?: '?'),
        !empty($meta['kind']) ? 'Loại: ' . clean($meta['kind'], 40) : '',
        !empty($request['contact']) ? 'Liên hệ: ' . clean($request['contact'], 80) : '',
        !empty($request['note']) ? 'Ghi chú: ' . clean($request['note'], 600) : '',
        'IP: ' . $ip,
    ];
    return mb_substr(implode("\n", array_filter($lines)), 0, 1000);
}

function send_document(array $config, string $chatId, string $text, string $name, string $captionText): ?string
{
    $gzip = strlen($text) > TELEGRAM_FILE_LIMIT;
    $path = tempnam(sys_get_temp_dir(), 'panic');
    file_put_contents($path, $gzip ? gzencode($text) : $text);
    $api = rtrim((string)($config['api_base'] ?? 'https://api.telegram.org'), '/');
    $curl = curl_init($api . '/bot' . $config['bot_token'] . '/sendDocument');
    curl_setopt_array($curl, [
        CURLOPT_POST => true,
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_TIMEOUT => 60,
        CURLOPT_POSTFIELDS => [
            'chat_id' => $chatId,
            'caption' => $captionText,
            'document' => new CURLFile($path, $gzip ? 'application/gzip' : 'text/plain', $gzip ? $name . '.gz' : $name),
        ],
    ]);
    $response = curl_exec($curl);
    $failure = $response === false ? curl_error($curl) : null;
    curl_close($curl);
    unlink($path);
    if ($failure !== null) {
        return $failure;
    }
    $result = json_decode((string)$response, true);
    return !empty($result['ok']) ? null : (string)($result['description'] ?? 'telegram');
}

$configFile = getenv('PANIC_REPORT_CONFIG') ?: dirname(__DIR__) . '/panic-report-config.php';
$config = is_file($configFile) ? require $configFile : [];

$method = $_SERVER['REQUEST_METHOD'] ?? 'POST';
if ($method === 'GET') {
    reply(200, ['ok' => true, 'service' => 'panicanalyzer-report']);
}
if ($method !== 'POST') {
    reply(405, ['ok' => false, 'error' => 'method']);
}
if (empty($config['bot_token']) || empty($config['chat_id'])) {
    reply(500, ['ok' => false, 'error' => 'not_configured']);
}

$ip = (string)($_SERVER['REMOTE_ADDR'] ?? '?');
if (!allowed($ip, (int)($config['max_per_hour'] ?? 10))) {
    reply(429, ['ok' => false, 'error' => 'rate_limited']);
}

$body = file_get_contents('php://input', false, null, 0, MAX_BODY_BYTES + 1);
if ($body === false || strlen($body) > MAX_BODY_BYTES) {
    reply(413, ['ok' => false, 'error' => 'too_large']);
}
$request = json_decode($body, true);
if (!is_array($request)) {
    reply(400, ['ok' => false, 'error' => 'bad_json']);
}
$text = decode_report($request);
if ($text === null) {
    reply(400, ['ok' => false, 'error' => 'bad_data']);
}
// Only PanicAnalyzer exports (they start with this header).
if (strncmp($text, 'PanicAnalyzer', 13) !== 0) {
    reply(400, ['ok' => false, 'error' => 'not_a_report']);
}

$name = file_name($request);
$captionText = caption($request, $ip);
foreach (array_filter(array_map('trim', explode(',', (string)$config['chat_id']))) as $chatId) {
    $error = send_document($config, $chatId, $text, $name, $captionText);
    if ($error !== null) {
        reply(502, ['ok' => false, 'error' => 'telegram', 'detail' => substr($error, 0, 200)]);
    }
}
reply(200, ['ok' => true]);
