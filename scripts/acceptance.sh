#!/usr/bin/env bash
# slanginx M0 live acceptance: builds nothing, expects ./slanginx
# (copied from src/main) in the repo root. Drives the real server
# with curl across three runs:
#   run 1: shipped slanginx.toml (port 18090, root www)
#   run 2: alt TOML: port 18091 + max_file_bytes=1024 (streaming path)
#   run 3: alt TOML: port 18092 + root www-assets (TOML root change)
# Prints PASS/FAIL per check; exit code = number of failures (0=ok).
set -u
cd "$(dirname "$0")/.."
FAIL=0
ok()   { echo "PASS $1"; }
bad()  { echo "FAIL $1"; FAIL=$((FAIL+1)); }

wait_port_free() {
  local port=$1 i pid comm
  for i in $(seq 1 20); do
    if ! ss -tln 2>/dev/null | grep -q ":$port "; then return 0; fi
    sleep 0.5
  done
  # Reap a leftover slanginx listener (e.g. from a manual probe);
  # never touch any other process.
  pid=$(ss -tlnp 2>/dev/null | grep ":$port " | grep -oP 'pid=\K[0-9]+' | head -1)
  if [ -n "$pid" ]; then
    comm=$(cat /proc/$pid/comm 2>/dev/null || true)
    if [ "$comm" = "slanginx" ]; then
      echo "reaping stale slanginx pid $pid on port $port"
      kill "$pid" 2>/dev/null; sleep 1
      ss -tln 2>/dev/null | grep -q ":$port " || return 0
    fi
  fi
  echo "port $port still bound"; ss -tlnp 2>/dev/null | grep ":$port " || true
  return 1
}

start_server() { # config_env_value log_file
  if [ -n "$1" ]; then
    SLANGINX_CONFIG="$1" setsid nohup ./slanginx > "$2" 2>&1 &
  else
    setsid nohup ./slanginx > "$2" 2>&1 &
  fi
  echo $!
}

first_get() { # port path outfile
  curl -s --path-as-is --retry 30 --retry-connrefused --retry-delay 1 \
       --retry-max-time 40 -o "$3" "http://127.0.0.1:$1$2"
}

stop_server() { # pid port
  kill "$1" 2>/dev/null
  wait_port_free "$2" >/dev/null 2>&1 || true
}

[ -x ./slanginx ] || { echo "no ./slanginx binary (copy src/main first)"; exit 99; }

# ================= run 1 =================
echo "=== run 1: shipped slanginx.toml (port 18090, root www) ==="
rm -f logs/access.log
wait_port_free 18090 || exit 98
PID=$(start_server "" /tmp/slanginx_run1.log)
echo "server pid $PID"
B=http://127.0.0.1:18090

code=$(first_get 18090 /hello.txt /tmp/r1_hello); 
[ "$code" = "" ] && code=000
got=$(curl -s --path-as-is -o /tmp/r1_hello -w "%{http_code}" $B/hello.txt)
[ "$got" = 200 ] && cmp -s /tmp/r1_hello www/hello.txt && ok "GET /hello.txt 200 byte-exact" || bad "GET /hello.txt ($got)"

got=$(curl -s --path-as-is -o /tmp/r1_idx -w "%{http_code}" $B/)
[ "$got" = 200 ] && cmp -s /tmp/r1_idx www/index.html && ok "GET / serves index.html" || bad "GET / ($got)"

curl -s --path-as-is -D /tmp/r1_blob.hdr -o /tmp/r1_blob $B/blob.bin >/dev/null
cmp -s /tmp/r1_blob www/blob.bin && ok "GET /blob.bin byte-exact (sha256 $(sha256sum /tmp/r1_blob | cut -c1-16) == $(sha256sum www/blob.bin | cut -c1-16))" || bad "GET /blob.bin body differs"
grep -qi "^content-type: application/octet-stream" /tmp/r1_blob.hdr && ok "blob.bin content-type octet-stream" || bad "blob.bin content-type: $(grep -i '^content-type' /tmp/r1_blob.hdr)"

curl -s --path-as-is -D /tmp/r1_css.hdr -o /dev/null $B/style.css >/dev/null
grep -qi "^content-type: text/css" /tmp/r1_css.hdr && ok "style.css content-type text/css" || bad "style.css content-type"

curl -s -I --path-as-is $B/hello.txt > /tmp/r1_head.hdr
grep -q "200" /tmp/r1_head.hdr && ok "HEAD /hello.txt 200" || bad "HEAD status: $(head -1 /tmp/r1_head.hdr)"
grep -qi "^content-type: text/plain" /tmp/r1_head.hdr && ok "HEAD content-type text/plain" || bad "HEAD content-type"
# HEAD must not put body bytes on the wire (raw socket check).
python3 - <<'PYEOF' && ok "HEAD response carries no body bytes" || bad "HEAD response carried body bytes"
import socket, sys
s = socket.create_connection(("127.0.0.1", 18090), timeout=10)
s.sendall(b"HEAD /hello.txt HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
data = b""
while True:
    try:
        chunk = s.recv(4096)
    except socket.timeout:
        break
    if not chunk:
        break
    data += chunk
head, _, body = data.partition(b"\r\n\r\n")
# chunked terminator "0\r\n\r\n" is framing, not body
sys.exit(0 if body in (b"", b"0\r\n\r\n") else 1)
PYEOF

got=$(curl -s --path-as-is -o /dev/null -w "%{http_code}" $B/missing.txt)
[ "$got" = 404 ] && ok "GET /missing.txt 404" || bad "GET /missing.txt ($got)"

got=$(curl -s --path-as-is -o /tmp/r1_trav -w "%{http_code}" "$B/../slanginx.toml")
[ "$got" = 403 ] || [ "$got" = 404 ] && ok "GET /../slanginx.toml blocked ($got)" || bad "traversal raw .. returned $got"
grep -q "server" /tmp/r1_trav && bad "traversal leaked config body" || true

got=$(curl -s --path-as-is -o /dev/null -w "%{http_code}" "$B/%2e%2e/slanginx.toml")
[ "$got" = 403 ] || [ "$got" = 404 ] && ok "GET /%2e%2e/slanginx.toml blocked ($got)" || bad "traversal %%2e returned $got"

got=$(curl -s --path-as-is -o /dev/null -w "%{http_code}" "$B/a/../../slanginx.toml")
[ "$got" = 403 ] || [ "$got" = 404 ] && ok "GET /a/../../slanginx.toml blocked ($got)" || bad "traversal mid-path returned $got"

got=$(curl -s --path-as-is -o /tmp/r1_secret -w "%{http_code}" $B/internal/secret.txt)
[ "$got" = 403 ] && ok "GET /internal/secret.txt 403 (code-layer deny, file exists on disk)" || bad "GET /internal/secret.txt ($got)"
grep -q "TOP SECRET" /tmp/r1_secret && bad "deny rule leaked secret body" || true

got=$(curl -s --path-as-is -o /tmp/r1_logo -w "%{http_code}" $B/assets/logo.txt)
[ "$got" = 200 ] && cmp -s /tmp/r1_logo www-assets/logo.txt && ok "GET /assets/logo.txt served from alt root (code-layer alias)" || bad "GET /assets/logo.txt ($got)"

got=$(curl -s --path-as-is -o /tmp/r1_only -w "%{http_code}" $B/assets/only-here.txt)
[ "$got" = 200 ] && cmp -s /tmp/r1_only www-assets/only-here.txt && ok "GET /assets/only-here.txt 200 (exists only in alt root)" || bad "GET /assets/only-here.txt ($got)"

got=$(curl -s --path-as-is -o /tmp/r1_aidx -w "%{http_code}" $B/assets/)
[ "$got" = 200 ] && cmp -s /tmp/r1_aidx www-assets/index.html && ok "GET /assets/ serves alt root index" || bad "GET /assets/ ($got)"

got=$(curl -s --path-as-is -A "slanginx-acceptance/1.0" -o /tmp/r1_big -w "%{http_code}" $B/big.txt)
[ "$got" = 200 ] && cmp -s /tmp/r1_big www/big.txt && ok "GET /big.txt 200 byte-exact (buffered path)" || bad "GET /big.txt ($got)"

got=$(curl -s --path-as-is -X POST -o /dev/null -w "%{http_code}" $B/hello.txt)
[ "$got" = 405 ] && ok "POST 405" || bad "POST ($got)"

stop_server "$PID" 18090
echo "--- run 1 server log:"; cat /tmp/slanginx_run1.log
echo "--- run 1 access log:"; cat logs/access.log
grep -q "GET /hello.txt 200 32" logs/access.log && ok "access log: hello.txt 200 32 bytes" || bad "access log hello line"
grep -q "GET /missing.txt 404 10" logs/access.log && ok "access log: missing.txt 404 10 bytes" || bad "access log 404 line"
grep -q "GET /internal/secret.txt 403 10" logs/access.log && ok "access log: secret.txt 403" || bad "access log 403 line"
grep -q "slanginx-acceptance/1.0" logs/access.log && ok "access log: user-agent recorded" || bad "access log UA missing"
grep -q "GET /big.txt 200 210000" logs/access.log && ok "access log: big.txt 200 210000 bytes" || bad "access log big line"

# ================= run 2 =================
echo "=== run 2: alt TOML port 18091, max_file_bytes=1024 (streaming path) ==="
cat > /tmp/slanginx_alt.toml <<'EOF'
[server]
host = "127.0.0.1"
port = 18091
root = "www"
index = "index.html"
access_log = "logs/alt-access.log"
max_file_bytes = 1024
EOF
rm -f logs/alt-access.log
wait_port_free 18091 || exit 98
PID=$(start_server /tmp/slanginx_alt.toml /tmp/slanginx_run2.log)
echo "server pid $PID"
B=http://127.0.0.1:18091
got=$(curl -s --path-as-is --retry 30 --retry-connrefused --retry-delay 1 --retry-max-time 40 -o /tmp/r2_big -w "%{http_code}" $B/big.txt)
[ "$got" = 200 ] && cmp -s /tmp/r2_big www/big.txt && ok "run2 GET /big.txt 200 byte-exact over streaming path (cap 1024)" || bad "run2 GET /big.txt ($got)"
got=$(curl -s --path-as-is -o /tmp/r2_blob -w "%{http_code}" $B/blob.bin)
[ "$got" = 200 ] && cmp -s /tmp/r2_blob www/blob.bin && ok "run2 GET /blob.bin byte-exact over streaming path" || bad "run2 GET /blob.bin ($got)"
got=$(curl -s --path-as-is -o /tmp/r2_hello -w "%{http_code}" $B/hello.txt)
[ "$got" = 200 ] && cmp -s /tmp/r2_hello www/hello.txt && ok "run2 GET /hello.txt 200 on new port (TOML port change live)" || bad "run2 GET /hello.txt ($got)"
stop_server "$PID" 18091
echo "--- run 2 server log:"; cat /tmp/slanginx_run2.log

# ================= run 3 =================
echo "=== run 3: alt TOML port 18092, root www-assets (TOML root change) ==="
cat > /tmp/slanginx_root.toml <<'EOF'
[server]
host = "127.0.0.1"
port = 18092
root = "www-assets"
index = "index.html"
access_log = "logs/alt-access.log"
max_file_bytes = 33554432
EOF
wait_port_free 18092 || exit 98
PID=$(start_server /tmp/slanginx_root.toml /tmp/slanginx_run3.log)
echo "server pid $PID"
B=http://127.0.0.1:18092
got=$(curl -s --path-as-is --retry 30 --retry-connrefused --retry-delay 1 --retry-max-time 40 -o /tmp/r3_idx -w "%{http_code}" $B/)
[ "$got" = 200 ] && cmp -s /tmp/r3_idx www-assets/index.html && ok "run3 GET / serves www-assets/index.html (TOML root change live)" || bad "run3 GET / ($got)"
got=$(curl -s --path-as-is -o /dev/null -w "%{http_code}" $B/hello.txt)
[ "$got" = 404 ] && ok "run3 GET /hello.txt 404 (not in new root)" || bad "run3 GET /hello.txt ($got)"
stop_server "$PID" 18092
echo "--- run 3 server log:"; cat /tmp/slanginx_run3.log

echo "=== acceptance done: FAIL count = $FAIL ==="
exit $FAIL
