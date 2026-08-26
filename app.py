#!/usr/bin/env python3
"""Network Diagnostic Dashboard - Real-time monitoring with SSE."""

import json
import os
import platform
import queue
import socket
import subprocess
import threading
import time
import urllib.request
from datetime import datetime
from flask import Flask, Response, render_template, jsonify

app = Flask(__name__)

# Backlight control (Raspberry Pi DSI display)
BACKLIGHT_PATH = "/sys/class/backlight/10-0045/brightness"
BACKLIGHT_MAX = 155

# Track error state for wake-on-error
previous_has_errors = False

# Host/service configuration
HOSTS = {
    "router": {
        "name": "Router",
        "ip": "192.168.1.1",
        "checks": [
            {"type": "ping"},
            {"type": "port", "port": 80, "label": "HTTP"},
            {"type": "port", "port": 443, "label": "HTTPS"},
        ],
    },
    "dns": {
        "name": "DNS/Pi-hole",
        "ip": "192.168.1.41",
        "checks": [
            {"type": "ping"},
            {"type": "port", "port": 53, "label": "DNS"},
            {"type": "port", "port": 80, "label": "HTTP"},
        ],
    },
    "proxmox1": {
        "name": "Proxmox-1",
        "ip": "192.168.1.20",
        "checks": [
            {"type": "ping"},
            # SSH probe dropped 2026-08-26: 8006 already proves the node is up,
            # and proves more -- pveproxy answering means the Proxmox stack is
            # alive, whereas sshd happily keeps listening on a node whose cluster
            # services are broken.
            {"type": "port", "port": 8006, "label": "Web UI"},
        ],
    },
    "proxmox2": {
        "name": "Proxmox-2",
        "ip": "192.168.1.21",
        "checks": [
            {"type": "ping"},
            # SSH probe dropped 2026-08-26: 8006 already proves the node is up,
            # and proves more -- pveproxy answering means the Proxmox stack is
            # alive, whereas sshd happily keeps listening on a node whose cluster
            # services are broken.
            {"type": "port", "port": 8006, "label": "Web UI"},
        ],
    },
    "proxmox3": {
        "name": "Proxmox-3",
        "ip": "192.168.1.22",
        "checks": [
            {"type": "ping"},
            # SSH probe dropped 2026-08-26: 8006 already proves the node is up,
            # and proves more -- pveproxy answering means the Proxmox stack is
            # alive, whereas sshd happily keeps listening on a node whose cluster
            # services are broken.
            {"type": "port", "port": 8006, "label": "Web UI"},
        ],
    },
    "proxxy": {
        "name": "Proxxy (NPM)",
        "ip": "192.168.1.34",
        "checks": [
            {"type": "ping"},
            {"type": "port", "port": 80, "label": "HTTP"},
            {"type": "port", "port": 443, "label": "HTTPS"},
            {"type": "port", "port": 81, "label": "Admin"},
        ],
    },
    "wireguard": {
        "name": "WireGuard",
        "ip": "192.168.1.208",
        "checks": [
            {"type": "ping"},
            # SSH kept here: WireGuard is UDP/51820 so it cannot be TCP-probed,
            # and nothing else on this host listens on TCP (verified 2026-08-26).
            # At 30s that is ~2.9k sshd lines a day instead of 17k.
            {"type": "port", "port": 22, "label": "SSH"},
        ],
    },
}

# Thread-safe storage for check results
results_lock = threading.Lock()
check_results = {}

# Queue for SSE subscribers
subscribers = []
subscribers_lock = threading.Lock()


def ping_host(ip, timeout=2):
    """Ping a host and return (success, response_time_ms)."""
    system = platform.system().lower()

    if system == "darwin":
        # macOS uses -t for timeout
        cmd = ["ping", "-c", "1", "-t", str(timeout), ip]
    else:
        # Linux uses -W for timeout
        cmd = ["ping", "-c", "1", "-W", str(timeout), ip]

    try:
        start = time.time()
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout + 1
        )
        elapsed = (time.time() - start) * 1000

        if result.returncode == 0:
            return True, round(elapsed, 1)
        return False, None
    except (subprocess.TimeoutExpired, Exception):
        return False, None


def check_port(ip, port, timeout=2):
    """Check if a TCP port is open and return (success, response_time_ms)."""
    try:
        start = time.time()
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(timeout)
        result = sock.connect_ex((ip, port))
        elapsed = (time.time() - start) * 1000
        sock.close()

        if result == 0:
            return True, round(elapsed, 1)
        return False, None
    except Exception:
        return False, None


def get_external_ip(timeout=5):
    """Get external IP address using ipify API."""
    try:
        req = urllib.request.Request(
            "https://api.ipify.org",
            headers={"User-Agent": "network-dashboard"}
        )
        with urllib.request.urlopen(req, timeout=timeout) as response:
            return response.read().decode("utf-8").strip()
    except Exception:
        return None


def resolve_dns(hostname, dns_server="8.8.8.8", timeout=5):
    """Resolve hostname to IP address using specified DNS server."""
    try:
        # Use dig to query specific DNS server
        cmd = ["dig", "+short", f"@{dns_server}", hostname, "A"]
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout
        )
        if result.returncode == 0 and result.stdout.strip():
            # dig may return CNAME then IP, find the IP address
            for line in result.stdout.strip().split('\n'):
                line = line.strip()
                # Check if line looks like an IPv4 address
                if line and line[0].isdigit() and '.' in line:
                    return line
        return None
    except Exception:
        return None


DDNS_HOSTNAME = "www.arctian.org"
DDNS_LABEL = "DYN"


def get_brightness():
    """Get current backlight brightness."""
    try:
        with open(BACKLIGHT_PATH, "r") as f:
            return int(f.read().strip())
    except Exception:
        return None


def set_brightness(value):
    """Set backlight brightness."""
    try:
        with open(BACKLIGHT_PATH, "w") as f:
            f.write(str(value))
        return True
    except Exception:
        return False


def has_errors(results):
    """Check if any results have errors (down or warning status)."""
    for host_data in results.values():
        for check in host_data.get("checks", []):
            if check.get("status") in ("down", "warning"):
                return True
    return False


def run_checks():
    """Run all health checks and update results."""
    new_results = {}
    check_time = datetime.now().strftime("%H:%M:%S")

    for host_id, host_config in HOSTS.items():
        host_results = {
            "name": host_config["name"],
            "ip": host_config["ip"],
            "checks": [],
            "last_check": check_time,
        }

        for check in host_config["checks"]:
            if check["type"] == "ping":
                success, response_time = ping_host(host_config["ip"])
                host_results["checks"].append({
                    "label": "Ping",
                    "status": "up" if success else "down",
                    "response_time": response_time,
                })
            elif check["type"] == "port":
                success, response_time = check_port(
                    host_config["ip"], check["port"]
                )
                host_results["checks"].append({
                    "label": check["label"],
                    "status": "up" if success else "down",
                    "response_time": response_time,
                })

        new_results[host_id] = host_results

    # DDNS check - compare external IP with DNS resolution
    external_ip = get_external_ip()
    dns_ip = resolve_dns(DDNS_HOSTNAME)

    if external_ip and dns_ip:
        match_status = "up" if external_ip == dns_ip else "warning"
    else:
        match_status = "down"

    new_results["ddns"] = {
        "name": "Dynamic DNS",
        "ip": DDNS_HOSTNAME,
        "type": "ddns",
        "checks": [
            {
                "label": "WAN",
                "status": "up" if external_ip else "down",
                "value": external_ip or "unavailable",
            },
            {
                "label": DDNS_LABEL,
                "status": "up" if dns_ip else "down",
                "value": dns_ip or "unavailable",
            },
            {
                "label": "Match",
                "status": match_status,
                "value": "yes" if match_status == "up" else "no" if match_status == "warning" else "unknown",
            },
        ],
        "last_check": check_time,
    }

    with results_lock:
        check_results.clear()
        check_results.update(new_results)

    return new_results


def broadcast_results(results):
    """Send results to all SSE subscribers."""
    global previous_has_errors

    data = json.dumps(results)
    message = f"data: {data}\n\n"

    # Check for new errors (transition from no errors to errors)
    current_has_errors = has_errors(results)
    wake_screen = current_has_errors and not previous_has_errors
    previous_has_errors = current_has_errors

    with subscribers_lock:
        dead_subscribers = []
        for q in subscribers:
            try:
                # Send wake event if new errors detected
                if wake_screen:
                    q.put_nowait("event: wake\ndata: errors\n\n")
                q.put_nowait(message)
            except Exception:
                dead_subscribers.append(q)

        for q in dead_subscribers:
            subscribers.remove(q)


def health_check_loop():
    """Background thread that runs health checks periodically."""
    while True:
        results = run_checks()
        broadcast_results(results)
        # 30s, not 5s. At 5s this hit every host 17,280 times a day, and the SSH
        # probes alone added ~69k "Connection closed by 192.168.1.40" lines a day
        # to the Proxmox nodes' sshd journals -- enough to make
        # `journalctl -u ssh` useless for spotting a real login. A wall dashboard
        # does not need 5-second resolution on "is the box up".
        time.sleep(30)


@app.route("/")
def index():
    """Serve the dashboard page."""
    return render_template("index.html")


@app.route("/events")
def events():
    """SSE endpoint for real-time updates."""
    def generate():
        q = queue.Queue()

        with subscribers_lock:
            subscribers.append(q)

        try:
            # Send current state immediately
            with results_lock:
                if check_results:
                    data = json.dumps(check_results)
                    yield f"data: {data}\n\n"

            while True:
                try:
                    message = q.get(timeout=30)
                    yield message
                except queue.Empty:
                    # Send keepalive
                    yield ": keepalive\n\n"
        finally:
            with subscribers_lock:
                if q in subscribers:
                    subscribers.remove(q)

    return Response(
        generate(),
        mimetype="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
        }
    )


@app.route("/screen/on", methods=["POST"])
def screen_on():
    """Turn screen on."""
    success = set_brightness(BACKLIGHT_MAX)
    return jsonify({"success": success, "brightness": BACKLIGHT_MAX})


@app.route("/screen/off", methods=["POST"])
def screen_off():
    """Turn screen off."""
    success = set_brightness(0)
    return jsonify({"success": success, "brightness": 0})


@app.route("/screen/toggle", methods=["POST"])
def screen_toggle():
    """Toggle screen on/off."""
    current = get_brightness()
    if current is None:
        return jsonify({"success": False, "error": "Cannot read brightness"})

    if current > 0:
        success = set_brightness(0)
        new_brightness = 0
    else:
        success = set_brightness(BACKLIGHT_MAX)
        new_brightness = BACKLIGHT_MAX

    return jsonify({"success": success, "brightness": new_brightness})


@app.route("/screen/status")
def screen_status():
    """Get current screen status."""
    brightness = get_brightness()
    return jsonify({
        "brightness": brightness,
        "on": brightness is not None and brightness > 0
    })


if __name__ == "__main__":
    # Start background health check thread
    checker_thread = threading.Thread(target=health_check_loop, daemon=True)
    checker_thread.start()

    # Run Flask app
    app.run(host="0.0.0.0", port=5000, debug=False, threaded=True)
