---
name: d3board
description: >-
  Drive the Android boards in this lab (D3-503, MiTV, BB66...) from the Mac:
  list them, take screenshots, run adb shell commands, install APKs, and open a
  scrcpy window with the physical panel switched off. Use whenever the task
  mentions the D3 board, an RK3568/RK3566/amlogic test box, a LAN Android device,
  mirroring a board, watching a board's screen, or running adb against a device
  on this network. Also use it to fix a board whose IP changed — never edit an
  address by hand. Not for iPhones, simulators, or cloud phones.
---

# D3Board

Control the Android boxes on this LAN through the `d3board` MCP server. If the MCP
tools are not available in this session, the same thing works as a CLI:

```sh
python3 <repo>/mcp/d3board.py list          # add --deep to sweep the subnet
python3 <repo>/mcp/d3board.py info D3-503
python3 <repo>/mcp/d3board.py screenshot D3-503 -o /tmp/board.png
python3 <repo>/mcp/d3board.py shell D3-503 getprop ro.product.model
python3 <repo>/mcp/d3board.py mirror D3-503        # panel goes dark
python3 <repo>/mcp/d3board.py stop D3-503          # panel comes back
```

## Start every task the same way

1. `list_devices` (MCP) / `list` (CLI). Devices are keyed by `ro.serialno`, so the
   returned `address` is current even after a DHCP change — **never hardcode an IP
   from memory or from an old log**.
2. If a board you need shows as offline, call `list_devices` with `deep=true` before
   telling anyone it is gone: the address probably moved, and a deep scan re-finds it
   in about a second.
3. Address the device by **name or serial** in every later call. `D3-503`,
   `ND3503XEA337C0015` and `192.168.40.157:5555` all resolve to the same board, but
   only the first two survive an IP change.

## Seeing what is on the board

Use `screenshot` instead of guessing from logs. It returns a PNG of the framebuffer,
which works even while the physical panel is dark (that is a hardware backlight
state, not a display state).

For "what is running": `adb_shell` with `dumpsys activity activities | grep -m3 mResumed`,
`pm list packages | grep -i <name>`, or `logcat -d -t 200` (**always `-d`**, a bare
`logcat` never returns and will eat the timeout).

## Mirroring

- `mirror` opens an scrcpy window on this Mac. `screen_off` defaults to true, which
  powers the panel down — anyone standing at the box sees a black screen while you
  keep video and control. Use `screen_off=false` only when someone at the machine
  needs to see it too.
- `stop_mirror` closes it and restores the panel. When it is omitted, every mirror
  stops.
- Mirroring is for a human or for you to look at live video. For a one-off look, a
  `screenshot` is cheaper and does not need a GUI session.
- Only one mirror per board; calling `mirror` twice returns the existing pid.

## Things that will bite you

- **Never `pkill scrcpy`.** scrcpy 4.x ignores SIGTERM and can leave the panel dark;
  use `stop_mirror` (it sends SIGINT and waits).
- **No root.** `su` does not exist and `/sys/class/backlight/.../bl_power` is
  root-owned, so the panel cannot be switched from the shell. Only scrcpy's
  `--turn-screen-off` can do it.
- **The boards are shared.** Check `device_status` (or a screenshot) before typing on
  one — someone may be running a manual test. Do not install APKs, wipe data, or
  change settings unless the task explicitly asks.
- **adb_shell output is raw.** Quote carefully, and remember the device shell is
  older Android 11 `sh`: no `grep -P`, no bash arrays.
- A host can answer on port 5555 without being a useful device (there is a Linux box
  doing exactly that). The server already filters those out; if a device disappears
  from the list, that is why — pass `--deep`/`deep=true` to retry rather than
  editing the registry by hand.
- The GUI app (`D3Board.app`) and this server share one registry
  (`~/Library/Application Support/D3Board/devices.json`). Editing that file by hand
  is never necessary; `list_devices` fixes it.

## Reporting back

When you are done with a board, say what you did to it and leave it in the state you
found it: panel restored (no mirror left running) unless the task asked for the panel
to stay dark.
