#!/usr/bin/env python3
"""deploy.sh status: what a target server runs and whether its sites answer.

  python3 - probe < status.py         runs on the target (as root when sudo allows it), prints JSON
  python3 status.py render [--color]  runs here, reads that JSON on stdin and prints the report

Read-only: nothing on the target is changed.
"""
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import time


def run(cmd, timeout=10):
    """(exit code, stdout, stderr) of cmd; 127 when it cannot run."""
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout.strip(), p.stderr.strip()
    except (OSError, subprocess.TimeoutExpired) as e:
        return 127, "", str(e)


def read(path, default=""):
    try:
        with open(path) as f:
            return f.read()
    except OSError:
        return default


def read_json(path):
    try:
        return json.loads(read(path, "null"))
    except ValueError:
        return None


# ---------------------------------------------------------------- probe (on the target)
def probe():
    res = {"root": os.geteuid() == 0, "time": int(time.time())}

    osr = dict(re.findall(r'^(\w+)="?([^"\n]*)"?', read("/etc/os-release"), re.M))
    mem = dict(re.findall(r"^(\w+):\s+(\d+) kB", read("/proc/meminfo"), re.M))
    du = shutil.disk_usage("/")
    res["host"] = {
        "name": os.uname().nodename,
        "os": osr.get("PRETTY_NAME", "?"),
        "kernel": os.uname().release,
        "uptime_s": int(float(read("/proc/uptime", "0").split()[0] or 0)),
        "load": read("/proc/loadavg", "? ? ?").split()[:3],
        "cpus": os.cpu_count(),
        "mem_total_mb": int(mem.get("MemTotal", 0)) // 1024,
        "mem_avail_mb": int(mem.get("MemAvailable", 0)) // 1024,
        "disk_total_gb": round(du.total / 2**30, 1),
        "disk_free_gb": round(du.free / 2**30, 1),
    }

    # Addresses: the one used for outgoing traffic, and every global address
    ips = {"primary": "", "all": []}
    rc, out, _ = run(["ip", "-4", "route", "get", "1.1.1.1"])
    m = re.search(r"\bsrc (\S+)", out)
    if m:
        ips["primary"] = m.group(1)
    rc, out, _ = run(["ip", "-o", "addr", "show", "scope", "global"])
    for line in out.splitlines():
        f = line.split()
        if len(f) >= 4 and not f[1].startswith(("docker", "br-", "veth")):
            ips["all"].append({"dev": f[1], "addr": f[3].split("/")[0]})
    res["ips"] = ips

    res["marker"] = read("/etc/deployer/setup").strip()
    res["profile"] = read_json("/etc/deployer/server.json") or {}

    # Services on the host
    units = ["nginx", "redis-server", "mariadb", "docker"]
    units += sorted(d.split("/")[3] for d in glob.glob("/etc/php/*/fpm/"))
    svc = []
    for u in units:
        name = "php%s-fpm" % u if re.match(r"^\d+\.\d+$", u) else u
        rc, state, _ = run(["systemctl", "is-active", name])
        if state in ("", "unknown") or rc == 127:
            continue
        rc, enabled, _ = run(["systemctl", "is-enabled", name])
        restart = os.path.exists("/etc/systemd/system/%s.service.d/deployer-restart.conf" % name)
        svc.append({"name": name, "state": state, "enabled": enabled, "auto_restart": restart})
    res["services"] = svc

    # Containers
    cont = []
    if shutil.which("docker"):
        rc, out, _ = run(["docker", "ps", "-a", "--format", "{{.Names}}\t{{.State}}\t{{.Status}}\t{{.Image}}"])
        for line in out.splitlines():
            f = line.split("\t")
            if len(f) == 4:
                cont.append({"name": f[0], "state": f[1], "status": f[2], "image": f[3]})
    res["containers"] = cont

    # nginx: config test and Cloudflare real IP, for whichever nginx runs
    ng = {"where": "", "test_rc": None, "test": "", "realip": False}
    docker_ng = any(c["name"] == "enzipe-nginx" and c["state"] == "running" for c in cont)
    if docker_ng:
        ng["where"] = "docker (enzipe-nginx)"
        rc, out, err = run(["docker", "exec", "enzipe-nginx", "nginx", "-t"])
        ng["realip"] = "real_ip_header" in read("/opt/docker-stack/nginx/conf/nginx.conf")
    elif shutil.which("nginx"):
        ng["where"] = "native"
        rc, out, err = run(["nginx", "-t"])
        ng["realip"] = os.path.exists("/etc/nginx/conf.d/deployer-realip.conf")
    else:
        rc, err = None, ""
    if rc is not None:
        ng["test_rc"] = rc
        lines = [l for l in err.splitlines() if "syntax is ok" not in l and "test is successful" not in l]
        ng["test"] = "\n".join(lines[-5:])
    res["nginx"] = ng

    # Sites recorded by the deployer, and whether they answer on this server
    sites = []
    for sf in sorted(glob.glob("/etc/deployer/sites/*.json")):
        d = read_json(sf)
        if not isinstance(d, dict):
            continue
        dom = d.get("domain") or os.path.basename(sf)[:-5]
        s = {k: d.get(k) for k in ("domain", "setup", "php_version", "environment", "tls_mode",
                                   "traffic", "status", "last_deploy", "aliases")}
        s["domain"] = dom
        if d.get("status") != "stopped" and shutil.which("curl"):
            for scheme, port in (("http", 80), ("https", 443)):
                if scheme == "https" and (d.get("tls_mode") or "none") == "none":
                    continue
                rc, code, _ = run(["curl", "-sk", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "8",
                                   "--resolve", "%s:%d:127.0.0.1" % (dom, port), "%s://%s/" % (scheme, dom)], 12)
                s[scheme] = code if rc == 0 else "no answer"
        cert = "/etc/nginx/cert/%s/certificate.crt" % dom
        if not os.path.exists(cert):
            cert = "/etc/ssl/deployer/%s/fullchain.pem" % dom
        if os.path.exists(cert):
            rc, out, _ = run(["openssl", "x509", "-in", cert, "-noout", "-enddate"])
            if rc == 0 and "=" in out:
                rc2, ep, _ = run(["date", "-d", out.split("=", 1)[1], "+%s"])
                if rc2 == 0:
                    s["cert_days"] = (int(ep) - res["time"]) // 86400
        sites.append(s)
    res["sites"] = sites
    print(json.dumps(res))


# ---------------------------------------------------------------- render (here)
def render(color):
    data = json.load(sys.stdin)
    G, Y, R, B, O = ("\033[32m", "\033[33m", "\033[31m", "\033[1m", "\033[0m") if color else ("",) * 5

    def good(t): return G + t + O
    def bad(t): return R + t + O
    def meh(t): return Y + t + O

    def head(t):
        print("\n" + B + t + O)

    h = data["host"]
    up = h["uptime_s"]
    head("Server  %s" % h["name"])
    print("  OS        %s (kernel %s)" % (h["os"], h["kernel"]))
    print("  Up        %dd %dh, load %s, %s CPU" % (up // 86400, up % 86400 // 3600, " ".join(h["load"]), h["cpus"]))
    mem_used = 100 - (100 * h["mem_avail_mb"] // max(h["mem_total_mb"], 1))
    disk_used = 100 - int(100 * h["disk_free_gb"] / max(h["disk_total_gb"], 0.1))
    mem_t = "%d%% used of %d MB" % (mem_used, h["mem_total_mb"])
    disk_t = "%d%% used of %s GB (%s GB free)" % (disk_used, h["disk_total_gb"], h["disk_free_gb"])
    print("  Memory    %s" % (bad(mem_t) if mem_used >= 90 else mem_t))
    print("  Disk /    %s" % (bad(disk_t) if disk_used >= 90 else meh(disk_t) if disk_used >= 80 else disk_t))
    ips = data["ips"]
    others = [a["addr"] for a in ips["all"] if a["addr"] != ips["primary"]]
    print("  IP        %s%s" % (ips["primary"] or "?", ("  (also " + ", ".join(others) + ")") if others else ""))

    p = data.get("profile") or {}
    head("Setup  %s" % (data.get("marker") or p.get("setup") or "not set up by the deployer"))
    comp = p.get("components") or {}
    for name, c in sorted(comp.items()):
        extra = ""
        if c.get("versions"):
            extra = " " + ", ".join(c["versions"])
        print("  %-9s %s%s" % (name, c.get("placement", "?"), extra))
    if p.get("updated"):
        print("  Parts     %s (server parts last changed %s)" % (", ".join(sorted(p.get("applied", {}))), p["updated"]))

    ng = data["nginx"]
    if ng["where"]:
        if ng["test_rc"] == 0:
            t = good("config OK")
        else:
            t = bad("CONFIG BROKEN") + "\n" + "\n".join("            " + l for l in ng["test"].splitlines())
        print("  nginx     %s, %s, Cloudflare real IP %s" % (ng["where"], t, "on" if ng["realip"] else meh("off")))

    if data["services"]:
        head("Services")
        for s in data["services"]:
            st = good(s["state"]) if s["state"] == "active" else (bad(s["state"]) if s["state"] == "failed" else meh(s["state"]))
            notes = []
            if s["enabled"] != "enabled":
                notes.append("off at boot")
            if s["auto_restart"]:
                notes.append("restarts on crash")
            print("  %-16s %s%s" % (s["name"], st, ("  (" + ", ".join(notes) + ")") if notes else ""))

    if data["containers"]:
        head("Containers")
        for c in data["containers"]:
            st = good(c["status"]) if c["state"] == "running" and "unhealthy" not in c["status"] else \
                bad(c["status"]) if c["state"] in ("restarting", "dead") or "unhealthy" in c["status"] else meh(c["status"])
            print("  %-32s %s" % (c["name"], st))

    head("Sites")
    if not data["sites"]:
        print("  (none recorded in /etc/deployer/sites)")
    for s in data["sites"]:
        if s.get("status") == "stopped":
            print("  %-34s %s" % (s["domain"], meh("stopped") + " (closed by a setup switch, files kept)"))
            continue
        checks = []
        for scheme in ("http", "https"):
            if scheme in s:
                code = s[scheme]
                ok = code.isdigit() and code[0] in "23"
                checks.append("%s %s" % (scheme, good(code) if ok else bad(code)))
        if "cert_days" in s:
            d = s["cert_days"]
            t = "cert %d days" % d
            checks.append(bad(t) if d < 7 else meh(t) if d < 30 else t)
        setup = (s.get("setup") or "?").replace("_stack", "").replace("_lemp", "")
        print("  %-34s %-7s PHP %-4s %-10s %s" % (s["domain"], setup, s.get("php_version") or "?",
                                               s.get("environment") or "?", "  ".join(checks)))
    if not data.get("root"):
        print("\n" + meh("Not run as root on the target: some checks may be incomplete (no passwordless sudo)."))


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "probe"
    if mode == "probe":
        probe()
    elif mode == "render":
        render("--color" in sys.argv)
    else:
        sys.exit("usage: status.py probe|render [--color]")
