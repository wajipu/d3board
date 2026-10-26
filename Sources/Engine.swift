import Foundation

// MARK: - Process plumbing

struct RunResult {
    var code: Int32
    var out: String
}

func runProcess(_ path: String, _ args: [String], timeout: Double = 20) -> RunResult {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args

    var environment = ProcessInfo.processInfo.environment
    let extraPath = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    environment["PATH"] = extraPath + ":" + (environment["PATH"] ?? "")
    p.environment = environment

    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    p.standardInput = FileHandle.nullDevice

    let finished = DispatchSemaphore(value: 0)
    p.terminationHandler = { _ in finished.signal() }

    do {
        try p.run()
    } catch {
        return RunResult(code: -1, out: "launch failed: \(error.localizedDescription)")
    }

    let collected = NSMutableData()
    let readDone = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .utility).async {
        collected.append(pipe.fileHandleForReading.readDataToEndOfFile())
        readDone.signal()
    }

    if finished.wait(timeout: .now() + timeout) == .timedOut {
        p.terminate()
        _ = finished.wait(timeout: .now() + 2)
    }
    _ = readDone.wait(timeout: .now() + 3)
    return RunResult(code: p.terminationStatus, out: String(decoding: collected as Data, as: UTF8.self))
}

// MARK: - External tools

final class Tools {
    static let shared = Tools()
    private(set) var adb: String = "/usr/bin/env"
    private(set) var scrcpy: String = ""
    private var resolved = false

    func resolve() {
        guard !resolved else { return }
        resolved = true
        let home = NSHomeDirectory()
        adb = Tools.locate("adb", candidates: [
            "/opt/homebrew/share/android-commandlinetools/platform-tools/adb",
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            home + "/Library/Android/sdk/platform-tools/adb",
            home + "/.local/bin/adb",
        ]) ?? "/usr/bin/env"
        scrcpy = Tools.locate("scrcpy", candidates: [
            "/opt/homebrew/bin/scrcpy",
            "/usr/local/bin/scrcpy",
        ]) ?? ""
    }

    private static func locate(_ name: String, candidates: [String]) -> String? {
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        // Fall back to the user's interactive shell, which is where adb/scrcpy
        // usually get onto PATH (GUI apps start with a minimal environment).
        let found = runProcess("/bin/zsh", ["-lic", "command -v \(name)"], timeout: 10)
        for line in found.out.split(separator: "\n").reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: trimmed) {
                return trimmed
            }
        }
        return nil
    }
}

// MARK: - Persistent device registry (the IP bookkeeping)

/// Real Android serials are alphanumeric with `._-`; anything else came from a
/// shell error message and must never be stored as a device.
func looksLikeSerial(_ value: String) -> Bool {
    guard value.count >= 4, value.count <= 64 else { return false }
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
    return value.unicodeScalars.allSatisfy { allowed.contains($0) }
}

struct KnownDevice: Codable {
    var serial: String
    var model: String
    var device: String
    var nickname: String
    var lastAddress: String
    var previousAddress: String?
    var lastSeen: Date
}

final class Registry {
    private(set) var items: [String: KnownDevice] = [:]
    private let fileURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("D3Board", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("devices.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([KnownDevice].self, from: data) {
            for item in decoded where looksLikeSerial(item.serial) {
                items[item.serial] = item
            }
        }
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(Array(items.values)) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func record(serial: String, model: String, device: String, address: String) -> (record: KnownDevice, previousAddress: String?) {
        var entry = items[serial] ?? KnownDevice(
            serial: serial, model: model, device: device, nickname: "",
            lastAddress: address, previousAddress: nil, lastSeen: Date()
        )
        let previous = items[serial]?.lastAddress
        if let previous, previous != address { entry.previousAddress = previous }
        entry.model = model.isEmpty ? entry.model : model
        entry.device = device.isEmpty ? entry.device : device
        entry.lastAddress = address
        entry.lastSeen = Date()
        items[serial] = entry
        save()
        return (entry, previous)
    }

    func setNickname(_ name: String, for serial: String) {
        guard var entry = items[serial] else { return }
        entry.nickname = name
        items[serial] = entry
        save()
    }
}

// MARK: - Snapshot for the UI

struct DeviceRow {
    var serial: String
    var name: String
    var model: String
    var device: String
    var address: String
    var online: Bool
    var mirroring: Bool
    var ipChangedFrom: String?
}

struct Discovered {
    var serial: String
    var model: String
    var device: String
    var release: String
    var sdk: String
    var address: String
}

// MARK: - Engine

final class Engine {
    static let shared = Engine()

    let tools = Tools.shared
    let registry = Registry()

    private let work = DispatchQueue(label: "d3board.work")
    private let stateLock = NSLock()

    private(set) var rows: [DeviceRow] = []
    private var online: [String: Discovered] = [:]      // serial -> probed device (main thread only)
    private var mirrorProcs: [String: Process] = [:]    // main thread only
    private var mirroring: Set<String> = []             // main thread only
    private var scanning = false
    private var lastDeepScan = Date.distantPast
    private var lastOnline: Set<String> = []
    private let rejectedLock = NSLock()
    private var rejectedUntil: [String: Date] = [:]
    private var guardian: Timer?

    var onChange: (() -> Void)?
    var onLog: ((String) -> Void)?
    var onScanState: ((Bool) -> Void)?

    var lastScanAt: Date?
    var nativeResolution: Bool {
        get { UserDefaults.standard.bool(forKey: "nativeResolution") }
        set { UserDefaults.standard.set(newValue, forKey: "nativeResolution") }
    }

    /// Per-device mirror overrides. TVs with a software encoder are the reason
    /// this exists: their hardware ceiling is low, so the global "1024px/2M for
    /// smoothness" default looks like mud, while the boards with a Rockchip
    /// encoder are fine with it. Keyed by serial, same as everything else.
    private struct MirrorTuning: Codable {
        var maxSize: Int?
        var bitRate: String?
    }

    private static let defaultTuning: [String: MirrorTuning] = [
        // MiTV-ASTP0 (MTK mulan): OMX.google soft encoder only — raise the
        // clarity instead of fighting for fps it cannot deliver anyway.
        "MiTV-ASTP0": MirrorTuning(maxSize: 1920, bitRate: "8M"),
    ]

    private func tuning(for serial: String) -> MirrorTuning {
        // Custom override wins, then the built-in table by model, then the
        // global default (nil = whatever startMirror normally does).
        if let data = UserDefaults.standard.data(forKey: "mirrorTuning.\(serial)"),
           let custom = try? JSONDecoder().decode(MirrorTuning.self, from: data) {
            return custom
        }
        let model = registry.items[serial]?.model ?? ""
        return Engine.defaultTuning[model] ?? MirrorTuning(maxSize: nil, bitRate: nil)
    }

    // MARK: lifecycle

    func bootstrap() {
        tools.resolve()
        log("adb    \(tools.adb)")
        log("scrcpy \(tools.scrcpy.isEmpty ? "未找到！镜像功能不可用" : tools.scrcpy)")
        log("记录文件 \(registryFileDescription())")
        // First run: nothing on file, so sweep the whole subnet. Afterwards the
        // remembered addresses are enough, and a sweep only happens if one of
        // them stops answering.
        rescan(deep: registry.items.isEmpty, reason: "启动")
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            let offline = self.rows.contains { !$0.online }
            let deepNeeded = offline && Date().timeIntervalSince(self.lastDeepScan) > 120
            self.rescan(deep: deepNeeded, reason: deepNeeded ? "守护(全网段)" : "守护")
        }
        RunLoop.main.add(timer, forMode: .common)
        guardian = timer
    }

    private func registryFileDescription() -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("D3Board/devices.json").path
    }

    func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        onLog?("[\(formatter.string(from: Date()))] \(message)")
    }

    // MARK: scanning

    func rescan(deep: Bool, reason: String) {
        stateLock.lock()
        if scanning {
            stateLock.unlock()
            return
        }
        scanning = true
        stateLock.unlock()

        onScanState?(true)
        log("扫描开始（\(reason)\(deep ? "，含全网段" : "")）")
        if deep { lastDeepScan = Date() }
        let known = registry.items   // snapshot: the registry is main-thread owned

        work.async { [weak self] in
            guard let self else { return }
            let phaseStart = Date()
            let addresses = self.candidates(deep: deep, known: known)
            let phaseAddresses = Date()
            let found = self.probeAll(addresses)
            let phaseProbes = Date()
            let listTime = String(format: "%.1f", phaseAddresses.timeIntervalSince(phaseStart))
            let probeTime = String(format: "%.1f", phaseProbes.timeIntervalSince(phaseAddresses))
            let count = addresses.count

            DispatchQueue.main.async {
                self.stateLock.lock()
                self.scanning = false
                self.stateLock.unlock()
                self.apply(found)
                self.lastScanAt = Date()
                self.onScanState?(false)
                self.publish()
                self.log("扫描完成：候选 \(count) 个，找设备 \(listTime)s，探测 \(probeTime)s")

                // A quick scan only knows the addresses we already had on file. If
                // one of them went away (DHCP moved it) retry with a full sweep, so
                // the user never has to think about IPs.
                let offline = self.rows.contains { !$0.online }
                if !deep, offline, Date().timeIntervalSince(self.lastDeepScan) > 60 {
                    self.rescan(deep: true, reason: "有设备离线，全网段查找")
                }
            }
        }
    }

    private func candidates(deep: Bool, known: [String: KnownDevice]) -> [String] {
        var set = Set<String>()
        for entry in known.values { set.insert(normalize(entry.lastAddress)) }

        let current = runProcess(tools.adb, ["devices"], timeout: 8).out
        for line in current.split(separator: "\n") {
            let fields = line.split(separator: "\t")
            if let first = fields.first, first.contains(":") { set.insert(String(first)) }
        }

        let mdns = runProcess(tools.adb, ["mdns", "services"], timeout: 8).out
        for line in mdns.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            if fields.count >= 3, fields[2].contains(":") { set.insert(String(fields[2])) }
        }

        if deep { for address in sweep() { set.insert(address) } }
        return Array(set)
    }

    private func normalize(_ address: String) -> String {
        address.contains(":") ? address : address + ":5555"
    }

    private func localSubnet() -> String? {
        let route = runProcess("/sbin/route", ["-n", "get", "default"], timeout: 5).out
        guard let line = route.split(separator: "\n").first(where: { $0.contains("interface:") }),
              let iface = line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) else { return nil }
        let ip = runProcess("/usr/sbin/ipconfig", ["getifaddr", iface], timeout: 5)
            .out.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return nil }
        return parts.prefix(3).joined(separator: ".")
    }

    private func sweep() -> [String] {
        guard let base = localSubnet() else { return [] }
        // The ARP table already knows which hosts exist on this LAN, so probe
        // those first; only fall back to the whole /24 when none of them has
        // 5555 open. That turns a 25s sweep into well under a second.
        var addresses = portScan(arpHosts(base))
        if addresses.isEmpty {
            addresses = portScan((1...254).map { "\(base).\($0)" })
        }
        return addresses
    }

    private func arpHosts(_ base: String) -> [String] {
        let output = runProcess("/usr/sbin/arp", ["-an"], timeout: 5).out
        var hosts: [String] = []
        var seen = Set<String>()
        for line in output.split(separator: "\n") {
            // Skip "(incomplete)" entries: no MAC means nothing is there, and
            // probing them would just burn the 1s connect timeout.
            if line.contains("(incomplete)") { continue }
            guard let open = line.firstIndex(of: "("), let close = line.firstIndex(of: ")") else { continue }
            let ip = String(line[line.index(after: open)..<close])
            guard ip.hasPrefix(base + "."), !seen.contains(ip) else { continue }
            seen.insert(ip)
            hosts.append(ip)
        }
        return hosts
    }

    private func portScan(_ addresses: [String]) -> [String] {
        guard !addresses.isEmpty else { return [] }
        let hits = UnsafeMutablePointer<Bool>.allocate(capacity: addresses.count)
        hits.initialize(repeating: false, count: addresses.count)
        defer {
            hits.deinitialize(count: addresses.count)
            hits.deallocate()
        }
        // 64 in flight, short timeout: a LAN host answers in a few ms, so only
        // dead-but-cached ARP entries pay the timeout at all.
        let semaphore = DispatchSemaphore(value: 64)
        let group = DispatchGroup()
        for (index, address) in addresses.enumerated() {
            semaphore.wait()
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer {
                    semaphore.signal()
                    group.leave()
                }
                if self.portIsOpen(address, port: 5555, timeoutMs: 200) {
                    hits[index] = true
                }
            }
        }
        group.wait()
        var open: [String] = []
        for (index, address) in addresses.enumerated() where hits[index] {
            open.append(address + ":5555")
        }
        return open
    }

    /// Non-blocking TCP connect: cheap enough to sweep a /24 without spawning
    /// hundreds of `nc` processes, which was the slowest part of a deep scan.
    private func portIsOpen(_ ip: String, port: UInt16, timeoutMs: Int32) -> Bool {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, ip, &address.sin_addr) == 1 else { return false }

        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        let flags = fcntl(descriptor, F_GETFL, 0)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)

        var sockaddrValue = address
        let result = withUnsafePointer(to: &sockaddrValue) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                connect(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        guard poll(&pollDescriptor, 1, timeoutMs) > 0 else { return false }

        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 else { return false }
        return socketError == 0
    }

    private func probeAll(_ addresses: [String]) -> [Discovered] {
        let usable = addresses.filter { !isRejected($0) }
        guard !usable.isEmpty else { return [] }
        let buffer = UnsafeMutablePointer<Discovered?>.allocate(capacity: usable.count)
        buffer.initialize(repeating: nil, count: usable.count)
        defer {
            buffer.deinitialize(count: usable.count)
            buffer.deallocate()
        }
        let adb = tools.adb
        DispatchQueue.concurrentPerform(iterations: usable.count) { index in
            buffer[index] = probe(usable[index], adb: adb)
        }
        var results: [Discovered] = []
        for index in 0..<usable.count {
            if let device = buffer[index] { results.append(device) }
        }
        return results
    }

    // Hosts that answer on 5555 and even claim to be connected, but are not
    // Android (a Linux box with adbd, a stale transport). Without this, every
    // scan pays their shell timeout before giving up.
    private func isRejected(_ address: String) -> Bool {
        rejectedLock.lock()
        defer { rejectedLock.unlock() }
        guard let until = rejectedUntil[address] else { return false }
        return until > Date()
    }

    private func reject(_ address: String) {
        rejectedLock.lock()
        rejectedUntil[address] = Date().addingTimeInterval(300)
        rejectedLock.unlock()
    }

    private func clearRejection(_ address: String) {
        rejectedLock.lock()
        rejectedUntil[address] = nil
        rejectedLock.unlock()
    }

    private func probe(_ address: String, adb: String) -> Discovered? {
        // A host that merely exposes port 5555 answers TCP but never completes
        // the adb handshake; bail out on the connect result instead of paying a
        // shell timeout for it.
        let connected = runProcess(adb, ["connect", address], timeout: 2.5)
        guard connected.out.contains("connected to") else { return nil }

        // Full `getprop` dump, parsed as "[key]: [value]" — a Linux box running
        // adbd has no ro.serialno and is rejected instead of becoming a row.
        let result = runProcess(adb, ["-s", address, "shell", "getprop"], timeout: 6)
        var props: [String: String] = [:]
        for line in result.out.split(separator: "\n") {
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { continue }
            let key = String(line[line.index(after: line.startIndex)..<close])
            let rest = line[line.index(after: close)...]
            guard let open = rest.firstIndex(of: "["), rest.hasSuffix("]") else { continue }
            props[key] = String(rest[rest.index(after: open)..<rest.index(before: rest.endIndex)])
        }
        guard let serial = props["ro.serialno"], looksLikeSerial(serial),
              let model = props["ro.product.model"], !model.isEmpty else {
            // It accepted a connection but produced no Android identity: a Linux
            // box with adbd, or a dead transport. Drop it and skip it for a while
            // so scans stay fast.
            reject(address)
            _ = runProcess(adb, ["disconnect", address], timeout: 2)
            return nil
        }
        clearRejection(address)
        return Discovered(serial: serial,
                          model: model,
                          device: props["ro.product.device"] ?? "",
                          release: props["ro.build.version.release"] ?? "",
                          sdk: props["ro.build.version.sdk"] ?? "",
                          address: address)
    }

    private func apply(_ found: [Discovered]) {
        var best: [String: Discovered] = [:]
        for device in found {
            if let existing = best[device.serial] {
                // Same board seen twice (stale adb entry + current lease): prefer the
                // address we already had on file, otherwise keep the first one.
                let known = registry.items[device.serial]?.lastAddress
                if existing.address != known, device.address == known { best[device.serial] = device }
            } else {
                best[device.serial] = device
            }
        }
        online = best

        for device in best.values {
            let outcome = registry.record(serial: device.serial, model: device.model,
                                          device: device.device, address: device.address)
            let name = displayName(outcome.record)
            if outcome.previousAddress == nil {
                log("发现 \(name)  \(device.address)")
            } else if let previous = outcome.previousAddress, previous != device.address {
                log("\(name) 地址变更 \(previous) → \(device.address)")
                _ = runProcess(tools.adb, ["disconnect", previous], timeout: 5)
                if mirroring.contains(device.serial) {
                    log("该设备正在镜像，IP 变了，镜像需要重新连接")
                }
            } else if !lastOnline.isEmpty && !lastOnline.contains(device.serial) {
                log("恢复在线 \(name)  \(device.address)")
            }
        }
        for serial in lastOnline where best[serial] == nil {
            if let entry = registry.items[serial] {
                log("离线 \(displayName(entry))  上次 \(entry.lastAddress)")
            }
        }
        lastOnline = Set(best.keys)
    }

    func displayName(_ entry: KnownDevice) -> String {
        if !entry.nickname.isEmpty { return entry.nickname }
        return entry.model.isEmpty ? entry.serial : entry.model
    }

    func displayName(serial: String, fallback: String) -> String {
        if let entry = registry.items[serial] { return displayName(entry) }
        return fallback
    }

    private func publish() {
        var result: [DeviceRow] = []
        var seen = Set<String>()

        for device in online.values {
            seen.insert(device.serial)
            let entry = registry.items[device.serial]
            let previous = entry?.previousAddress
            let changed = (previous != nil && previous != device.address) ? previous : nil
            result.append(DeviceRow(
                serial: device.serial,
                name: displayName(serial: device.serial, fallback: device.model),
                model: device.model,
                device: device.device,
                address: device.address,
                online: true,
                mirroring: mirroring.contains(device.serial),
                ipChangedFrom: changed
            ))
        }
        for entry in registry.items.values where !seen.contains(entry.serial) {
            result.append(DeviceRow(
                serial: entry.serial,
                name: displayName(entry),
                model: entry.model,
                device: entry.device,
                address: entry.lastAddress,
                online: false,
                mirroring: false,
                ipChangedFrom: nil
            ))
        }
        result.sort { lhs, rhs in
            if lhs.online != rhs.online { return lhs.online }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        rows = result
        onChange?()
    }

    // MARK: actions

    func startMirror(serial: String) {
        guard let device = online[serial] else {
            log("无法镜像：设备当前离线")
            return
        }
        guard !tools.scrcpy.isEmpty else {
            log("找不到 scrcpy，请先 brew install scrcpy")
            return
        }
        guard mirrorProcs[serial] == nil else { return }

        let name = displayName(serial: serial, fallback: device.model)
        let tuning = tuning(for: serial)
        var args = [
            "-s", device.address,
            "--turn-screen-off",
            "--stay-awake",
            "--no-audio",
            "--no-mouse-hover",
            "--max-fps=30",
            "--video-bit-rate=\(tuning.bitRate ?? "2M")",
            "--window-title=\(name) — \(device.address)",
        ]
        if let maxSize = tuning.maxSize {
            // This device has a reason to deviate from the global cap.
            args.append("--max-size=\(maxSize)")
        } else if !nativeResolution {
            args.append("--max-size=1024")
        }

        let isRockchip = device.device.hasPrefix("rk356") || device.device.hasPrefix("rk358")
        if isRockchip {
            // Hardware H.264 encoder on the RK356x/RK3588 boards: much cheaper than
            // software encoding at the same quality.
            args += ["--video-codec=h264", "--video-encoder=OMX.rk.video_encoder.avc"]
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tools.scrcpy)
        process.arguments = args
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.mirrorProcs[serial] = nil
                self.mirroring.remove(serial)
                self.log("镜像结束 \(name)")
                self.publish()
            }
        }
        do {
            try process.run()
        } catch {
            log("启动 scrcpy 失败：\(error.localizedDescription)")
            return
        }
        mirrorProcs[serial] = process
        mirroring.insert(serial)
        log("镜像中 \(name) \(device.address)（物理屏已关闭）")
        publish()
    }

    func stopMirror(serial: String) {
        guard let process = mirrorProcs[serial] else { return }
        log("停止镜像 \(displayName(serial: serial, fallback: serial))")
        // scrcpy 4.x ignores SIGTERM; SIGINT makes it shut down and restore the
        // panel. SIGKILL is only a last resort so the process cannot linger.
        let pid = process.processIdentifier
        kill(pid, SIGINT)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    func stopAllMirrors() {
        for serial in mirrorProcs.keys { stopMirror(serial: serial) }
    }

    /// Panel comes back when scrcpy exits; this also wakes the device if the
    /// screen was off for an unrelated reason.
    func wake(serial: String) {
        guard let device = online[serial] else { return }
        _ = runProcess(tools.adb, ["-s", device.address, "shell", "input keyevent KEYCODE_WAKEUP"], timeout: 8)
        _ = runProcess(tools.adb, ["-s", device.address, "shell", "wm dismiss-keyguard"], timeout: 8)
        log("已发送亮屏 \(displayName(serial: serial, fallback: device.model))")
    }

    func rename(serial: String, to name: String) {
        registry.setNickname(name, for: serial)
        publish()
    }

    func shellCommand(for serial: String) -> String? {
        guard let device = online[serial] else { return nil }
        let adb = tools.adb.contains(" ") ? "\"\(tools.adb)\"" : tools.adb
        return "\(adb) -s \(device.address) shell"
    }

    func address(for serial: String) -> String? {
        if let device = online[serial] { return device.address }
        return registry.items[serial]?.lastAddress
    }
}
