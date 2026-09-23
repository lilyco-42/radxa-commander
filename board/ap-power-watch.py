#!/usr/bin/env python3
"""A7A AP power watcher. Run every 5 min via ap-power.timer (root).

Policy (config /etc/radxa-commander/ap-power.conf):
  QUIET_ON=1  QUIET_START=01:00  QUIET_END=06:30
    In quiet window and AP up  -> AP down, flag=quiet (forced sleep).
    Out of window and flag==quiet -> AP up, clear flag (morning recovery).
  IDLE_OFF=0  IDLE_MINUTES=60
    If enabled, AP up, and every associated station inactive longer than
    IDLE_MINUTES (or zero stations + no traffic) -> AP down, flag=idle.
    flag==idle recovers at next quiet-end like quiet (see above).
  Manual PUT /api/ap clears the flag file -> timer never fights the user.

Why idle-off defaults to 0: with the AP down, associated clients cannot wake
it (no wake path over WiFi). Quiet hours are predictable and self-recovering.
"""
import os
import re
import subprocess
import time

CONF = "/etc/radxa-commander/ap-power.conf"
FLAG = "/run/radxa-ap-auto"
AP_CON = "radxa-ap"
TRAFFIC_LAST = "/run/radxa-ap-traffic"


def run(*argv, timeout=20):
    try:
        r = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout.strip(), r.stderr.strip()
    except Exception as e:  # noqa: BLE001
        return 127, "", str(e)


def load_conf():
    cfg = {"QUIET_ON": "1", "QUIET_START": "01:00", "QUIET_END": "06:30",
           "IDLE_OFF": "0", "IDLE_MINUTES": "60"}
    try:
        with open(CONF) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, _, v = line.partition("=")
                if k.strip() in cfg:
                    cfg[k.strip()] = v.strip()
    except OSError:
        pass
    return cfg


def ap_up():
    rc, out, _ = run("nmcli", "-t", "-f", "NAME", "connection", "show", "--active")
    return AP_CON in (out or "").splitlines()


def ap_down():
    run("nmcli", "connection", "down", AP_CON)


def ap_up_cmd():
    rc, _, err = run("nmcli", "connection", "up", AP_CON)
    return rc, err


def read_flag():
    try:
        with open(FLAG) as f:
            return f.read().strip() or None
    except OSError:
        return None


def write_flag(v):
    try:
        with open(FLAG, "w") as f:
            f.write(v + "\n")
    except OSError:
        pass


def clear_flag():
    try:
        os.unlink(FLAG)
    except OSError:
        pass


def stations():
    """Return [(mac, inactive_ms)] or None when iw unavailable."""
    rc, out, _ = run("iw", "dev", "wlan0", "station", "dump")
    if rc:
        return None
    res, mac = [], None
    for line in out.splitlines():
        m = re.match(r"Station (\S+)", line)
        if m:
            mac = m.group(1).lower()
            continue
        m = re.match(r"\s*inactive time:\s*(\d+)\s*ms", line)
        if m and mac:
            res.append((mac, int(m.group(1))))
            mac = None
    return res


def traffic_idle(threshold_s):
    """Fallback when iw missing: wlan0 counters unchanged for threshold."""
    try:
        with open("/sys/class/net/wlan0/statistics/rx_bytes") as f:
            rx = int(f.read())
        with open("/sys/class/net/wlan0/statistics/tx_bytes") as f:
            tx = int(f.read())
    except OSError:
        return False
    now = time.time()
    try:
        with open(TRAFFIC_LAST) as f:
            o_rx, o_tx, o_ts = f.read().split()
            old = (int(o_rx), int(o_tx), float(o_ts))
    except (OSError, ValueError):
        old = None
    try:
        with open(TRAFFIC_LAST, "w") as f:
            f.write("%d %d %f\n" % (rx, tx, now))
    except OSError:
        pass
    if old is None:
        return False
    o_rx, o_tx, o_ts = old
    return (rx, tx) == (o_rx, o_tx) and (now - o_ts) >= threshold_s


def in_quiet(now_hm, start, end):
    if start <= end:
        return start <= now_hm < end
    return now_hm >= start or now_hm < end


def main():
    cfg = load_conf()
    idle_off = cfg["IDLE_OFF"] == "1"
    try:
        idle_min = max(5, int(cfg["IDLE_MINUTES"]))
    except ValueError:
        idle_min = 60
    quiet_on = cfg["QUIET_ON"] == "1"
    qs, qe = cfg["QUIET_START"], cfg["QUIET_END"]
    now_hm = time.strftime("%H:%M")
    quiet = quiet_on and in_quiet(now_hm, qs, qe)
    up = ap_up()
    flag = read_flag()

    if quiet:
        if up and flag != "manual":
            ap_down()
            write_flag("quiet")
            print("quiet: AP down")
        return

    # outside quiet window
    if flag == "manual":
        clear_flag()  # resume normal management, keep current AP state
        return
    if flag in ("quiet", "idle"):
        if not up:
            rc, err = ap_up_cmd()
            print("recover: AP up rc=%d %s" % (rc, err))
        clear_flag()
        return
    if idle_off and up:
        st = stations()
        if st is not None:
            if st and all(ms >= idle_min * 60000 for _, ms in st):
                ap_down()
                write_flag("idle")
                print("idle: AP down (%d stations quiet)" % len(st))
            elif not st and traffic_idle(idle_min * 60):
                ap_down()
                write_flag("idle")
                print("idle: AP down (no stations, no traffic)")
        elif traffic_idle(idle_min * 60):
            ap_down()
            write_flag("idle")
            print("idle: AP down (no traffic)")


if __name__ == "__main__":
    main()
