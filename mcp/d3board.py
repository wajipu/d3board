#!/usr/bin/env python3
"""d3board - control the LAN Android boards, for humans and for agents.

One file, no dependencies (Python 3.9+ standard library only). It is two things:

    d3board.py <subcommand> ...      a normal CLI
    d3board.py mcp                   an MCP server on stdio

Both share the same device registry the macOS app uses
(~/Library/Application Support/D3Board/devices.json), so an agent and the GUI
never disagree about which board is where.

Addresses are not an API: every command takes a device by nickname, model,
serial or address, and a board that changed its DHCP lease is found again and
remembered. Nothing here needs the GUI to be running.
"""

import argparse
import base64
import concurrent.futures
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import time
from datetime import datetime, timezone

APP_DIR = os.path.expanduser("~/Library/Application Support/D3Board")
REGISTRY = os.path.join(APP_DIR, "devices.json")
MIRRORS = os.path.join(APP_DIR, "mirrors.json")
ADB_PORT = 5555
SCAN_TTL = 10.0            # reuse a scan this long before touching the network again
REJECT_TTL = 300.0         # hosts that answer 5555 but are not Android
SERIAL_RE = re.compile(r"^[A-Za-z0-9._-]{4,64}$")


# ---------------------------------------------------------------- small utils

def log(message):
    """Diagnostics go to stderr: stdout belongs to the MCP stream."""
    print("[d3board] " + message, file=sys.stderr, flush=True)


def iso_now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_iso(value):
    try:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except Exception:
        return None


def find_tool(name, candidates):
    for path in candidates:
        if os.path.isfile(path) and os.access(path, os.X_OK):
            return path
    shell = os.environ.get("SHELL", "/bin/zsh")
    try:
        out = subprocess.run([shell, "-lic", "command -v %s" % name],
                             capture_output=True, text=True, timeout=10).stdout
        for line in reversed(out.splitlines()):
            line = line.strip()
            if line.startswith("/") and os.access(line, os.X_OK):
                return line
    except Exception:
        pass
    return None


class Tools(object):
    def __init__(self):
        home = os.path.expanduser("~")
        self.adb = find_tool("adb", [
            "/opt/homebrew/share/android-commandlinetools/platform-tools/adb",
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            os.path.join(home, "Library/Android/sdk/platform-tools/adb"),
            os.path.join(home, ".local/bin/adb"),
        ])
        self.scrcpy = find_tool("scrcpy", ["/opt/homebrew/bin/scrcpy", "/usr/local/bin/scrcpy"])


TOOLS = Tools()


def run(args, timeout=20, binary=False):
    """Run a command, never raise. Returns (code, stdout, stderr)."""
    try:
        proc = subprocess.run(args, capture_output=True, timeout=timeout,
                              text=not binary)
        if binary:
            return proc.returncode, proc.stdout, proc.stderr.decode("utf-8", "replace")
        return proc.returncode, proc.stdout, proc.stderr
    except subprocess.TimeoutExpired:
        return -9, (b"" if binary else ""), "timeout after %ss: %s" % (timeout, " ".join(args))
    except FileNotFoundError:
        return -2, (b"" if binary else ""), "not found: %s" % args[0]


def adb(args, timeout=20, binary=False):
    if not TOOLS.adb:
        return -2, (b"" if binary else ""), "adb not found (brew install android-platform-tools)"
    return run([TOOLS.adb] + list(args), timeout=timeout, binary=binary)


# -------------------------------------------------------------------- registry

def load_registry():
    try:
        with open(REGISTRY) as handle:
            data = json.load(handle)
        return {entry["serial"]: entry for entry in data if SERIAL_RE.match(entry.get("serial", ""))}
    except FileNotFoundError:
        return {}
    except Exception as error:
        log("registry unreadable: %s" % error)
        return {}


def save_registry(entries):
    os.makedirs(APP_DIR, exist_ok=True)
    payload = sorted(entries.values(), key=lambda entry: entry.get("serial", ""))
    tmp = REGISTRY + ".tmp"
    try:
        with open(tmp, "w") as handle:
            json.dump(payload, handle, indent=2)
        os.replace(tmp, REGISTRY)
    except Exception as error:
        log("registry not saved: %s" % error)


def record_device(serial, model, device, address):
    """Upsert like the app does, including the 'it moved' history."""
    entries = load_registry()
    entry = entries.get(serial) or {
        "serial": serial, "model": model, "device": device,
        "nickname": "", "lastAddress": address, "previousAddress": None,
        "lastSeen": iso_now(),
    }
    previous = entry.get("lastAddress")
    if previous and previous != address:
        entry["previousAddress"] = previous
    entry["model"] = model or entry.get("model", "")
    entry["device"] = device or entry.get("device", "")
    entry["lastAddress"] = address
    entry["lastSeen"] = iso_now()
    entries[serial] = entry
    save_registry(entries)
    return entry, previous


def display_name(entry):
    nickname = (entry.get("nickname") or "").strip()
    if nickname:
        return nickname
    return entry.get("model") or entry.get("serial", "")


# ------------------------------------------------------------------- discovery

_rejected = {}
_cache = {"at": 0.0, "devices": [], "deep": False}


def local_subnet():
    code, out, _ = run(["/sbin/route", "-n", "get", "default"], timeout=5)
    interface = None
    for line in out.splitlines():
        if "interface:" in line:
            interface = line.split(":")[-1].strip()
    if not interface:
        return None
    code, out, _ = run(["/usr/sbin/ipconfig", "getifaddr", interface], timeout=5)
    parts = out.strip().split(".")
    if len(parts) != 4:
        return None
    return ".".join(parts[:3])


def arp_hosts(base):
    code, out, _ = run(["/usr/sbin/arp", "-an"], timeout=5)
    seen, hosts = set(), []
    for line in out.splitlines():
        if "(incomplete)" in line:
            continue
        match = re.search(r"\(([\d.]+)\)", line)
        if not match:
            continue
        ip = match.group(1)
        if ip.startswith(base + ".") and ip not in seen:
            seen.add(ip)
            hosts.append(ip)
    return hosts


def port_open(ip, port=ADB_PORT, timeout=0.2):
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    try:
        return sock.connect_ex((ip, port)) == 0
    finally:
        sock.close()


def sweep():
    base = local_subnet()
    if not base:
        return []
    hosts = arp_hosts(base)
    candidates = hosts or ["%s.%d" % (base, index) for index in range(1, 255)]
    open_hosts = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=64) as pool:
        for ip, is_open in zip(candidates, pool.map(port_open, candidates)):
            if is_open:
                open_hosts.append("%s:%d" % (ip, ADB_PORT))
    return open_hosts


def normalize(address):
    return address if ":" in address else "%s:%d" % (address, ADB_PORT)


def candidates(deep, known):
    addresses = []
    for entry in known.values():
        addresses.append(normalize(entry.get("lastAddress", "")))
    code, out, _ = adb(["devices"], timeout=8)
    for line in out.splitlines():
        first = line.split("\t")[0].strip()
        if ":" in first:
            addresses.append(first)
    code, out, _ = adb(["mdns", "services"], timeout=8)
    for line in out.splitlines():
        fields = line.split()
        if len(fields) >= 3 and ":" in fields[2]:
            addresses.append(fields[2])
    if deep:
        addresses.extend(sweep())
    unique = []
    for address in addresses:
        if address and address not in unique:
            unique.append(address)
    return unique


def probe(address):
    """Return a device dict, or None when this host is not an Android device."""
    code, out, _ = adb(["connect", address], timeout=5)
    if "connected to" not in out:
        return None
    code, out, _ = adb(["-s", address, "shell", "getprop"], timeout=8)
    props = {}
    for line in out.splitlines():
        match = re.match(r"^\[([^\]]+)\]: \[(.*)\]$", line)
        if match:
            props[match.group(1)] = match.group(2)
    serial = props.get("ro.serialno", "")
    model = props.get("ro.product.model", "")
    if not SERIAL_RE.match(serial) or not model:
        _rejected[address] = time.time() + REJECT_TTL
        adb(["disconnect", address], timeout=3)
        return None
    _rejected.pop(address, None)
    return {
        "serial": serial,
        "model": model,
        "device": props.get("ro.product.device", ""),
        "release": props.get("ro.build.version.release", ""),
        "sdk": props.get("ro.build.version.sdk", ""),
        "address": address,
    }


def scan(deep=False, refresh=False):
    now = time.time()
    if (not refresh and _cache["devices"] and now - _cache["at"] < SCAN_TTL
            and (not deep or _cache["deep"])):
        return _cache["devices"]

    known = load_registry()
    addresses = [a for a in candidates(deep, known) if _rejected.get(a, 0) <= now]
    found = []
    if addresses:
        with concurrent.futures.ThreadPoolExecutor(max_workers=min(8, len(addresses))) as pool:
            for device in pool.map(probe, addresses):
                if device:
                    found.append(device)

    # The same board can answer on a stale address and a fresh one; keep the
    # one we already had on file.
    best = {}
    for device in found:
        existing = best.get(device["serial"])
        if existing is None:
            best[device["serial"]] = device
        else:
            known_address = normalize((known.get(device["serial"]) or {}).get("lastAddress", ""))
            if existing["address"] != known_address and device["address"] == known_address:
                best[device["serial"]] = device

    devices = []
    for device in best.values():
        entry, previous = record_device(device["serial"], device["model"],
                                        device["device"], device["address"])
        device = dict(device)
        device["name"] = display_name(entry)
        device["nickname"] = entry.get("nickname", "")
        device["online"] = True
        device["previous_address"] = entry.get("previousAddress")
        device["address_changed_from"] = previous if previous and previous != device["address"] else None
        devices.append(device)

    online_serials = {device["serial"] for device in devices}
    for serial, entry in known.items():
        if serial in online_serials:
            continue
        devices.append({
            "serial": serial, "model": entry.get("model", ""), "device": entry.get("device", ""),
            "release": "", "sdk": "", "address": entry.get("lastAddress", ""),
            "name": display_name(entry), "nickname": entry.get("nickname", ""),
            "online": False, "previous_address": entry.get("previousAddress"),
            "address_changed_from": None,
        })

    devices.sort(key=lambda item: (not item["online"], item["name"].lower()))
    _cache.update({"at": time.time(), "devices": devices, "deep": deep or _cache["deep"]})
    return devices


def resolve(query, deep=False):
    """Find a device by nickname, model, serial or address."""
    if not query:
        return None
    needle = query.strip().lower()
    devices = scan(deep=deep)
    matches = [d for d in devices if d["address"].lower() == needle
               or d["address"].split(":")[0] == needle
               or d["serial"].lower() == needle]
    if not matches:
        matches = [d for d in devices if needle in d["name"].lower()
                   or needle in d["model"].lower() or needle in d["serial"].lower()]
    if not matches:
        # An address we have never seen: try it directly before giving up.
        address = normalize(needle)
        device = probe(address)
        if device:
            device["name"] = device["model"]
            device["online"] = True
            return device
        return None
    matches.sort(key=lambda d: not d["online"])
    return matches[0]


# --------------------------------------------------------------- device actions

def shell(address, command, timeout=25):
    return adb(["-s", address, "shell", command], timeout=timeout)


def screenshot_png(address, timeout=25):
    code, data, err = adb(["-s", address, "exec-out", "screencap", "-p"],
                          timeout=timeout, binary=True)
    if code != 0 or not data.startswith(b"\x89PNG"):
        return None, (err or "screencap returned %d bytes" % len(data))
    return data, None


def panel_state(address):
    code, out, _ = shell(address, "cat /sys/class/backlight/backlight/bl_power", timeout=10)
    value = out.strip()
    return {"raw": value, "dark": value == "4"}


def wake(address):
    shell(address, "input keyevent KEYCODE_WAKEUP", timeout=10)
    shell(address, "wm dismiss-keyguard", timeout=10)
    return True


def load_mirrors():
    try:
        with open(MIRRORS) as handle:
            return json.load(handle)
    except Exception:
        return {}


def save_mirrors(data):
    os.makedirs(APP_DIR, exist_ok=True)
    try:
        with open(MIRRORS, "w") as handle:
            json.dump(data, handle, indent=2)
    except Exception as error:
        log("mirrors not saved: %s" % error)


# Mirror overrides for devices whose encoder can do better (or worse) than the
# global default; keep in sync with Engine.defaultTuning in Sources/Engine.swift.
DEVICE_TUNING = {
    "MiTV-ASTP0": {"max_size": 1920, "bit_rate": "8M"},  # soft encoder only (MTK mulan)
}


def mirror_pids(address):
    """scrcpy processes for this address (alive ones only)."""
    pids = []
    code, out, _ = run(["/usr/bin/pgrep", "-f", "scrcpy -s %s" % address], timeout=5)
    for line in out.split():
        if line.isdigit():
            pids.append(int(line))
    return pids


def start_mirror(device, screen_off=True, native_resolution=False,
                 max_fps=30, bitrate="2M"):
    if not TOOLS.scrcpy:
        return None, "scrcpy not found (brew install scrcpy)"
    address = device["address"]
    if mirror_pids(address):
        return mirror_pids(address), None
    args = [TOOLS.scrcpy, "-s", address,
            "--stay-awake", "--no-audio", "--no-mouse-hover",
            "--max-fps=%s" % max_fps, "--video-bit-rate=%s" % bitrate,
            "--window-title=%s - %s" % (device.get("name", device["model"]), address)]
    tuning = DEVICE_TUNING.get(device.get("model", ""), {})
    max_size = tuning.get("max_size", 1024 if not native_resolution else None)
    bit_rate = tuning.get("bit_rate", bitrate)
    if max_size:
        args.append("--max-size=%s" % max_size)
    args = [a if not a.startswith("--video-bit-rate=") else "--video-bit-rate=%s" % bit_rate
            for a in args]
    if screen_off:
        args.append("--turn-screen-off")
    if device.get("device", "").startswith(("rk356", "rk358")):
        args += ["--video-codec=h264", "--video-encoder=OMX.rk.video_encoder.avc"]

    try:
        proc = subprocess.Popen(args, stdin=subprocess.DEVNULL,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                start_new_session=True)
    except Exception as error:
        return None, "scrcpy failed to start: %s" % error
    time.sleep(0.4)
    mirrors = load_mirrors()
    mirrors[address] = {"pid": proc.pid, "started": iso_now(),
                        "screen_off": screen_off, "name": device.get("name", "")}
    save_mirrors(mirrors)
    return [proc.pid], None


def stop_mirror(address):
    """scrcpy 4.x ignores SIGTERM; SIGINT makes it restore the panel."""
    pids = mirror_pids(address)
    for pid in pids:
        try:
            os.kill(pid, signal.SIGINT)
        except ProcessLookupError:
            pass
    deadline = time.time() + 6
    while time.time() < deadline and mirror_pids(address):
        time.sleep(0.2)
    remaining = mirror_pids(address)
    for pid in remaining:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    mirrors = load_mirrors()
    mirrors.pop(address, None)
    save_mirrors(mirrors)
    return pids, (remaining if remaining else [])


def device_report(device):
    address = device["address"]
    report = {
        "name": device.get("name") or device["model"],
        "model": device["model"],
        "device": device.get("device", ""),
        "serial": device["serial"],
        "address": address,
        "online": device.get("online", False),
    }
    if not report["online"]:
        return report
    code, out, _ = shell(address, "getprop ro.build.version.release; "
                                  "getprop ro.build.version.sdk; "
                                  "dumpsys power | grep -m1 mWakefulness=; "
                                  "dumpsys battery | grep -E 'level|status' | head -2",
                         timeout=15)
    values = [line.strip() for line in out.splitlines()]
    if len(values) >= 2:
        report["release"], report["sdk"] = values[0], values[1]
    for line in values:
        if line.startswith("mWakefulness="):
            report["wakefulness"] = line.split("=", 1)[1]
        if line.startswith("level:"):
            report["battery"] = line.split(":", 1)[1].strip()
    report["panel"] = panel_state(address)
    report["mirror_pids"] = mirror_pids(address)
    return report


# ------------------------------------------------------------------------- CLI

def cmd_list(args):
    devices = scan(deep=args.deep, refresh=args.refresh)
    if args.json:
        print(json.dumps(devices, indent=2, ensure_ascii=False))
        return 0
    if not devices:
        print("no devices found (try --deep)")
        return 1
    print("%-4s %-16s %-14s %-22s %-24s" % ("", "NAME", "MODEL", "ADDRESS", "NOTES"))
    for device in devices:
        mark = "*" if device["online"] else " "
        notes = []
        if device.get("address_changed_from"):
            notes.append("IP was %s" % device["address_changed_from"])
        if not device["online"]:
            notes.append("offline")
        print("%-4s %-16s %-14s %-22s %-24s" % (
            mark, device["name"][:16], device["model"][:14],
            device["address"], ", ".join(notes)))
    return 0


def cmd_info(args):
    device = resolve(args.device, deep=args.deep)
    if not device:
        print("device not found: %s" % args.device, file=sys.stderr)
        return 1
    print(json.dumps(device_report(device), indent=2, ensure_ascii=False))
    return 0


def cmd_shell(args):
    device = resolve(args.device, deep=args.deep)
    if not device:
        print("device not found: %s" % args.device, file=sys.stderr)
        return 1
    code, out, err = shell(device["address"], " ".join(args.command), timeout=args.timeout)
    sys.stdout.write(out)
    sys.stderr.write(err)
    return code


def cmd_screenshot(args):
    device = resolve(args.device, deep=args.deep)
    if not device:
        print("device not found: %s" % args.device, file=sys.stderr)
        return 1
    data, error = screenshot_png(device["address"])
    if not data:
        print("screenshot failed: %s" % error, file=sys.stderr)
        return 1
    path = args.out or "d3board-%s.png" % device["serial"]
    with open(path, "wb") as handle:
        handle.write(data)
    print("%s (%d bytes)" % (path, len(data)))
    return 0


def cmd_mirror(args):
    device = resolve(args.device)
    if not device:
        print("device not found: %s" % args.device, file=sys.stderr)
        return 1
    pids, error = start_mirror(device,
                               screen_off=not args.keep_screen_on,
                               native_resolution=args.native,
                               max_fps=args.max_fps,
                               bitrate=args.bitrate)
    if error:
        print(error, file=sys.stderr)
        return 1
    panel = "dark" if not args.keep_screen_on else "on"
    print("mirroring %s at %s (panel %s), pid %s"
          % (device["name"], device["address"], panel, pids[0]))
    return 0


def cmd_stop(args):
    targets = []
    if args.device:
        device = resolve(args.device)
        if not device:
            print("device not found: %s" % args.device, file=sys.stderr)
            return 1
        targets = [device["address"]]
    else:
        targets = list(load_mirrors().keys())
    if not targets:
        print("nothing is mirroring")
        return 0
    for address in targets:
        stopped, killed = stop_mirror(address)
        print("%s: stopped %s%s" % (address, stopped or "nothing",
                                    " (killed %s)" % killed if killed else ""))
    return 0


def cmd_wake(args):
    device = resolve(args.device)
    if not device:
        print("device not found: %s" % args.device, file=sys.stderr)
        return 1
    wake(device["address"])
    print("woke %s (%s)" % (device["name"], device["address"]))
    return 0


def cmd_install(args):
    device = resolve(args.device)
    if not device:
        print("device not found: %s" % args.device, file=sys.stderr)
        return 1
    code, out, err = adb(["-s", device["address"], "install", "-r", args.apk], timeout=600)
    sys.stdout.write(out)
    sys.stderr.write(err)
    return code


def cmd_transfer(args):
    device = resolve(args.device)
    if not device:
        print("device not found: %s" % args.device, file=sys.stderr)
        return 1
    if args.direction == "push":
        code, out, err = adb(["-s", device["address"], "push", args.local, args.remote], timeout=600)
    else:
        code, out, err = adb(["-s", device["address"], "pull", args.remote, args.local], timeout=600)
    sys.stdout.write(out)
    sys.stderr.write(err)
    return code


# ------------------------------------------------------------------------- MCP

def tool(name, description, properties, required=None):
    return {
        "name": name,
        "description": description,
        "inputSchema": {
            "type": "object",
            "properties": properties,
            "required": required or [],
            "additionalProperties": False,
        },
    }


DEVICE_ARG = {"type": "string",
              "description": "Device nickname, model, serial, or ip[:5555]. "
                             "Look it up with list_devices first."}

TOOL_DEFS = [
    tool("list_devices",
         "List the Android boards on this LAN: nickname, model, serial, address, online state. "
         "Devices are tracked by serial, so an address that changed is corrected here and shown "
         "as address_changed_from. Cheap by default; deep=true sweeps the whole subnet in ~1s.",
         {"deep": {"type": "boolean", "description": "Sweep the subnet instead of only known addresses."},
          "refresh": {"type": "boolean", "description": "Ignore the 10 second scan cache."}},
         []),
    tool("device_status",
         "Live status of one device: Android version, wakefulness, battery, whether the physical "
         "panel is powered off (panel.dark), and any scrcpy pids mirroring it.",
         {"device": DEVICE_ARG, "deep": {"type": "boolean"}},
         ["device"]),
    tool("adb_shell",
         "Run a shell command on a device and return its output. Use for anything adb can do: "
         "logcat, pm list packages, dumpsys, input tap/swipe, settings put, screencap -p to a file.",
         {"device": DEVICE_ARG,
          "command": {"type": "string", "description": "Shell command, e.g. 'dumpsys power | head -5'."},
          "timeout_seconds": {"type": "integer", "description": "Default 25."}},
         ["device", "command"]),
    tool("screenshot",
         "Capture the current device screen as a PNG (returned as image content). Use it to see "
         "what is actually on the board instead of guessing.",
         {"device": DEVICE_ARG},
         ["device"]),
    tool("mirror",
         "Open a scrcpy window on this Mac for the device. screen_off=true (default) powers the "
         "physical panel down so nobody standing at the box sees anything, while video and control "
         "keep working. Returns the pid. Requires a GUI session on this Mac.",
         {"device": DEVICE_ARG,
          "screen_off": {"type": "boolean", "description": "Power the physical panel off. Default true."},
          "native_resolution": {"type": "boolean", "description": "Use the device resolution instead of 1024px wide."},
          "max_fps": {"type": "integer", "description": "Default 30."},
          "bitrate": {"type": "string", "description": "Default 2M."}},
         ["device"]),
    tool("stop_mirror",
         "Close the scrcpy window for a device (or every device when it is omitted) and let it "
         "restore the physical panel.",
         {"device": DEVICE_ARG},
         []),
    tool("wake_screen",
         "Send KEYCODE_WAKEUP and dismiss the keyguard. Use when the panel is on but the device is "
         "asleep, or after an app left the screen off.",
         {"device": DEVICE_ARG},
         ["device"]),
    tool("install_apk",
         "Install or reinstall an APK from a path on this Mac (adb install -r).",
         {"device": DEVICE_ARG,
          "apk_path": {"type": "string", "description": "Absolute path on this Mac."}},
         ["device", "apk_path"]),
    tool("transfer_file",
         "Push a file to the device or pull one back. direction is 'push' or 'pull'.",
         {"device": DEVICE_ARG,
          "direction": {"type": "string", "enum": ["push", "pull"]},
          "local_path": {"type": "string"},
          "remote_path": {"type": "string", "description": "e.g. /sdcard/Download/log.txt"}},
         ["device", "direction", "local_path", "remote_path"]),
]

TOOL_MAP = {entry["name"]: entry for entry in TOOL_DEFS}


def text_result(text, is_error=False):
    return {"content": [{"type": "text", "text": text}], "isError": is_error}


def call_tool(name, arguments):
    if name not in TOOL_MAP:
        raise KeyError("unknown tool: %s" % name)

    if name == "list_devices":
        devices = scan(deep=bool(arguments.get("deep")), refresh=bool(arguments.get("refresh")))
        if not devices:
            return text_result("no devices found; try deep=true", True)
        lines = ["%s %s (%s) %s%s" % (
            "*" if d["online"] else "-", d["name"], d["model"], d["address"],
            " [IP was %s]" % d["address_changed_from"] if d.get("address_changed_from") else "",
        ) for d in devices]
        return text_result("\n".join(lines) + "\n\n" + json.dumps(devices, ensure_ascii=False))

    if name == "screenshot":
        device = resolve(arguments["device"], deep=bool(arguments.get("deep")))
        if not device:
            return text_result("device not found: %s" % arguments["device"], True)
        data, error = screenshot_png(device["address"])
        if not data:
            return text_result("screenshot failed: %s" % error, True)
        return {"content": [
            {"type": "image", "data": base64.b64encode(data).decode("ascii"), "mimeType": "image/png"},
            {"type": "text", "text": "%s (%s) %d bytes" % (device["name"], device["address"], len(data))},
        ]}

    device = resolve(arguments["device"], deep=bool(arguments.get("deep")))
    if not device and name != "stop_mirror":
        return text_result("device not found: %s (run list_devices, or pass deep=true)"
                           % arguments["device"], True)

    if name == "device_status":
        return text_result(json.dumps(device_report(device), indent=2, ensure_ascii=False))

    if name == "adb_shell":
        timeout = int(arguments.get("timeout_seconds") or 25)
        code, out, err = shell(device["address"], arguments["command"], timeout=timeout)
        body = out if out else ""
        if err:
            body += ("\n[stderr] " + err) if body else err
        if code not in (0,):
            body += "\n[exit %s]" % code
        return text_result(body.strip() or "(no output)", code != 0)

    if name == "mirror":
        pids, error = start_mirror(
            device,
            screen_off=arguments.get("screen_off", True),
            native_resolution=bool(arguments.get("native_resolution")),
            max_fps=int(arguments.get("max_fps") or 30),
            bitrate=arguments.get("bitrate") or "2M",
        )
        if error:
            return text_result(error, True)
        return text_result("mirroring %s at %s, pid %s, panel %s" % (
            device["name"], device["address"], pids[0],
            "off" if arguments.get("screen_off", True) else "on"))

    if name == "stop_mirror":
        if device:
            addresses = [device["address"]]
        else:
            addresses = list(load_mirrors().keys())
        if not addresses:
            return text_result("nothing is mirroring")
        report = []
        for address in addresses:
            stopped, killed = stop_mirror(address)
            report.append("%s: stopped %s%s" % (address, stopped or "nothing",
                                                " (killed %s)" % killed if killed else ""))
        return text_result("\n".join(report))

    if name == "wake_screen":
        wake(device["address"])
        return text_result("woke %s (%s)" % (device["name"], device["address"]))

    if name == "install_apk":
        path = arguments["apk_path"]
        if not os.path.isfile(path):
            return text_result("no such file: %s" % path, True)
        code, out, err = adb(["-s", device["address"], "install", "-r", path], timeout=900)
        return text_result((out + err).strip() or "(no output)", code != 0)

    if name == "transfer_file":
        direction = arguments["direction"]
        if direction == "push":
            if not os.path.exists(arguments["local_path"]):
                return text_result("no such file: %s" % arguments["local_path"], True)
            code, out, err = adb(["-s", device["address"], "push",
                                  arguments["local_path"], arguments["remote_path"]], timeout=900)
        else:
            code, out, err = adb(["-s", device["address"], "pull",
                                  arguments["remote_path"], arguments["local_path"]], timeout=900)
        return text_result((out + err).strip() or "(no output)", code != 0)

    return text_result("unhandled tool %s" % name, True)


def handle_message(message):
    """Return the JSON-RPC response, or None for notifications."""
    method = message.get("method")
    identifier = message.get("id")
    params = message.get("params") or {}
    is_notification = identifier is None

    if method == "initialize":
        requested = params.get("protocolVersion")
        version = requested if isinstance(requested, str) else "2025-06-18"
        result = {
            "protocolVersion": version,
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": {"name": "d3board", "version": "1.1.0"},
            "instructions": "Control the LAN Android boards: list_devices, then screenshot or "
                            "adb_shell on one. mirror opens a window on this Mac with the physical "
                            "panel switched off.",
        }
    elif method == "ping":
        result = {}
    elif method == "tools/list":
        result = {"tools": TOOL_DEFS}
    elif method == "tools/call":
        try:
            result = call_tool(params.get("name"), params.get("arguments") or {})
        except KeyError as error:
            return {"jsonrpc": "2.0", "id": identifier,
                    "error": {"code": -32602, "message": str(error)}}
        except Exception as error:                    # noqa: BLE001 - never kill the server
            return {"jsonrpc": "2.0", "id": identifier,
                    "result": text_result("error: %s" % error, True)}
    elif method == "resources/list":
        result = {"resources": []}
    elif method == "prompts/list":
        result = {"prompts": []}
    elif method in ("notifications/initialized", "notifications/cancelled",
                    "notifications/progress", "$/cancelRequest"):
        return None
    elif method:
        if is_notification:
            return None
        return {"jsonrpc": "2.0", "id": identifier,
                "error": {"code": -32601, "message": "method not found: %s" % method}}
    else:
        return None

    if is_notification:
        return None
    return {"jsonrpc": "2.0", "id": identifier, "result": result}


def serve():
    log("ready (adb=%s scrcpy=%s)" % (TOOLS.adb, TOOLS.scrcpy))
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except ValueError:
            continue
        response = handle_message(message)
        if response is not None:
            sys.stdout.write(json.dumps(response) + "\n")
            sys.stdout.flush()
    return 0


# ----------------------------------------------------------------------- entry

def main(argv=None):
    parser = argparse.ArgumentParser(prog="d3board", description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd")

    listing = sub.add_parser("list", help="list devices")
    listing.add_argument("--deep", action="store_true", help="sweep the subnet")
    listing.add_argument("--refresh", action="store_true", help="ignore the scan cache")
    listing.add_argument("--json", action="store_true")
    listing.set_defaults(func=cmd_list)

    info = sub.add_parser("info", help="live status of one device")
    info.add_argument("device")
    info.add_argument("--deep", action="store_true")
    info.set_defaults(func=cmd_info)

    sh = sub.add_parser("shell", help="run a shell command on a device")
    sh.add_argument("device")
    sh.add_argument("command", nargs=argparse.REMAINDER)
    sh.add_argument("--timeout", type=int, default=25)
    sh.add_argument("--deep", action="store_true")
    sh.set_defaults(func=cmd_shell)

    shot = sub.add_parser("screenshot", help="save a device screenshot")
    shot.add_argument("device")
    shot.add_argument("-o", "--out")
    shot.add_argument("--deep", action="store_true")
    shot.set_defaults(func=cmd_screenshot)

    mir = sub.add_parser("mirror", help="open scrcpy, panel off by default")
    mir.add_argument("device")
    mir.add_argument("--native", action="store_true", help="device resolution")
    mir.add_argument("--keep-screen-on", action="store_true")
    mir.add_argument("--max-fps", type=int, default=30)
    mir.add_argument("--bitrate", default="2M")
    mir.set_defaults(func=cmd_mirror)

    stop = sub.add_parser("stop", help="stop mirroring")
    stop.add_argument("device", nargs="?")
    stop.set_defaults(func=cmd_stop)

    wk = sub.add_parser("wake", help="wake the screen")
    wk.add_argument("device")
    wk.set_defaults(func=cmd_wake)

    inst = sub.add_parser("install", help="install an apk")
    inst.add_argument("device")
    inst.add_argument("apk")
    inst.set_defaults(func=cmd_install)

    xfer = sub.add_parser("transfer", help="push or pull a file")
    xfer.add_argument("device")
    xfer.add_argument("direction", choices=["push", "pull"])
    xfer.add_argument("local")
    xfer.add_argument("remote")
    xfer.set_defaults(func=cmd_transfer)

    mcp = sub.add_parser("mcp", help="run the MCP server on stdio")
    mcp.set_defaults(func=lambda _args: serve())

    args = parser.parse_args(argv)
    if not getattr(args, "func", None):
        parser.print_help()
        return 1
    if args.cmd == "shell" and getattr(args, "command", None) == []:
        parser.error("shell needs a command")
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
