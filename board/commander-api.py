#!/usr/bin/env python3
"""radxa-commander board control API.

Stdlib only. Runs as root via systemd (needs nmcli / iptables / mihomo access).
Auth: Authorization: Bearer <token>, token in /etc/radxa-commander/token (0600).
Listen: 0.0.0.0:18080 (LAN/AP reachable; token-gated).

Endpoints (all JSON; errors -> {"error": msg}):
  GET  /api/hello              no auth. {app, version, board}
  GET  /api/status             hostname/uptime/load/mem/temp/wan/ap/mihomo
  GET  /api/wifi               {ssid, password, channel}
  PUT  /api/wifi               {ssid?, password?, channel?}  (re-applies AP: clients drop!)
  GET  /api/clients            [{ip, mac, hostname, state}]
  POST /api/clients/block      {mac}
  POST /api/clients/unblock    {mac}
  POST /api/reboot             {}
  GET  /api/split              mihomo selector {now, all}
  PUT  /api/split              {name}
  GET  /api/check              one-click health booleans
"""

import json
import os
import re
import subprocess
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VERSION = "0.2.0"
LISTEN = ("0.0.0.0", 18080)
TOKEN_FILE = "/etc/radxa-commander/token"
BLOCKED_FILE = "/etc/radxa-commander/blocked.conf"
MIHOMO_CTRL = "http://127.0.0.1:9091"
SELECTOR = "\U0001f680 \u8282\u70b9\u9009\u62e9"  # 🚀 节点选择
AP_CON = "radxa-ap"
LEASES = "/var/lib/NetworkManager/dnsmasq-wlan0.leases"


def run(*argv, timeout=20):
    try:
        r = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout.strip(), r.stderr.strip()
    except Exception as e:  # noqa: BLE001
        return 127, "", str(e)


def load_token():
    try:
        with open(TOKEN_FILE) as f:
            return f.read().strip()
    except OSError:
        return ""


def nmcli(*args):
    return run("nmcli", "-t", *args)


def mihomo_get(path, timeout=10):
    req = urllib.request.Request(MIHOMO_CTRL + path)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def mihomo_put(path, obj, timeout=10):
    data = json.dumps(obj).encode()
    req = urllib.request.Request(MIHOMO_CTRL + path, data=data, method="PUT",
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout):
        return True


# ---- collectors -----------------------------------------------------------

def get_status():
    rc, hostname, _ = run("hostname")
    with open("/proc/uptime") as f:
        uptime_s = int(float(f.read().split()[0]))
    with open("/proc/loadavg") as f:
        load1 = float(f.read().split()[0])
    mem = {}
    with open("/proc/meminfo") as f:
        for line in f:
            k, _, v = line.partition(":")
            if k in ("MemTotal", "MemAvailable"):
                mem[k] = int(v.split()[0]) // 1024
    temp_c = None
    for z in ("/sys/class/thermal/thermal_zone0/temp",):
        try:
            with open(z) as f:
                temp_c = int(f.read().strip()) / 1000.0
            break
        except OSError:
            continue
    _, wan_ip, _ = run("sh", "-c",
                       "ip -4 -o addr show end0 scope global | awk '{print $4}' | cut -d/ -f1 | head -1")
    _, ssid, _ = nmcli("-f", "802-11-wireless.ssid", "connection", "show", AP_CON)
    _, chan, _ = nmcli("-f", "802-11-wireless.channel", "connection", "show", AP_CON)
    _, mm_active, _ = run("systemctl", "is-active", "mihomo")
    group_now, group_all = None, []
    try:
        g = mihomo_get("/proxies/" + urllib.parse.quote(SELECTOR, safe=""))
        group_now, group_all = g.get("now"), g.get("all", [])
    except Exception:  # noqa: BLE001
        pass
    return {
        "board": hostname or "a7a",
        "uptime_s": uptime_s,
        "load1": load1,
        "mem_mb": mem,
        "temp_c": temp_c,
        "wan": {"iface": "end0", "ip": wan_ip},
        "ap": {"ssid": ssid.split(":", 1)[-1] if ":" in ssid else ssid,
               "channel": chan.split(":", 1)[-1] if ":" in chan else chan,
               "enabled": ap_active(),
               "auto": read_ap_flag()},
        "mihomo": {"active": mm_active == "active", "group_now": group_now,
                   "group_all": group_all},
        "time": int(time.time()),
    }


def get_wifi():
    _, ssid, _ = nmcli("-f", "802-11-wireless.ssid", "connection", "show", AP_CON)
    _, chan, _ = nmcli("-f", "802-11-wireless.channel", "connection", "show", AP_CON)
    _, psk, _ = run("nmcli", "-s", "-g", "802-11-wireless-security.psk",
                    "connection", "show", AP_CON)
    return {
        "ssid": ssid.split(":", 1)[-1] if ":" in ssid else ssid,
        "password": psk,
        "channel": int(chan.split(":", 1)[-1]) if chan.split(":")[-1].isdigit() else 6,
    }


def set_wifi(body):
    ssid = body.get("ssid")
    password = body.get("password")
    channel = body.get("channel")
    if ssid is not None:
        ssid = str(ssid).strip()
        if not (1 <= len(ssid) <= 32):
            raise ValueError("ssid 长度需 1..32")
    if password is not None:
        password = str(password)
        if len(password) < 8:
            raise ValueError("WiFi 密码至少 8 位")
    if channel is not None:
        channel = int(channel)
        if channel not in (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13):
            raise ValueError("信道需 1..13")
    if ssid is not None:
        rc, _, err = run("nmcli", "connection", "modify", AP_CON, "wifi.ssid", ssid)
        if rc:
            raise RuntimeError("改 SSID 失败: " + err)
    if password is not None:
        rc, _, err = run("nmcli", "connection", "modify", AP_CON, "wifi-sec.psk", password)
        if rc:
            raise RuntimeError("改密码失败: " + err)
    if channel is not None:
        rc, _, err = run("nmcli", "connection", "modify", AP_CON, "wifi.channel", str(channel))
        if rc:
            raise RuntimeError("改信道失败: " + err)
    run("nmcli", "connection", "down", AP_CON)
    time.sleep(2)
    rc, _, err = run("nmcli", "connection", "up", AP_CON)
    if rc:
        raise RuntimeError("热点重开失败: " + err)
    time.sleep(2)
    return get_wifi()


def get_ap():
    reason = read_ap_flag()
    _, ssid, _ = nmcli("-f", "802-11-wireless.ssid", "connection", "show", AP_CON)
    return {"enabled": ap_active(),
            "auto": reason,
            "ssid": ssid.split(":", 1)[-1] if ":" in ssid else ssid}


def set_ap(enabled):
    if enabled:
        rc, _, err = run("nmcli", "connection", "up", AP_CON)
        if rc:
            raise RuntimeError("热点开启失败: " + err)
    else:
        rc, _, err = run("nmcli", "connection", "down", AP_CON)
        if rc:
            raise RuntimeError("热点关闭失败: " + err)
    clear_ap_flag()  # manual action: timer never fights the user
    time.sleep(2)
    return get_ap()


def ap_active():
    rc, out, _ = run("nmcli", "-t", "-f", "NAME", "connection", "show", "--active")
    return AP_CON in (out or "").splitlines()


def read_ap_flag():
    try:
        with open("/run/radxa-ap-auto") as f:
            return f.read().strip() or None
    except OSError:
        return None


def clear_ap_flag():
    try:
        os.unlink("/run/radxa-ap-auto")
    except OSError:
        pass


def get_clients():
    leases = {}
    try:
        with open(LEASES) as f:
            for line in f:
                parts = line.split()
                if len(parts) >= 4:
                    _, mac, ip, host = parts[0], parts[1], parts[2], parts[3]
                    leases[mac.lower()] = {"ip": ip, "hostname": host if host != "*" else ""}
    except OSError:
        pass
    neigh = {}
    rc, out, _ = run("ip", "-o", "neigh", "show", "dev", "wlan0")
    if not rc:
        for line in out.splitlines():
            m = re.match(r"(\S+)\s+(?:dev \S+ )?lladdr (\S+)\s+(\S+)", line)
            if m:
                neigh[m.group(2).lower()] = {"ip": m.group(1), "state": m.group(3)}
    blocked = set()
    try:
        with open(BLOCKED_FILE) as f:
            blocked = {l.strip().lower() for l in f if l.strip()}
    except OSError:
        pass
    macs = sorted(set(leases) | set(neigh))
    clients = []
    for mac in macs:
        info = {"mac": mac,
                "ip": leases.get(mac, {}).get("ip") or neigh.get(mac, {}).get("ip", ""),
                "hostname": leases.get(mac, {}).get("hostname", ""),
                "state": neigh.get(mac, {}).get("state", "unknown"),
                "blocked": mac in blocked}
        clients.append(info)
    return clients


def save_blocked(blocked):
    os.makedirs(os.path.dirname(BLOCKED_FILE), exist_ok=True)
    with open(BLOCKED_FILE, "w") as f:
        f.write("\n".join(sorted(blocked)) + ("\n" if blocked else ""))
    os.chmod(BLOCKED_FILE, 0o600)


def set_blocked(mac, block):
    mac = str(mac).lower()
    if not re.fullmatch(r"(?:[0-9a-f]{2}:){5}[0-9a-f]{2}", mac):
        raise ValueError("MAC 格式错误")
    try:
        with open(BLOCKED_FILE) as f:
            blocked = {l.strip().lower() for l in f if l.strip()}
    except OSError:
        blocked = set()
    rule = ["iptables", "-t", "filter", "-I", "FORWARD", "1",
            "-m", "mac", "--mac-source", mac, "-j", "DROP",
            "-m", "comment", "--comment", "commander-block"]
    if block:
        rc, _, _ = run("iptables", "-t", "filter", "-C", "FORWARD",
                       "-m", "mac", "--mac-source", mac, "-j", "DROP")
        if rc:
            rcc, _, err = run(*rule)
            if rcc:
                raise RuntimeError("拉黑失败: " + err)
        blocked.add(mac)
    else:
        run("iptables", "-t", "filter", "-D", "FORWARD",
            "-m", "mac", "--mac-source", mac, "-j", "DROP")
        blocked.discard(mac)
    save_blocked(blocked)
    return {"mac": mac, "blocked": block}


def get_split():
    g = mihomo_get("/proxies/" + urllib.parse.quote(SELECTOR, safe=""))
    return {"now": g.get("now"), "all": g.get("all", [])}


def set_split(name):
    mihomo_put("/proxies/" + urllib.parse.quote(SELECTOR, safe=""), {"name": name})
    return get_split()


def get_check():
    def has_ipt(table, *spec):
        rc, _, _ = run("iptables", "-t", table, "-C", *spec)
        return rc == 0
    rc, ipf, _ = run("sh", "-c", "sysctl -n net.ipv4.ip_forward")
    try:
        with open("/sys/class/net/end0/device/tx_delay") as f:
            tx = "".join(c for c in f.read().splitlines()[-1] if c.isdigit())
    except OSError:
        tx = ""
    _, ap_names, _ = run("nmcli", "-t", "-f", "NAME", "connection", "show", "--active")
    _, mm, _ = run("systemctl", "is-active", "mihomo")
    _, dq, _ = run("sh", "-c", "ps -o comm= -C dnsmasq | head -1")
    return {
        "ap_active": AP_CON in (ap_names or "").splitlines(),
        "ip_forward": ipf.strip() == "1",
        "tx_delay": {"value": tx, "ok": tx == "9"},
        "nat_masquerade": has_ipt("nat", "POSTROUTING", "-s", "10.42.0.0/24",
                                  "-o", "end0", "-j", "MASQUERADE"),
        "redirect_tcp": has_ipt("nat", "PREROUTING", "-i", "wlan0", "-p", "tcp",
                                "-m", "addrtype", "!", "--dst-type", "LOCAL",
                                "-j", "REDIRECT", "--to-ports", "7892"),
        "dns_hijack_udp": has_ipt("nat", "PREROUTING", "-i", "wlan0", "-p", "udp",
                                  "--dport", "53", "-j", "REDIRECT", "--to-ports", "1053"),
        "mihomo_active": mm.strip() == "active",
        "dnsmasq_running": dq.strip() == "dnsmasq",
    }


# ---- HTTP ---------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    server_version = "Commander/0.1"

    def log_message(self, *a):  # quiet
        pass

    def _send(self, code, obj):
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _auth(self):
        token = load_token()
        if not token:
            return False
        auth = self.headers.get("Authorization", "")
        return auth == "Bearer " + token

    def _body(self):
        try:
            n = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            n = 0
        if n <= 0 or n > 65536:
            return {}
        try:
            return json.loads(self.rfile.read(n).decode())
        except Exception:  # noqa: BLE001
            return {}

    def do_GET(self):
        if self.path == "/api/hello":
            self._send(200, {"app": "radxa-commander", "version": VERSION})
            return
        if not self._auth():
            self._send(401, {"error": "unauthorized"})
            return
        try:
            if self.path == "/api/status":
                self._send(200, get_status())
            elif self.path == "/api/wifi":
                self._send(200, get_wifi())
            elif self.path == "/api/ap":
                self._send(200, get_ap())
            elif self.path == "/api/clients":
                self._send(200, get_clients())
            elif self.path == "/api/split":
                self._send(200, get_split())
            elif self.path == "/api/check":
                self._send(200, get_check())
            else:
                self._send(404, {"error": "not found"})
        except Exception as e:  # noqa: BLE001
            self._send(500, {"error": str(e)})

    def _mutate(self):
        if not self._auth():
            self._send(401, {"error": "unauthorized"})
            return
        body = self._body()
        try:
            if self.path == "/api/wifi" and self.command == "PUT":
                self._send(200, set_wifi(body))
            elif self.path == "/api/ap" and self.command == "PUT":
                if not isinstance(body.get("enabled"), bool):
                    self._send(400, {"error": "enabled 需 true/false"})
                else:
                    self._send(200, set_ap(body["enabled"]))
            elif self.path == "/api/clients/block":
                self._send(200, set_blocked(body.get("mac", ""), True))
            elif self.path == "/api/clients/unblock":
                self._send(200, set_blocked(body.get("mac", ""), False))
            elif self.path == "/api/split" and self.command == "PUT":
                if not body.get("name"):
                    self._send(400, {"error": "缺少 name"})
                else:
                    self._send(200, set_split(body["name"]))
            elif self.path == "/api/reboot":
                self._send(200, {"rebooting": True})
                subprocess.Popen(["sh", "-c", "sleep 1; systemctl reboot"])
            else:
                self._send(404, {"error": "not found"})
        except ValueError as e:
            self._send(400, {"error": str(e)})
        except RuntimeError as e:
            self._send(500, {"error": str(e)})
        except Exception as e:  # noqa: BLE001
            self._send(500, {"error": str(e)})

    do_PUT = _mutate
    do_POST = _mutate


if __name__ == "__main__":
    ThreadingHTTPServer(LISTEN, Handler).serve_forever()
