#!/usr/bin/env python3
"""Protocol test for the d3board MCP server.

    python3 tools/test_mcp.py

Talks to `mcp/d3board.py mcp` over stdio exactly like an MCP client does, so it
catches framing/handshake mistakes that a plain unit test would miss. The device
part is skipped (not failed) when no board is reachable, which is what CI does.
"""

import json
import os
import queue
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER = os.path.join(os.path.dirname(HERE), "mcp", "d3board.py")
TIMEOUT = 90

failures = []


def check(label, condition, detail=""):
    if condition:
        print("ok    %s" % label)
    else:
        print("FAIL  %s %s" % (label, detail))
        failures.append(label)


class Client(object):
    def __init__(self):
        self.stderr = open("/tmp/d3board-mcp-test.log", "w")
        self.proc = subprocess.Popen(
            [sys.executable, SERVER, "mcp"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.stderr,
            text=True, bufsize=1,
        )
        self.inbox = queue.Queue()
        self.thread = threading.Thread(target=self._pump, daemon=True)
        self.thread.start()
        self.counter = 0

    def _pump(self):
        for line in self.proc.stdout:
            self.inbox.put(line)
        self.inbox.put(None)

    def send(self, message):
        self.proc.stdin.write(json.dumps(message) + "\n")
        self.proc.stdin.flush()

    def notify(self, method, params=None):
        self.send({"jsonrpc": "2.0", "method": method, "params": params or {}})

    def request(self, method, params=None):
        self.counter += 1
        identifier = self.counter
        self.send({"jsonrpc": "2.0", "id": identifier, "method": method,
                   "params": params or {}})
        deadline = time.time() + TIMEOUT
        while time.time() < deadline:
            try:
                line = self.inbox.get(timeout=max(0.1, deadline - time.time()))
            except queue.Empty:
                break
            if line is None:
                break
            response = json.loads(line)
            if response.get("id") == identifier:
                return response
        raise RuntimeError("no response to %s" % method)

    def close(self):
        try:
            self.proc.stdin.close()
        except Exception:
            pass
        try:
            self.proc.wait(timeout=10)
        except Exception:
            self.proc.kill()
        self.stderr.close()


def main():
    if not os.path.isfile(SERVER):
        print("FAIL  server not found: %s" % SERVER)
        return 1

    client = Client()
    try:
        init = client.request("initialize", {
            "protocolVersion": "2025-06-18",
            "capabilities": {},
            "clientInfo": {"name": "test_mcp", "version": "1"},
        })
        result = init.get("result") or {}
        check("initialize: serverInfo", result.get("serverInfo", {}).get("name") == "d3board",
              json.dumps(result.get("serverInfo")))
        check("initialize: protocol echoed",
              result.get("protocolVersion") == "2025-06-18", str(result.get("protocolVersion")))
        check("initialize: advertises tools",
              "tools" in (result.get("capabilities") or {}))
        client.notify("notifications/initialized")

        pong = client.request("ping")
        check("ping", pong.get("result") == {})

        listing = client.request("tools/list")
        tools = (listing.get("result") or {}).get("tools") or []
        names = {entry.get("name") for entry in tools}
        expected = {"list_devices", "device_status", "adb_shell", "screenshot", "mirror",
                    "stop_mirror", "wake_screen", "install_apk", "transfer_file"}
        check("tools/list: all tools present", expected <= names, str(expected - names))
        check("tools/list: every tool has a schema",
              all(entry.get("inputSchema", {}).get("type") == "object" for entry in tools))

        unknown = client.request("definitely/not/a/method")
        check("unknown method -> -32601",
              (unknown.get("error") or {}).get("code") == -32601, json.dumps(unknown))

        bad = client.request("tools/call", {"name": "no_such_tool", "arguments": {}})
        check("unknown tool -> -32602",
              (bad.get("error") or {}).get("code") == -32602, json.dumps(bad))

        devices = client.request("tools/call", {"name": "list_devices",
                                                "arguments": {"deep": False}})
        content = (devices.get("result") or {}).get("content") or []
        text = "".join(part.get("text", "") for part in content if part.get("type") == "text")
        check("list_devices returns text", bool(text), json.dumps(devices)[:200])

        if devices.get("result", {}).get("isError"):
            print("skip  device tools (no adb device reachable: %s)" % text.strip()[:80])
        else:
            first = None
            for line in text.splitlines():
                if line.startswith("* "):
                    first = line
                    break
            check("list_devices found an online device", first is not None, text[:120])
            if first:
                name = first[2:].split(" (")[0]
                status = client.request("tools/call", {"name": "device_status",
                                                       "arguments": {"device": name}})
                status_text = "".join(part.get("text", "")
                                      for part in (status.get("result") or {}).get("content", []))
                check("device_status returns json", "\"serial\"" in status_text, status_text[:120])

                shot = client.request("tools/call", {"name": "screenshot",
                                                    "arguments": {"device": name}})
                parts = (shot.get("result") or {}).get("content") or []
                image = [part for part in parts if part.get("type") == "image"]
                check("screenshot returns png image", bool(image) and image[0].get("mimeType") == "image/png",
                      str([p.get("type") for p in parts]))

                shell = client.request("tools/call", {
                    "name": "adb_shell",
                    "arguments": {"device": name, "command": "getprop ro.product.model"}})
                shell_text = "".join(part.get("text", "")
                                     for part in (shell.get("result") or {}).get("content", []))
                check("adb_shell runs a command", bool(shell_text.strip()), shell_text[:120])
    finally:
        client.close()

    if failures:
        print("\n%d check(s) failed" % len(failures))
        return 1
    print("\nall checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
