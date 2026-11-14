<?php
/**
 * RH Sub-Proxy — Iran-side subscription forwarder
 * ------------------------------------------------
 * Runs on an Iran server that users CAN reach, and transparently forwards
 * subscription requests to the original (foreign / filtered) subscription
 * server — optionally THROUGH a SOCKS5 proxy that is able to reach it.
 *
 * Flow:
 *   user (Iran)  ──►  https://iran-domain/sub/<token>
 *                        │  (this script)
 *                        ▼  curl over SOCKS5
 *                     https://panel.foreign:8000/sub/<token>   (original)
 *                        │
 *                        ▼  config list / clash / base64 …
 *   user gets the subscription content from the Iran domain.
 *
 * Why: the foreign sub URL is heavily filtered for end-users in Iran; the
 * Iran box reaches it (directly, or via the SOCKS5) and relays the bytes.
 *
 * Security: this is NOT an open proxy — only paths matching `allow_paths`
 * in config.php are forwarded. The original UA is preserved so the upstream
 * panel returns the right format (v2ray / clash / sing-box / base64), and
 * the subscription metadata headers (usage, expiry, title) are passed back.
 */

$cfg = require __DIR__ . '/config.php';

$method = $_SERVER['REQUEST_METHOD'] ?? 'GET';
$path   = parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH) ?: '/';
$qs     = (isset($_SERVER['QUERY_STRING']) && $_SERVER['QUERY_STRING'] !== '') ? ('?' . $_SERVER['QUERY_STRING']) : '';

// ── health check ──
if ($path === '/' || $path === '/healthz' || $path === '/health') {
    header('Content-Type: text/plain; charset=utf-8');
    echo "RH Sub-Proxy is running.\n";
    exit;
}

// ── optional per-path upstreams, e.g. an emergency-charge service on the panel ──
$routeTarget = null;
foreach (($cfg['routes'] ?? []) as $re => $dest) {
    if (@preg_match($re, $path)) { $routeTarget = $dest; break; }
}

// ── allow-list: never act as an open proxy ──
$allowed = $routeTarget !== null;
foreach (($cfg['allow_paths'] ?? []) as $re) {
    if (@preg_match($re, $path)) { $allowed = true; break; }
}
if (!$allowed) {
    http_response_code(403);
    header('Content-Type: text/plain; charset=utf-8');
    echo "Forbidden\n";
    exit;
}

// Normalise the configured target down to its ORIGIN (scheme://host[:port]),
// ignoring any path the admin may have accidentally appended (e.g. ".../sub/"),
// so we never produce a doubled path like ".../sub//sub/<token>".
$base = $routeTarget ?? $cfg['target'];
$tp = @parse_url($base);
if (is_array($tp) && !empty($tp['host'])) {
    $origin = ($tp['scheme'] ?? 'https') . '://' . $tp['host'] . (isset($tp['port']) ? ':' . $tp['port'] : '');
} else {
    $origin = rtrim($base, '/');
}
$target = $origin . $path . $qs;

$ch = curl_init($target);
if ($ch === false) {
    http_response_code(500);
    echo "init error\n";
    exit;
}

$opts = [
    CURLOPT_RETURNTRANSFER => true,
    CURLOPT_HEADER         => true,
    CURLOPT_FOLLOWLOCATION => true,
    CURLOPT_MAXREDIRS      => 5,
    CURLOPT_CONNECTTIMEOUT => (int) ($cfg['connect_timeout'] ?? 10),
    CURLOPT_TIMEOUT        => (int) ($cfg['timeout'] ?? 25),
    CURLOPT_SSL_VERIFYPEER => !empty($cfg['ssl_verify']),
    CURLOPT_SSL_VERIFYHOST => !empty($cfg['ssl_verify']) ? 2 : 0,
    CURLOPT_CUSTOMREQUEST  => $method,
    CURLOPT_ENCODING       => '',   // accept gzip and let curl decode
];

// ── route through a SOCKS5 proxy when configured ──
if (!empty($cfg['socks5'])) {
    $opts[CURLOPT_PROXY] = $cfg['socks5'];                  // e.g. 127.0.0.1:1080
    // SOCKS5_HOSTNAME = resolve the target's DNS THROUGH the proxy (important
    // when the upstream domain itself is filtered/poisoned in Iran).
    $opts[CURLOPT_PROXYTYPE] = defined('CURLPROXY_SOCKS5_HOSTNAME') ? CURLPROXY_SOCKS5_HOSTNAME : 7;
    if (!empty($cfg['socks5_user'])) {
        $opts[CURLOPT_PROXYUSERPWD] = $cfg['socks5_user'] . ':' . ($cfg['socks5_pass'] ?? '');
    }
}

// ── forward the client's headers (UA decides the sub format) ──
$fwd = [];
$skip = ['host', 'accept-encoding', 'content-length', 'connection', 'x-forwarded-for', 'x-forwarded-host'];
foreach ((function_exists('getallheaders') ? getallheaders() : []) as $name => $value) {
    if (in_array(strtolower($name), $skip, true)) continue;
    $fwd[] = "$name: $value";
}
if (!empty($fwd)) $opts[CURLOPT_HTTPHEADER] = $fwd;

if (in_array($method, ['POST', 'PUT', 'PATCH'], true)) {
    $opts[CURLOPT_POSTFIELDS] = file_get_contents('php://input');
}

curl_setopt_array($ch, $opts);
$resp = curl_exec($ch);

if ($resp === false) {
    $err = curl_error($ch);
    curl_close($ch);
    http_response_code(502);
    header('Content-Type: text/plain; charset=utf-8');
    echo "Sub-Proxy: upstream unreachable\n";
    if (!empty($cfg['log'])) {
        @error_log('[' . date('Y-m-d H:i:s') . "] $err | target=$target\n", 3, __DIR__ . '/error.log');
    }
    exit;
}

$headerSize = curl_getinfo($ch, CURLINFO_HEADER_SIZE);
$httpCode   = curl_getinfo($ch, CURLINFO_HTTP_CODE) ?: 200;
$rawHeaders = substr($resp, 0, $headerSize);
$body       = substr($resp, $headerSize);
curl_close($ch);

// ── relay status + the headers that matter for VPN clients ──
http_response_code($httpCode);
$passThrough = '/^(Content-Type|Content-Disposition|Profile-Update-Interval|Subscription-Userinfo|Profile-Title|Profile-Web-Page-Url|Support-Url|Announce|Routing|Cache-Control|Expires|Last-Modified):/i';
foreach (explode("\r\n", $rawHeaders) as $line) {
    if ($line === '') continue;
    if (preg_match($passThrough, $line)) header($line, false);
}
// CORS so browser-based clients / the mini-app can fetch it too
header('Access-Control-Allow-Origin: *');

// HTTP-mode clipboard fix: the subscription PAGE uses navigator.clipboard,
// which browsers DISABLE on non-HTTPS origins (so "copy config" says
// "clipboard not supported"). Inject a tiny polyfill that falls back to
// execCommand('copy') — works over plain HTTP. (We don't pass through the
// upstream Content-Length, so changing the body length is safe.)
if (preg_match('#^Content-Type:\s*text/html#im', $rawHeaders)) {
    $poly = '<script>(function(){function f(t){return new Promise(function(r,j){try{var a=document.createElement("textarea");a.value=t;a.setAttribute("readonly","");a.style.position="fixed";a.style.top="-1000px";a.style.opacity="0";document.body.appendChild(a);a.focus();a.select();try{a.setSelectionRange(0,t.length);}catch(e){}var ok=document.execCommand("copy");document.body.removeChild(a);ok?r():j(new Error("copy"));}catch(e){j(e);}});}try{if(!navigator.clipboard||!navigator.clipboard.writeText){Object.defineProperty(navigator,"clipboard",{value:{writeText:f,readText:function(){return Promise.reject(new Error("no"));}},configurable:true});}}catch(e){try{navigator.clipboard={writeText:f};}catch(_){}}})();</script>';
    if (stripos($body, '</body>') !== false) {
        $body = preg_replace('#</body>#i', $poly . '</body>', $body, 1);
    } else {
        $body .= $poly;
    }
}

echo $body;