import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private var window: NSWindow!
    private let table = NSTableView()
    private let logView = NSTextView()
    private let spinner = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "准备中…")
    private let nativeCheck = NSButton(checkboxWithTitle: "原生分辨率", target: nil, action: nil)
    private let engine = Engine.shared
    private let updater = Updater.shared
    private var rows: [DeviceRow] = []
    private var progressSheet: NSWindow?
    private var presentingUpdate = false
    private let progressLabel = NSTextField(labelWithString: "")
    private let progressSpinner = NSProgressIndicator()

    // MARK: - App lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()
        wireEngine()
        wireUpdater()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        engine.bootstrap()

        // A quiet check shortly after launch, then every few hours. Manual
        // checks from the menu always report, even when nothing is new.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.updater.check(manual: false)
        }
        let timer = Timer(timeInterval: 4 * 3600, repeats: true) { [weak self] _ in
            self?.updater.check(manual: false)
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        // scrcpy restores the physical panel when it exits.
        engine.stopAllMirrors()
        Thread.sleep(forTimeInterval: 0.6)
    }

    private func wireEngine() {
        engine.onChange = { [weak self] in self?.refresh() }
        engine.onLog = { [weak self] line in self?.appendLog(line) }
        engine.onScanState = { [weak self] scanning in self?.setScanning(scanning) }
    }

    private func wireUpdater() {
        updater.onAvailable = { [weak self] info in self?.presentUpdate(info) }
        updater.onUpToDate = { [weak self] version in
            guard let self else { return }
            let alert = NSAlert()
            alert.messageText = "已是最新版本"
            alert.informativeText = "当前 \(version)，GitHub 上没有更新的 release。"
            alert.addButton(withTitle: "好")
            alert.beginSheetModal(for: self.window, completionHandler: nil)
        }
        updater.onFailure = { [weak self] message in
            guard let self else { return }
            let alert = NSAlert()
            alert.messageText = "检查更新失败"
            alert.informativeText = message
            alert.addButton(withTitle: "好")
            alert.beginSheetModal(for: self.window, completionHandler: nil)
        }
    }

    private func presentUpdate(_ info: ReleaseInfo) {
        // The 4h timer and a manual check can land together; one sheet at a time.
        guard !presentingUpdate else { return }
        presentingUpdate = true
        appendLog("发现新版本 \(info.version)（当前 \(Updater.currentVersion)）")
        let alert = NSAlert()
        alert.messageText = "有新版本 \(info.version)"
        var detail = "当前版本 \(Updater.currentVersion)。"
        let notes = info.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            detail += "\n\n" + String(notes.prefix(900))
        }
        alert.informativeText = detail
        // "稍后" is the default button on purpose: an update restarts the app and
        // interrupts whatever the boards are doing, so a stray Return or a click
        // that was meant for the window behind should not start it. macOS does the
        // same in Software Update.
        alert.addButton(withTitle: "稍后")
        alert.addButton(withTitle: "下载并安装")
        alert.addButton(withTitle: "跳过此版本")
        Updater.trace("alert shown for \(info.version) parentVisible=\(window.isVisible) key=\(window.isKeyWindow) active=\(NSApp.isActive)")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            Updater.trace("alert response=\(response.rawValue)")
            self.presentingUpdate = false
            switch response {
            case .alertSecondButtonReturn:
                self.installUpdate(info)
            case .alertThirdButtonReturn:
                self.updater.skip(version: info.version)
                self.appendLog("已跳过 \(info.version)")
            default:
                self.appendLog("稍后再说，保留 \(info.version) 提示")
            }
        }
    }

    @objc private func checkForUpdates() {
        updater.check(manual: true)
    }

    private func installUpdate(_ info: ReleaseInfo) {
        guard info.zipURL != nil else {
            let alert = NSAlert()
            alert.messageText = "无法自动安装"
            alert.informativeText = "这个 release 没有 zip 资产，请到发布页手动下载。"
            alert.addButton(withTitle: "打开发布页")
            alert.addButton(withTitle: "取消")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(info.pageURL)
            }
            return
        }

        showProgress("正在准备…")
        updater.install(info, progress: { [weak self] text in
            self?.showProgress(text)
        }, completion: { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.progressLabel.stringValue = "更新完成，正在重启…"
                self.appendLog("已安装 \(info.version)，重启")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    // NSApplication.terminate is a no-op while a sheet is up: it
                    // returns happily and the app keeps running, which leaves the
                    // user staring at "正在重启" and the swap helper waiting for a
                    // process that never exits. End the sheet first.
                    self.hideProgress()
                    NSApp.terminate(nil)
                    Updater.trace("terminate returned, still running")
                    // Belt and braces: if the quit is deferred anyway, stop the
                    // mirrors ourselves and exit — the helper can only swap once
                    // this pid is gone.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        Engine.shared.stopAllMirrors()
                        exit(0)
                    }
                }
            case .failure(let error):
                self.hideProgress()
                self.appendLog("更新失败：\(error.localizedDescription)")
                let alert = NSAlert()
                alert.messageText = "更新失败"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "打开发布页")
                alert.addButton(withTitle: "好")
                alert.beginSheetModal(for: self.window) { response in
                    if response == .alertFirstButtonReturn {
                        NSWorkspace.shared.open(info.pageURL)
                    }
                }
            }
        })
    }

    private func showProgress(_ text: String) {
        if progressSheet == nil {
            let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 96),
                                 styleMask: [.titled], backing: .buffered, defer: false)
            sheet.title = "更新 D3Board"

            progressLabel.stringValue = text
            progressLabel.font = NSFont.systemFont(ofSize: 12)
            progressLabel.lineBreakMode = .byTruncatingTail
            progressLabel.translatesAutoresizingMaskIntoConstraints = false

            let spinner = progressSpinner
            spinner.style = .spinning
            spinner.isIndeterminate = true
            spinner.controlSize = .small
            spinner.startAnimation(nil)
            spinner.translatesAutoresizingMaskIntoConstraints = false

            let content = NSView()
            content.addSubview(progressLabel)
            content.addSubview(spinner)
            NSLayoutConstraint.activate([
                spinner.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
                spinner.centerYAnchor.constraint(equalTo: content.centerYAnchor),
                progressLabel.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 10),
                progressLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
                progressLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            ])
            sheet.contentView = content
            window.beginSheet(sheet, completionHandler: nil)
            progressSheet = sheet
        }
        progressLabel.stringValue = text
    }

    private func hideProgress() {
        guard let sheet = progressSheet else { return }
        progressSpinner.stopAnimation(nil)
        window.endSheet(sheet)
        progressSheet = nil
    }

    // MARK: - UI

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 D3Board", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        let checkItem = NSMenuItem(title: "检查更新…", action: #selector(checkForUpdates), keyEquivalent: "u")
        checkItem.target = self
        appMenu.addItem(checkItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 D3Board", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 D3Board", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        let deviceItem = NSMenuItem()
        main.addItem(deviceItem)
        let deviceMenu = NSMenu(title: "设备")
        let scan = NSMenuItem(title: "扫描", action: #selector(rescanAction), keyEquivalent: "r")
        scan.target = self
        deviceMenu.addItem(scan)
        let deep = NSMenuItem(title: "全网段深度扫描", action: #selector(deepScanAction), keyEquivalent: "R")
        deep.target = self
        deviceMenu.addItem(deep)
        deviceMenu.addItem(.separator())
        let mirror = NSMenuItem(title: "镜像（黑屏）", action: #selector(mirrorAction), keyEquivalent: "m")
        mirror.target = self
        deviceMenu.addItem(mirror)
        let stop = NSMenuItem(title: "停止镜像", action: #selector(stopAction), keyEquivalent: ".")
        stop.target = self
        deviceMenu.addItem(stop)
        deviceItem.submenu = deviceMenu

        NSApp.mainMenu = main
    }

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1020, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "D3Board — 局域网设备"
        window.minSize = NSSize(width: 860, height: 520)
        window.center()
        window.setFrameAutosaveName("D3BoardMain")
        // The autosaved frame is restored from the last run, and it can point at a
        // display that is no longer attached (or at coordinates from a bigger
        // screen), which makes the window open effectively invisible. If no screen
        // would show a real piece of it, start centered instead.
        if !NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: 60, dy: 60).intersects(window.frame) }) {
            window.setFrame(NSRect(x: 0, y: 0, width: 1020, height: 660), display: false)
            window.center()
        }

        let content = NSView()
        window.contentView = content

        // --- top bar
        let scanButton = makeButton("扫描", #selector(rescanAction))
        let deepButton = makeButton("深度扫描", #selector(deepScanAction))
        nativeCheck.target = self
        nativeCheck.action = #selector(toggleNative)
        nativeCheck.state = engine.nativeResolution ? .on : .off
        nativeCheck.toolTip = "镜像时使用设备原始分辨率（更清晰，也更吃带宽）"

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.widthAnchor.constraint(equalToConstant: 16).isActive = true
        spinner.heightAnchor.constraint(equalToConstant: 16).isActive = true

        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let topBar = NSStackView(views: [scanButton, deepButton, spinner, statusLabel, nativeCheck])
        topBar.orientation = .horizontal
        topBar.spacing = 10
        topBar.alignment = .centerY
        topBar.translatesAutoresizingMaskIntoConstraints = false
        topBar.setCustomSpacing(4, after: deepButton)
        content.addSubview(topBar)

        // --- table
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = true
        content.addSubview(scroll)

        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 26
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.target = self
        table.doubleAction = #selector(mirrorAction)
        table.style = .fullWidth
        table.dataSource = self
        table.delegate = self

        let columns: [(String, String, CGFloat)] = [
            ("name", "设备", 190),
            ("model", "型号", 130),
            ("address", "地址", 165),
            ("status", "状态", 210),
            ("mirror", "镜像", 70),
        ]
        for (id, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = 60
            table.addTableColumn(column)
        }
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        scroll.documentView = table

        // --- action bar
        let mirrorButton = makeButton("镜像（黑屏）", #selector(mirrorAction))
        let mirrorAllButton = makeButton("全部镜像", #selector(mirrorAllAction))
        let stopButton = makeButton("停止镜像", #selector(stopAction))
        let wakeButton = makeButton("亮屏", #selector(wakeAction))
        let terminalButton = makeButton("adb 终端", #selector(terminalAction))
        let copyButton = makeButton("复制 IP", #selector(copyAction))
        let renameButton = makeButton("重命名", #selector(renameAction))
        let addButton = makeButton("添加设备…", #selector(addDeviceAction))

        let actionBar = NSStackView(views: [mirrorButton, mirrorAllButton, stopButton, wakeButton,
                                            terminalButton, copyButton, renameButton, addButton])
        actionBar.orientation = .horizontal
        actionBar.spacing = 8
        actionBar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(actionBar)

        // --- log
        let logScroll = NSScrollView()
        logScroll.translatesAutoresizingMaskIntoConstraints = false
        logScroll.hasVerticalScroller = true
        logScroll.borderType = .bezelBorder
        logScroll.drawsBackground = true
        content.addSubview(logScroll)

        logView.isEditable = false
        logView.isSelectable = true
        logView.drawsBackground = true
        logView.backgroundColor = .textBackgroundColor
        logView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.textContainerInset = NSSize(width: 6, height: 6)
        logView.autoresizingMask = [.width]
        logView.isVerticallyResizable = true
        logView.textContainer?.widthTracksTextView = true
        logScroll.documentView = logView

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            topBar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            topBar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),

            scroll.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),

            actionBar.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            actionBar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            actionBar.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -12),

            logScroll.topAnchor.constraint(equalTo: actionBar.bottomAnchor, constant: 8),
            logScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            logScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            logScroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            logScroll.heightAnchor.constraint(equalToConstant: 150),
        ])
    }

    private func makeButton(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        return button
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn, row < rows.count else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("cell-" + column.identifier.rawValue)
        var cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView
        if cell == nil {
            let view = NSTableCellView()
            view.identifier = identifier
            let label = NSTextField(labelWithString: "")
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = NSFont.systemFont(ofSize: 12)
            view.addSubview(label)
            view.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
                label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6),
                label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            ])
            cell = view
        }

        let device = rows[row]
        let label = cell?.textField
        label?.textColor = .labelColor
        label?.font = NSFont.systemFont(ofSize: 12)

        switch column.identifier.rawValue {
        case "name":
            label?.stringValue = device.name
            if !device.online { label?.textColor = .tertiaryLabelColor }
        case "model":
            label?.stringValue = device.model
            label?.textColor = device.online ? .secondaryLabelColor : .tertiaryLabelColor
        case "address":
            label?.stringValue = device.address
            label?.font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
            label?.textColor = device.online ? .labelColor : .tertiaryLabelColor
        case "status":
            if !device.online {
                label?.stringValue = "离线"
                label?.textColor = .tertiaryLabelColor
            } else if let old = device.ipChangedFrom {
                label?.stringValue = "在线 · IP 曾 \(old.replacingOccurrences(of: ":5555", with: ""))"
                label?.textColor = .systemOrange
            } else {
                label?.stringValue = "在线 · \(device.device)"
                label?.textColor = .secondaryLabelColor
            }
        case "mirror":
            if device.mirroring {
                label?.stringValue = "● 镜像中"
                label?.textColor = .systemGreen
            } else {
                label?.stringValue = "—"
                label?.textColor = .tertiaryLabelColor
            }
        default:
            label?.stringValue = ""
        }
        return cell
    }

    private func refresh() {
        rows = engine.rows
        let selected = table.selectedRowIndexes
        table.reloadData()
        table.selectRowIndexes(selected, byExtendingSelection: false)

        let online = rows.filter { $0.online }.count
        let mirrors = rows.filter { $0.mirroring }.count
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let stamp = engine.lastScanAt.map { formatter.string(from: $0) } ?? "—"
        statusLabel.stringValue = "在线 \(online) / 已知 \(rows.count) · 镜像 \(mirrors) · 上次扫描 \(stamp)"
    }

    private func setScanning(_ scanning: Bool) {
        if scanning {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
    }

    private func appendLog(_ line: String) {
        let text = logView.string.isEmpty ? line : logView.string + "\n" + line
        logView.string = text
        logView.scrollToEndOfDocument(nil)
    }

    // MARK: - Selection helpers

    private var selectedRows: [DeviceRow] {
        let indexes = table.selectedRowIndexes
        return indexes.compactMap { $0 < rows.count ? rows[$0] : nil }
    }

    // MARK: - Actions

    @objc private func rescanAction() {
        engine.rescan(deep: false, reason: "手动")
    }

    @objc private func deepScanAction() {
        engine.rescan(deep: true, reason: "手动全网段")
    }

    @objc private func toggleNative() {
        engine.nativeResolution = nativeCheck.state == .on
    }

    @objc private func mirrorAction() {
        let targets = selectedRows
        if targets.isEmpty {
            appendLog("先选中一行（或双击某一行）")
            return
        }
        for device in targets where device.online {
            engine.startMirror(serial: device.serial)
        }
    }

    @objc private func mirrorAllAction() {
        for device in rows where device.online && !device.mirroring {
            engine.startMirror(serial: device.serial)
        }
    }

    @objc private func stopAction() {
        let targets = selectedRows.filter { $0.mirroring }
        if targets.isEmpty {
            engine.stopAllMirrors()
        } else {
            for device in targets { engine.stopMirror(serial: device.serial) }
        }
    }

    @objc private func wakeAction() {
        for device in selectedRows where device.online {
            engine.wake(serial: device.serial)
        }
    }

    @objc private func copyAction() {
        guard let first = selectedRows.first, let address = engine.address(for: first.serial) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(address, forType: .string)
        appendLog("已复制 \(address)")
    }

    @objc private func renameAction() {
        guard let device = selectedRows.first else { return }
        let alert = NSAlert()
        alert.messageText = "给设备起个名字"
        alert.informativeText = "只是显示用，方便在列表里认出来（例如“客厅板子”）。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = device.name
        field.placeholderString = device.model
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            engine.rename(serial: device.serial, to: field.stringValue.trimmingCharacters(in: .whitespaces))
        }
    }

    @objc private func addDeviceAction() {
        // Manual escape hatch: a board that changed IP while powered off (or
        // that lives outside the subnet) is invisible to every scan; here the
        // user types its address once and it is registered by serial, so all
        // later address changes are picked up automatically again.
        let alert = NSAlert()
        alert.messageText = "添加设备"
        alert.informativeText = "输入板子的 IP（或 ip:端口），例如 192.168.40.157。\n会先验证它真是 adb 设备，按序列号记入列表。"
        alert.addButton(withTitle: "连接")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "192.168.40.157"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let raw = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return }

        appendLog("正在连接 \(raw)…")
        // Probe off the main thread: a wrong address costs a few seconds of
        // connect timeout, and the alert has already closed.
        let engine = self.engine
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let note = engine.addDevice(address: raw)
            DispatchQueue.main.async {
                self?.appendLog(note)
            }
        }
    }

    @objc private func terminalAction() {
        guard let device = selectedRows.first, let command = engine.shellCommand(for: device.serial) else { return }
        let path = NSTemporaryDirectory() + "d3board-shell-\(device.serial).command"
        let script = "#!/bin/zsh\nclear\necho \"\(device.name) — \(device.address)\"\n\(command)\n"
        do {
            try script.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        } catch {
            appendLog("打开终端失败：\(error.localizedDescription)")
        }
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
