#!/usr/bin/env python3
"""Endurance driver for the goroutine serve model.

Drives a fixed total number of keep-alive GET /hello.txt
requests at a running slanginx from N threads, sampling the
server's VmRSS/VmStk on the way. The acceptance question is
the stage-2 death closure: the sequential model died by
SIGSEGV at 523,128 requests under the default 8 MiB stack
(the accept loop's stack ratchet reached RLIMIT_STACK); the
goroutine model must pass that count alive, with the
dispatcher/acceptor generational rotation carrying it
(600,000 requests = 6 acceptor generations and ~24 dispatcher
generations at the shipped budgets).

Usage:
  ./slanginx &                      # shipped config, port 18090
  python3 docs/repro/endurance_drive.py <server-pid> [total] [threads] [port]

Exit code 0 = target reached with the server alive and a
final GET returning 200; 1 otherwise.
"""
import http.client
import sys
import threading
import time

done = 0
errors = 0
lock = threading.Lock()
stop_monitor = False
samples = []


def proc_fields(pid):
    rss = stk = -1
    with open(f"/proc/{pid}/status") as f:
        for line in f:
            if line.startswith("VmRSS"):
                rss = int(line.split()[1])
            elif line.startswith("VmStk"):
                stk = int(line.split()[1])
    return rss, stk


def worker(port, total, per_thread):
    global done, errors
    local_done = 0
    local_err = 0
    try:
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=15)
        for _ in range(per_thread):
            try:
                conn.request("GET", "/hello.txt")
                resp = conn.getresponse()
                body = resp.read()
                if resp.status == 200 and len(body) == 32:
                    local_done += 1
                else:
                    local_err += 1
            except Exception:
                local_err += 1
                try:
                    conn.close()
                except Exception:
                    pass
                conn = http.client.HTTPConnection("127.0.0.1", port,
                                                  timeout=15)
        conn.close()
    finally:
        with lock:
            done += local_done
            errors += local_err


def monitor(pid):
    while not stop_monitor:
        try:
            rss, stk = proc_fields(pid)
            with lock:
                d = done
            samples.append((d, rss, stk))
        except Exception:
            break
        time.sleep(2)


def main():
    pid = int(sys.argv[1])
    total = int(sys.argv[2]) if len(sys.argv) > 2 else 600000
    threads_n = int(sys.argv[3]) if len(sys.argv) > 3 else 16
    port = int(sys.argv[4]) if len(sys.argv) > 4 else 18090
    per = total // threads_n
    total = per * threads_n
    rss0, stk0 = proc_fields(pid)
    print(f"start: pid={pid} VmRSS={rss0} kB VmStk={stk0} kB "
          f"target={total} threads={threads_n}", flush=True)
    mon = threading.Thread(target=monitor, args=(pid,), daemon=True)
    mon.start()
    t0 = time.time()
    threads = [threading.Thread(target=worker, args=(port, total, per))
               for _ in range(threads_n)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    global stop_monitor
    stop_monitor = True
    elapsed = time.time() - t0
    try:
        rss1, stk1 = proc_fields(pid)
        alive = True
    except Exception:
        rss1 = stk1 = -1
        alive = False
    print(f"requests done={done} errors={errors} "
          f"elapsed={elapsed:.1f}s rps={done / max(elapsed, 0.001):.0f}")
    print(f"end: alive={alive} VmRSS={rss1} kB VmStk={stk1} kB")
    if samples:
        mid = samples[len(samples) // 2]
        print(f"mid sample at ~{mid[0]} req: VmRSS={mid[1]} kB "
              f"VmStk={mid[2]} kB")
    ok = alive and errors == 0 and done == total
    if ok:
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
        conn.request("GET", "/hello.txt")
        resp = conn.getresponse()
        resp.read()
        print(f"final GET status={resp.status}")
        ok = resp.status == 200
        conn.close()
    print("ENDURANCE_PASS" if ok else "ENDURANCE_FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
