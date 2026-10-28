#!/usr/bin/env bash
# slanginx vs native nginx benchmark gate (see README.md in
# this directory for the method and the T50 thresholds).
#
# Runs, on this one machine, serially:
#   nginx (apt, config from nginx-bench.conf.tmpl)
#   slanginx (./slanginx with slanginx-bench.toml)
#   the trivial python fixture (proxy-scenario ceiling, info)
# Scenarios: static small /hello.txt, static large /big.txt
# (210,000 B), reverse proxy /api/hello to the fixture.
# Concurrency tiers: 1, 10, 50. Per cell: 1 warmup run
# (discarded) + 3 measured runs of BENCH_DUR (default 5s),
# median reported. Tool: wrk, 2 threads.
#
# Output: a TSV + human table on stdout and in $BENCH_OUT
# (default /tmp/bench-results). Exit code: 0 = gate passed,
# 1 = gate failed, 99 = environment problem.
set -u
cd "$(dirname "$0")/../.."
REPO=$PWD
OUT=${BENCH_OUT:-/tmp/bench-results}
DUR=${BENCH_DUR:-5s}
mkdir -p "$OUT" /tmp/bench-nginx
TSV="$OUT/results.tsv"
: > "$TSV"

command -v wrk >/dev/null || { echo "wrk not installed"; exit 99; }
command -v nginx >/dev/null || { echo "nginx not installed"; exit 99; }
[ -x ./slanginx ] || { echo "no ./slanginx binary (build first)"; exit 99; }
pgrep -af "zig build" && echo "WARN: a zig build is running on this box; numbers may be skewed" || true

conv_ms() {
  local v=$1
  case "$v" in
    *us) printf "%.3f" "$(echo "${v%us}" | awk '{print $1/1000}')" ;;
    *ms) echo "${v%ms}" ;;
    *s)  printf "%.3f" "$(echo "${v%s}" | awk '{print $1*1000}')" ;;
    *)   echo "$v" ;;
  esac
}

wrk_once() { # url c -> "rps p50ms p99ms"
  local f rps p50 p99 t=2
  [ "$2" -lt 2 ] && t=1   # wrk: connections must be >= threads
  f=$(mktemp)
  wrk -t$t -c"$2" -d"$DUR" --latency "$1" > "$f" 2>&1
  rps=$(awk '/Requests\/sec:/ {print $2}' "$f")
  p50=$(awk '/Latency Distribution/{g=1} g && $1=="50%" {print $2; exit}' "$f")
  p99=$(awk '/Latency Distribution/{g=1} g && $1=="99%" {print $2; exit}' "$f")
  rm -f "$f"
  echo "$rps $(conv_ms "$p50") $(conv_ms "$p99")"
}

median3() { printf "%s\n" "$1" "$2" "$3" | sort -n | sed -n 2p; }

# cell <server> <scenario> <c> <url>
cell() {
  local server=$1 scen=$2 c=$3 url=$4
  wrk_once "$url" "$c" > /dev/null   # warmup, discarded
  local r1 r2 r3
  r1=$(wrk_once "$url" "$c"); r2=$(wrk_once "$url" "$c"); r3=$(wrk_once "$url" "$c")
  local rps p50 p99
  rps=$(median3 "$(echo $r1 | cut -d' ' -f1)" "$(echo $r2 | cut -d' ' -f1)" "$(echo $r3 | cut -d' ' -f1)")
  p50=$(median3 "$(echo $r1 | cut -d' ' -f2)" "$(echo $r2 | cut -d' ' -f2)" "$(echo $r3 | cut -d' ' -f2)")
  p99=$(median3 "$(echo $r1 | cut -d' ' -f3)" "$(echo $r2 | cut -d' ' -f3)" "$(echo $r3 | cut -d' ' -f3)")
  echo -e "$server\t$scen\t$c\t$rps\t$p50\t$p99" >> "$TSV"
  echo "cell $server $scen c=$c -> rps=$rps p50=${p50}ms p99=${p99}ms   (rounds: $r1 | $r2 | $r3)"
}

port_free() { ! ss -tln 2>/dev/null | grep -q ":$1 "; }
for p in 18094 18095 19001; do
  port_free "$p" || { echo "port $p busy"; exit 99; }
done

# ---- servers up ----
sed "s|@REPO@|$REPO|g; s|@PREFIX@|/tmp/bench-nginx|g" scripts/bench/nginx-bench.conf.tmpl > /tmp/bench-nginx/nginx.conf
setsid nohup nginx -c /tmp/bench-nginx/nginx.conf -p /tmp/bench-nginx -g 'daemon off;' > /tmp/bench-nginx/console.log 2>&1 &
NG=$!
setsid nohup python3 scripts/upstream_fixture.py 19001 A > /tmp/bench_fixture.log 2>&1 &
FA=$!
rm -f logs/bench-access.log
SLANGINX_CONFIG=scripts/bench/slanginx-bench.toml setsid nohup ./slanginx > /tmp/bench_slanginx.log 2>&1 &
SX=$!
echo "pids: nginx=$NG fixture=$FA slanginx=$SX"
curl -s --retry 30 --retry-connrefused --retry-delay 1 --retry-max-time 40 -o /dev/null http://127.0.0.1:18095/hello.txt || { echo "nginx did not come up"; kill $NG $FA $SX 2>/dev/null; exit 99; }
curl -s --retry 30 --retry-connrefused --retry-delay 1 --retry-max-time 40 -o /dev/null http://127.0.0.1:19001/hello || { echo "fixture did not come up"; kill $NG $FA $SX 2>/dev/null; exit 99; }
curl -s --retry 30 --retry-connrefused --retry-delay 1 --retry-max-time 40 -o /dev/null http://127.0.0.1:18094/hello.txt || { echo "slanginx did not come up"; kill $NG $FA $SX 2>/dev/null; exit 99; }

NGINX_BASE=http://127.0.0.1:18095
SLANGINX_BASE=http://127.0.0.1:18094
for C in 1 10 50; do
  cell nginx    small $C "$NGINX_BASE/hello.txt"
  cell slanginx small $C "$SLANGINX_BASE/hello.txt"
done
for C in 1 10 50; do
  cell nginx    large $C "$NGINX_BASE/big.txt"
  cell slanginx large $C "$SLANGINX_BASE/big.txt"
done
for C in 1 10 50; do
  cell nginx    proxy $C "$NGINX_BASE/api/hello"
  cell slanginx proxy $C "$SLANGINX_BASE/api/hello"
  cell fixture  proxy $C "http://127.0.0.1:19001/hello"
done

kill $SX $FA $NG 2>/dev/null
sleep 1

# ---- verdict (T50: per row, slanginx rps >= 0.5 * nginx rps
# ---- and slanginx p99 <= 2 * nginx p99; fixture rows exempt)
echo
echo "| scenario | c | nginx rps | slanginx rps | ratio | nginx p50 | slanginx p50 | nginx p99 | slanginx p99 | p99 ratio | verdict |"
echo "|---|---|---|---|---|---|---|---|---|---|---|"
GATE=0
for scen in small large proxy; do
  for C in 1 10 50; do
    n=$(awk -F'\t' -v s="$scen" -v c="$C" '$1=="nginx" && $2==s && $3==c' "$TSV")
    x=$(awk -F'\t' -v s="$scen" -v c="$C" '$1=="slanginx" && $2==s && $3==c' "$TSV")
    nrps=$(echo "$n" | cut -f4); np50=$(echo "$n" | cut -f5); np99=$(echo "$n" | cut -f6)
    xrps=$(echo "$x" | cut -f4); xp50=$(echo "$x" | cut -f5); xp99=$(echo "$x" | cut -f6)
    read -r ratio p99ratio verdict <<< "$(awk -v nr="$nrps" -v xr="$xrps" -v np="$np99" -v xp="$xp99" 'BEGIN{
      r = (nr > 0) ? xr/nr : 0; q = (np > 0) ? xp/np : 999;
      v = (r >= 0.5 && q <= 2.0) ? "PASS" : "FAIL";
      printf "%.3f %.2f %s", r, q, v }')"
    [ "$verdict" = "FAIL" ] && GATE=1
    echo "| $scen | $C | $nrps | $xrps | $ratio | ${np50}ms | ${xp50}ms | ${np99}ms | ${xp99}ms | $p99ratio | $verdict |"
  done
done
echo
echo "fixture ceiling (proxy scenario, informational):"
awk -F'\t' '$1=="fixture" {print "  c=" $3 " rps=" $4 " p50=" $5 "ms p99=" $6 "ms"}' "$TSV"
if [ "$GATE" = 0 ]; then echo "BENCH GATE: PASS"; else echo "BENCH GATE: FAIL"; fi
exit $GATE
