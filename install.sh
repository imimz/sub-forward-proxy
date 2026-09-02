#!/usr/bin/env bash
#
# RH Sub-Proxy — SIMPLE installer for an Iran server.
#
# No nginx, no web-stack, nothing that could clash with what's already on the
# box. It runs the tiny forwarder with PHP's OWN built-in web server, on a
# port you choose, managed by a systemd service (auto-restart).
#
# The only dependency is the `php` CLI + its curl extension. If they're missing
# it installs JUST those (php-cli, php-curl) THROUGH your SOCKS5 proxy — so it
# works even on a box with no direct apt access. Nothing else is touched.
#
#   sudo bash install.sh
#   # non-interactive:
#   PORT=8088 TARGET=https://panel1.foreign.com:8000 \
#   SOCKS5=socks5://user:pass@127.0.0.1:8880 sudo -E bash install.sh
#
set -euo pipefail

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; N='\033[0m'
say(){ echo -e "${G}[sub-proxy]${N} $*"; }
warn(){ echo -e "${Y}[sub-proxy]${N} $*"; }
die(){ echo -e "${R}[sub-proxy] $*${N}" >&2; exit 1; }
[ "$(id -u)" = "0" ] || die "Run as root (sudo bash install.sh)."

DIR=/opt/rh-subproxy

PORT="${PORT:-}"
TARGET="${TARGET:-}"
SOCKS5="${SOCKS5:-}"

[ -n "$PORT" ]   || read -rp "Port to listen on [8088]: " PORT
PORT="${PORT:-8088}"
[ -n "$TARGET" ] || read -rp "Original subscription base URL (e.g. https://panel1.foreign.com:8000): " TARGET
if [ -z "${SOCKS5+x}" ] || [ -z "$SOCKS5" ]; then
  read -rp "SOCKS5 proxy [socks5://user:pass@host:port, empty = direct]: " SOCKS5 || true
fi
[ -n "$TARGET" ] || die "target required"

# ── parse the SOCKS5 string into host:port + user/pass (for the forwarder) ──
SHP=""; SUSER=""; SPASS=""; APT_PROXY=""
if [ -n "$SOCKS5" ]; then
  S="${SOCKS5#*://}"                       # strip scheme
  if [[ "$S" == *@* ]]; then
    CREDS="${S%@*}"; SHP="${S##*@}"
    SUSER="${CREDS%%:*}"; SPASS="${CREDS#*:}"
  else
    SHP="$S"
  fi
  APT_PROXY="socks5h://${S}"               # apt resolves DNS via the proxy
fi

# ── ensure php-cli + curl ext (install ONLY if missing, via the proxy) ──
need_php=0
command -v php >/dev/null 2>&1 || need_php=1
if [ "$need_php" = "0" ] && ! php -m 2>/dev/null | grep -qi '^curl$'; then need_php=1; fi
if [ "$need_php" = "1" ]; then
  say "php/php-curl missing — installing just those…"
  if [ -n "$APT_PROXY" ]; then
    echo "Acquire::http::Proxy \"$APT_PROXY\";"  >  /etc/apt/apt.conf.d/99-rh-subproxy
    echo "Acquire::https::Proxy \"$APT_PROXY\";" >> /etc/apt/apt.conf.d/99-rh-subproxy
    say "apt will download via your SOCKS5 ($SHP)…"
  fi
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq || warn "apt update had warnings"
  apt-get install -y -qq php-cli php-curl || die "could not install php-cli/php-curl (is the SOCKS5 reachable?)"
  rm -f /etc/apt/apt.conf.d/99-rh-subproxy
fi
PHP_BIN="$(command -v php)"
php -m | grep -qi '^curl$' || die "php-curl extension still not available"

mkdir -p "$DIR"

# ── write the forwarder ──
say "Writing forwarder…"
cat > "$DIR/index.php" <<'PHPEOF'
<?php
/** RH Sub-Proxy forwarder (served by PHP's built-in server). */
$cfg = require __DIR__ . '/config.php';
if (!function_exists('getallheaders')) {
    function getallheaders(){ $h=[]; foreach($_SERVER as $k=>$v){ if(substr($k,0,5)==='HTTP_') $h[str_replace(' ','-',ucwords(strtolower(str_replace('_',' ',substr($k,5)))))]=$v; } return $h; }
}
$method = $_SERVER['REQUEST_METHOD'] ?? 'GET';
$path   = parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH) ?: '/';
$qs     = (isset($_SERVER['QUERY_STRING']) && $_SERVER['QUERY_STRING'] !== '') ? ('?' . $_SERVER['QUERY_STRING']) : '';
if ($path === '/' || $path === '/healthz' || $path === '/health') { header('Content-Type: text/plain; charset=utf-8'); echo "RH Sub-Proxy is running.\n"; exit; }
$allowed = false;
foreach (($cfg['allow_paths'] ?? []) as $re) { if (@preg_match($re, $path)) { $allowed = true; break; } }
if (!$allowed) { http_response_code(403); header('Content-Type: text/plain; charset=utf-8'); echo "Forbidden\n"; exit; }
$tp = @parse_url($cfg['target']); $origin = (is_array($tp) && !empty($tp['host'])) ? (($tp['scheme'] ?? 'https') . '://' . $tp['host'] . (isset($tp['port']) ? ':' . $tp['port'] : '')) : rtrim($cfg['target'], '/');
$target = $origin . $path . $qs;
$ch = curl_init($target);
if ($ch === false) { http_response_code(500); echo "init error\n"; exit; }
$opts = [
  CURLOPT_RETURNTRANSFER => true, CURLOPT_HEADER => true, CURLOPT_FOLLOWLOCATION => true, CURLOPT_MAXREDIRS => 5,
  CURLOPT_CONNECTTIMEOUT => (int)($cfg['connect_timeout'] ?? 10), CURLOPT_TIMEOUT => (int)($cfg['timeout'] ?? 25),
  CURLOPT_SSL_VERIFYPEER => !empty($cfg['ssl_verify']), CURLOPT_SSL_VERIFYHOST => !empty($cfg['ssl_verify']) ? 2 : 0,
  CURLOPT_CUSTOMREQUEST => $method, CURLOPT_ENCODING => '',
];
if (!empty($cfg['socks5'])) {
  $opts[CURLOPT_PROXY] = $cfg['socks5'];
  $opts[CURLOPT_PROXYTYPE] = defined('CURLPROXY_SOCKS5_HOSTNAME') ? CURLPROXY_SOCKS5_HOSTNAME : 7;
  if (!empty($cfg['socks5_user'])) $opts[CURLOPT_PROXYUSERPWD] = $cfg['socks5_user'] . ':' . ($cfg['socks5_pass'] ?? '');
}
$fwd = []; $skip = ['host','accept-encoding','content-length','connection','x-forwarded-for','x-forwarded-host'];
foreach (getallheaders() as $n => $v) { if (in_array(strtolower($n), $skip, true)) continue; $fwd[] = "$n: $v"; }
if ($fwd) $opts[CURLOPT_HTTPHEADER] = $fwd;
if (in_array($method, ['POST','PUT','PATCH'], true)) $opts[CURLOPT_POSTFIELDS] = file_get_contents('php://input');
curl_setopt_array($ch, $opts);
$resp = curl_exec($ch);
if ($resp === false) { $e = curl_error($ch); curl_close($ch); http_response_code(502); header('Content-Type: text/plain; charset=utf-8'); echo "Sub-Proxy: upstream unreachable\n"; if (!empty($cfg['log'])) @error_log('['.date('Y-m-d H:i:s')."] $e | $target\n",3,__DIR__.'/error.log'); exit; }
$hsz = curl_getinfo($ch, CURLINFO_HEADER_SIZE); $code = curl_getinfo($ch, CURLINFO_HTTP_CODE) ?: 200;
$rawh = substr($resp,0,$hsz); $body = substr($resp,$hsz); curl_close($ch);
http_response_code($code);
$pt = '/^(Content-Type|Content-Disposition|Profile-Update-Interval|Subscription-Userinfo|Profile-Title|Profile-Web-Page-Url|Support-Url|Announce|Routing):/i';
foreach (explode("\r\n", $rawh) as $l) { if ($l === '') continue; if (preg_match($pt, $l)) header($l, false); }
header('Access-Control-Allow-Origin: *');
if (preg_match('#^Content-Type:\s*text/html#im', $rawh)) {
  $poly = '<script>(function(){function f(t){return new Promise(function(r,j){try{var a=document.createElement("textarea");a.value=t;a.setAttribute("readonly","");a.style.position="fixed";a.style.top="-1000px";a.style.opacity="0";document.body.appendChild(a);a.focus();a.select();try{a.setSelectionRange(0,t.length);}catch(e){}var ok=document.execCommand("copy");document.body.removeChild(a);ok?r():j(new Error("copy"));}catch(e){j(e);}});}try{if(!navigator.clipboard||!navigator.clipboard.writeText){Object.defineProperty(navigator,"clipboard",{value:{writeText:f,readText:function(){return Promise.reject(new Error("no"));}},configurable:true});}}catch(e){try{navigator.clipboard={writeText:f};}catch(_){}}})();</script>';
  $body = (stripos($body,'</body>')!==false) ? preg_replace('#</body>#i',$poly.'</body>',$body,1) : ($body.$poly);
}
echo $body;
PHPEOF

# ── write config ──
esc(){ printf '%s' "$1" | sed "s/'/\\\\'/g"; }
cat > "$DIR/config.php" <<EOF
<?php
return [
    'target'          => '$(esc "$TARGET")',
    'socks5'          => '$(esc "$SHP")',
    'socks5_user'     => '$(esc "$SUSER")',
    'socks5_pass'     => '$(esc "$SPASS")',
    'allow_paths'     => [
        '#^/sub(/|\$)#i',
        '#^/sub4me(/|\$)#i',
        '#^/api/sub#i',
        '#^/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+\$#',
    ],
    'ssl_verify'      => false,
    'timeout'         => 25,
    'connect_timeout' => 10,
    'log'             => true,
];
EOF
chown -R www-data:www-data "$DIR" 2>/dev/null || true

# ── systemd service: PHP built-in server, auto-restart ──
say "Creating systemd service…"
cat > /etc/systemd/system/rh-subproxy.service <<EOF
[Unit]
Description=RH Sub-Proxy (PHP built-in server)
After=network.target

[Service]
Environment=PHP_CLI_SERVER_WORKERS=4
ExecStart=$PHP_BIN -d error_reporting=0 -d display_errors=0 -S 0.0.0.0:$PORT -t $DIR $DIR/index.php
Restart=always
RestartSec=3
User=www-data

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now rh-subproxy >/dev/null 2>&1 || systemctl restart rh-subproxy

sleep 1
say "Status:"
systemctl is-active rh-subproxy >/dev/null 2>&1 && say "running ✅" || warn "service not active — check: journalctl -u rh-subproxy -n 30"
echo
say "Test:"
echo "   curl -s http://127.0.0.1:$PORT/healthz        # → RH Sub-Proxy is running."
echo "   curl -s http://<server-ip>:$PORT/sub/<token>  # → the real subscription"
echo
say "Then point the PasarGuard subscription URL prefix at this relay, e.g.:"
echo "   http://<server-ip>:$PORT     (or your domain/Cloudflare in front)"
echo
say "Manage:  systemctl {status|restart|stop} rh-subproxy   |   config: $DIR/config.php"