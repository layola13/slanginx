#!/usr/bin/env python3
"""REPRO driver (defect F1, sa_std HTTP server face).

Drives a fixed number of keep-alive requests at a running
slanginx and prints the server's RSS before/after each phase,
yielding the per-request memory growth slope.

Measured on the M1 bench box (bench config, pid given):
  baseline RSS 9,940 kB
  +300 x GET /hello.txt (32 B body)   -> +8,720 kB  (~29 kB/req)
  +300 x GET /big.txt (210,000 B)    -> +70,136 kB (~234 kB/req
                                        = body + ~24 kB fixed)
The application frees its file buffer every request
(sa_fs_read_buffer_free in src/main.sla); the growth is inside
the std server face's per-request allocations.

Usage:
  ./slanginx &   # bench or normal config
  python3 docs/repro/server_rss_slope.py <server-pid> [port]
"""
import http.client
import sys


def rss_kb(pid):
    with open(f"/proc/{pid}/status") as f:
        for line in f:
            if line.startswith("VmRSS"):
                return int(line.split()[1])
    raise RuntimeError("no VmRSS")


def drive(port, path, n):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    for _ in range(n):
        conn.request("GET", path)
        resp = conn.getresponse()
        resp.read()
        assert resp.status == 200, (path, resp.status)
    conn.close()


def main():
    pid = int(sys.argv[1])
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 18094
    r0 = rss_kb(pid)
    print(f"baseline: {r0} kB")
    drive(port, "/hello.txt", 300)
    r1 = rss_kb(pid)
    print(f"after 300x /hello.txt: {r1} kB  slope {(r1 - r0) * 1024 // 300} B/req")
    drive(port, "/big.txt", 300)
    r2 = rss_kb(pid)
    print(f"after 300x /big.txt:   {r2} kB  slope {(r2 - r1) * 1024 // 300} B/req")


if __name__ == "__main__":
    main()
