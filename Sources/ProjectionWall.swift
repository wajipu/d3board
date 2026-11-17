import AppKit

// scrcpy sends video to a private FIFO, so the wall neither opens another
// window nor writes a recording. FFmpeg decodes one small preview per board.
private final class ProjectionStream {
    private let capture = Process()
    private let decode = Process()
    private var directory: URL?
    private var running = false

    func start(row: DeviceRow, tools: Tools, frame: @escaping (CGImage) -> Void,
               ended: @escaping () -> Void, log: @escaping (String) -> Void) throws {
        let width = 480, height = 270
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        directory = dir
        do {
            let pipeURL = dir.appendingPathComponent("video.mkv")
            guard mkfifo(pipeURL.path, 0o600) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }

            capture.executableURL = URL(fileURLWithPath: tools.scrcpy)
            capture.arguments = [
                "-s", row.address, "--no-window", "--no-audio", "--no-control",
                "--max-size=1024", "--max-fps=8", "--video-bit-rate=800K",
                "--video-codec=h264", "--video-codec-options=i-frame-interval:int=1",
                "--verbosity=warn", "--record-format=mkv", "--record=\(pipeURL.path)",
            ]
            if row.device.hasPrefix("rk356") || row.device.hasPrefix("rk358") {
                capture.arguments?.append("--video-encoder=OMX.rk.video_encoder.avc")
            }
            var env = ProcessInfo.processInfo.environment
            env["ADB"] = tools.adb
            capture.environment = env
            capture.standardInput = FileHandle.nullDevice
            capture.standardOutput = FileHandle.nullDevice

            let pictures = Pipe()
            decode.executableURL = URL(fileURLWithPath: tools.ffmpeg)
            decode.arguments = [
                "-nostdin", "-hide_banner", "-loglevel", "error", "-threads", "1",
                "-f", "matroska", "-probesize", "2048", "-analyzeduration", "1", "-fpsprobesize", "0",
                "-i", pipeURL.path, "-an", "-filter_threads", "1",
                "-vf", "scale=\(width):\(height):force_original_aspect_ratio=decrease,"
                    + "pad=\(width):\(height):(ow-iw)/2:(oh-ih)/2,setsar=1,settb=1/8,setpts=N",
                "-c:v", "rawvideo", "-threads", "1", "-fps_mode", "passthrough",
                "-enc_time_base", "1:8",
                "-pix_fmt", "bgra", "-f", "rawvideo", "pipe:1",
            ]
            decode.standardInput = FileHandle.nullDevice
            decode.standardOutput = pictures

            running = true
            for process in [capture, decode] {
                let errors = Pipe()
                process.standardError = errors
                process.terminationHandler = { [weak self] _ in
                    DispatchQueue.main.async {
                        guard let self, self.running else { return }
                        self.stop()
                        ended()
                    }
                }
                try process.run()
                errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    let bytes = handle.availableData
                    if bytes.isEmpty {
                        handle.readabilityHandler = nil
                        return
                    }
                    let message = String(decoding: bytes, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !message.isEmpty {
                        DispatchQueue.main.async {
                            if self?.running == true { log("投屏墙 \(row.address)：\(message)") }
                        }
                    }
                }
            }

            let handle = pictures.fileHandleForReading
            let size = width * height * 4
            let pendingDisplay = DispatchSemaphore(value: 1)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                var bytes = Data()
                while let chunk = try? handle.read(upToCount: size - bytes.count), !chunk.isEmpty {
                    bytes.append(chunk)
                    guard bytes.count == size else { continue }
                    let pixels = bytes
                    bytes = Data()
                    // Drop frames if the UI is busy instead of queuing stale video.
                    guard pendingDisplay.wait(timeout: .now()) == .success else { continue }
                    let image = CGDataProvider(data: pixels as CFData).flatMap { provider in
                        CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: [.byteOrder32Little,
                                             CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)],
                                provider: provider, decode: nil, shouldInterpolate: true,
                                intent: .defaultIntent)
                    }
                    DispatchQueue.main.async {
                        defer { pendingDisplay.signal() }
                        if let image, self?.running == true { frame(image) }
                    }
                }
            }
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        running = false
        for process in [capture, decode] where process.isRunning {
            let pid = process.processIdentifier
            kill(pid, SIGINT)
            // Covers an early exit while one side is still opening the FIFO.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
        if let directory {
            try? FileManager.default.removeItem(at: directory)
            self.directory = nil
        }
    }
}

private final class ProjectionTile: NSView {
    private let name = NSTextField(labelWithString: "")
    private let address = NSTextField(labelWithString: "")
    private let picture = NSImageView()
    private let state = NSTextField(labelWithString: "")
    private let retry = NSButton(title: "重试", target: nil, action: nil)
    private let engine: Engine
    private var row: DeviceRow?
    private var stream: ProjectionStream?

    init(engine: Engine) {
        self.engine = engine
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail
        address.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        address.textColor = .secondaryLabelColor
        state.textColor = .secondaryLabelColor
        state.font = .systemFont(ofSize: 11)
        state.lineBreakMode = .byTruncatingTail
        picture.imageScaling = .scaleProportionallyUpOrDown
        picture.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        picture.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        picture.wantsLayer = true
        picture.layer?.backgroundColor = NSColor.black.cgColor
        retry.target = self
        retry.action = #selector(restart)
        retry.controlSize = .small
        let footer = NSStackView(views: [state, NSView(), retry])
        let body = NSStackView(views: [name, address, picture, footer])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 5
        body.translatesAutoresizingMaskIntoConstraints = false
        addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            body.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            body.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            body.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
            name.widthAnchor.constraint(lessThanOrEqualTo: body.widthAnchor),
            picture.widthAnchor.constraint(equalTo: body.widthAnchor),
            picture.heightAnchor.constraint(equalTo: picture.widthAnchor, multiplier: 9.0 / 16.0),
            footer.widthAnchor.constraint(equalTo: body.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ next: DeviceRow) {
        let reconnect = row?.address != next.address || row?.online != next.online
            || row?.mirroring != next.mirroring
        row = next
        name.stringValue = next.name
        name.toolTip = next.serial
        address.stringValue = next.address
        picture.setAccessibilityLabel("\(next.name) \(next.address) 预览")
        if reconnect { restart() }
    }

    func stop() {
        stream?.stop()
        stream = nil
        picture.image = nil
    }

    @objc private func restart() {
        stop()
        retry.isEnabled = false
        guard let row, row.online else { state.stringValue = "离线"; return }
        guard !row.mirroring else { state.stringValue = "单台镜像中"; return }
        let tools = engine.tools
        guard !tools.scrcpy.isEmpty, !tools.ffmpeg.isEmpty else {
            state.stringValue = "需要 scrcpy 和 FFmpeg"
            return
        }
        let preview = ProjectionStream()
        stream = preview
        state.stringValue = "连接中…"
        do {
            try preview.start(row: row, tools: tools, frame: { [weak self] frame in
                guard let self else { return }
                if self.picture.image == nil { self.state.stringValue = "预览中" }
                self.picture.image = NSImage(cgImage: frame, size: .zero)
            }, ended: { [weak self] in
                self?.failed("预览已断开")
            }, log: engine.log)
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self, weak preview] in
                guard let self, let preview, self.stream === preview, self.picture.image == nil else { return }
                self.failed("等待画面超时")
            }
        } catch {
            engine.log("投屏墙 \(row.address)：\(error.localizedDescription)")
            failed("预览启动失败")
        }
    }

    private func failed(_ message: String) {
        stop()
        state.stringValue = message
        retry.isEnabled = true
    }
}

final class ProjectionWall: NSView {
    private final class Document: NSView {
        override var isFlipped: Bool { true }
    }

    private let tiles: [String: ProjectionTile]

    init(devices: [DeviceRow], engine: Engine, target: AnyObject, back: Selector) {
        tiles = Dictionary(uniqueKeysWithValues: devices.map { ($0.serial, ProjectionTile(engine: engine)) })
        super.init(frame: .zero)
        let backButton = NSButton(title: "返回设备列表", target: target, action: back)
        let title = NSTextField(labelWithString: "投屏墙 · \(devices.count) 台")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let hint = NSTextField(labelWithString: "只读预览 · 设备屏幕状态不变")
        hint.textColor = .secondaryLabelColor
        let header = NSStackView(views: [backButton, title, NSView(), hint])
        header.spacing = 10
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        let grid = NSStackView()
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 12
        grid.translatesAutoresizingMaskIntoConstraints = false
        let document = Document()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(grid)
        scroll.documentView = document
        if devices.isEmpty {
            grid.addArrangedSubview(NSTextField(labelWithString: "没有在线设备。返回列表扫描或添加设备后再试。"))
        } else {
            let columns = min(3, devices.count)
            let gap: CGFloat = 12
            for start in stride(from: 0, to: devices.count, by: columns) {
                let end = min(start + columns, devices.count)
                let line = NSView()
                line.translatesAutoresizingMaskIntoConstraints = false
                grid.addArrangedSubview(line)
                line.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
                var previous: NSView?
                for tile in devices[start..<end].compactMap({ tiles[$0.serial] }) {
                    tile.translatesAutoresizingMaskIntoConstraints = false
                    line.addSubview(tile)
                    NSLayoutConstraint.activate([
                        tile.leadingAnchor.constraint(equalTo: previous?.trailingAnchor ?? line.leadingAnchor,
                                                      constant: previous == nil ? 0 : gap),
                        tile.topAnchor.constraint(equalTo: line.topAnchor),
                        tile.bottomAnchor.constraint(equalTo: line.bottomAnchor),
                        tile.widthAnchor.constraint(equalTo: line.widthAnchor, multiplier: 1 / CGFloat(columns),
                                                    constant: -gap * CGFloat(columns - 1) / CGFloat(columns)),
                    ])
                    previous = tile
                }
            }
        }

        for view in [header, scroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            grid.topAnchor.constraint(equalTo: document.topAnchor, constant: 5),
            grid.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 12),
            grid.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -12),
            grid.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -12),
        ])
        update(devices)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ devices: [DeviceRow]) {
        for device in devices { tiles[device.serial]?.update(device) }
    }

    func stop() { tiles.values.forEach { $0.stop() } }
}
