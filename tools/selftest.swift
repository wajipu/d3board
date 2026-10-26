import Foundation

// Headless end-to-end test of the same Engine the GUI uses:
//   swiftc Sources/Engine.swift tools/selftest.swift -o d3selftest
// Discovery, registry bookkeeping, mirror start/stop and panel state.

let engine = Engine.shared
engine.onLog = { print("LOG  \($0)") }
engine.onChange = {
    for row in engine.rows {
        print("ROW  \(row.online ? "on " : "off") \(row.name)  \(row.address)  mirror=\(row.mirroring)")
    }
}

func pump(_ seconds: Double) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

engine.tools.resolve()
print("adb     \(engine.tools.adb)")
print("scrcpy  \(engine.tools.scrcpy)")
if engine.tools.scrcpy.isEmpty { print("FAIL: scrcpy not found"); exit(1) }

engine.rescan(deep: true, reason: "selftest")
var start = Date()
let scanDeadline = Date().addingTimeInterval(60)
while engine.rows.isEmpty && Date() < scanDeadline { pump(0.2) }
print("deep scan took  \(String(format: "%.1f", Date().timeIntervalSince(start)))s")

// second pass: same devices, no sweep — this is what the 30s guardian does
let before = engine.lastScanAt
engine.rescan(deep: false, reason: "selftest-shallow")
start = Date()
while engine.lastScanAt == before && Date().timeIntervalSince(start) < 40 { pump(0.1) }
print("shallow scan took \(String(format: "%.1f", Date().timeIntervalSince(start)))s")

guard !engine.rows.isEmpty else { print("FAIL: no devices found"); exit(1) }
guard let target = engine.rows.first(where: { $0.model == "D3-503" || $0.device.hasPrefix("rk3568") }) else {
    print("FAIL: D3-503 not found")
    exit(1)
}
print("target  \(target.name)  \(target.address)  serial=\(target.serial)")

// panel state before
func panelState() -> String {
    let out = runProcess(engine.tools.adb, ["-s", target.address, "shell", "cat /sys/class/backlight/backlight/bl_power"], timeout: 8)
    return out.out.trimmingCharacters(in: .whitespacesAndNewlines)
}
print("panel before  \(panelState())  (0=lit, 4=dark)")

engine.startMirror(serial: target.serial)
pump(9)

let scrcpyRunning = !runProcess("/usr/bin/pgrep", ["-fl", "scrcpy -s \(target.address)"], timeout: 5).out.isEmpty
print("scrcpy running  \(scrcpyRunning)")
print("panel during  \(panelState())  (expect 4)")

engine.stopMirror(serial: target.serial)
pump(4)
print("panel after   \(panelState())  (expect 0)")
let stillRunning = !runProcess("/usr/bin/pgrep", ["-fl", "scrcpy -s \(target.address)"], timeout: 5).out.isEmpty
print("scrcpy after  \(stillRunning ? "STILL RUNNING" : "stopped")")

let ok = scrcpyRunning && panelState() == "0" && !stillRunning
print(ok ? "SELFTEST PASS" : "SELFTEST FAIL")
exit(ok ? 0 : 1)
