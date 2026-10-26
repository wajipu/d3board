import AppKit

// In-app updates from GitHub Releases.
//
// The app is not notarized, so there is no Sparkle here: we read
// /releases/latest, compare tags, download the universal zip, verify that the
// bundle we unpacked really is the version we asked for, then hand the swap to a
// detached shell script. The script waits for this process to exit, replaces the
// bundle, and reopens it — a running app cannot safely overwrite itself.

struct ReleaseInfo {
    var version: String
    var notes: String
    var pageURL: URL
    var zipURL: URL?
}

enum UpdateError: LocalizedError {
    case badResponse(String)
    case noAsset
    case download(String)
    case unpack(String)
    case mismatch(expected: String, found: String)
    case notWritable(String)
    case spawn(String)

    var errorDescription: String? {
        switch self {
        case .badResponse(let detail): return "更新服务器返回异常：\(detail)"
        case .noAsset: return "这个 release 里没有 zip 包。"
        case .download(let detail): return "下载失败：\(detail)"
        case .unpack(let detail): return "解压失败：\(detail)"
        case .mismatch(let expected, let found): return "下载到的版本是 \(found)，不是 \(expected)。"
        case .notWritable(let path): return "没有权限写入 \(path)。"
        case .spawn(let detail): return "无法启动更新助手：\(detail)"
        }
    }
}

final class Updater {
    static let shared = Updater()

    private let repo = "wajipu/d3board"
    private(set) var latest: ReleaseInfo?

    var onAvailable: ((ReleaseInfo) -> Void)?
    var onUpToDate: ((String) -> Void)?
    var onFailure: ((String) -> Void)?

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Automatic checks are quiet and rate limited; manual ones always report.
    func check(manual: Bool) {
        let defaults = UserDefaults.standard
        if !manual {
            if let last = defaults.object(forKey: "lastUpdateCheck") as? Date,
               Date().timeIntervalSince(last) < 6 * 3600 {
                return
            }
        }
        defaults.set(Date(), forKey: "lastUpdateCheck")

        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        request.setValue("D3Board/\(Updater.currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            let localVersion = Updater.currentVersion

            if let error {
                self.report(manual: manual, failure: "网络错误：\(error.localizedDescription)")
                return
            }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, let data else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                self.report(manual: manual, failure: "GitHub 返回 \(code)")
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else {
                self.report(manual: manual, failure: "看不懂的 release 数据")
                return
            }

            let remoteVersion = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let notes = (json["body"] as? String) ?? ""
            let page = URL(string: (json["html_url"] as? String) ?? "https://github.com/\(self.repo)/releases")
            var zip: URL?
            if let assets = json["assets"] as? [[String: Any]] {
                for asset in assets {
                    if let name = asset["name"] as? String, name.hasSuffix(".zip"),
                       let link = asset["browser_download_url"] as? String {
                        zip = URL(string: link)
                        break
                    }
                }
            }

            guard Updater.isNewer(remoteVersion, than: localVersion) else {
                self.latest = nil
                DispatchQueue.main.async {
                    if manual { self.onUpToDate?(localVersion) }
                }
                return
            }
            let skipped = UserDefaults.standard.string(forKey: "skippedUpdateVersion")
            if !manual && skipped == remoteVersion {
                DispatchQueue.main.async {
                    if manual { self.onUpToDate?(localVersion) }
                }
                return
            }

            let info = ReleaseInfo(version: remoteVersion, notes: notes,
                                   pageURL: page ?? URL(string: "https://github.com/\(self.repo)")!,
                                   zipURL: zip)
            self.latest = info
            DispatchQueue.main.async { self.onAvailable?(info) }
        }.resume()
    }

    private func report(manual: Bool, failure: String) {
        DispatchQueue.main.async {
            if manual { self.onFailure?(failure) } else { NSLog("update check failed: %@", failure) }
        }
    }

    func skip(version: String) {
        UserDefaults.standard.set(version, forKey: "skippedUpdateVersion")
    }

    static func isNewer(_ remote: String, than local: String) -> Bool {
        func parts(_ value: String) -> [Int] {
            value.split(separator: ".").map { component in
                Int(component.prefix(while: { $0.isNumber })) ?? 0
            }
        }
        let lhs = parts(remote), rhs = parts(local)
        for index in 0..<max(lhs.count, rhs.count) {
            let a = index < lhs.count ? lhs[index] : 0
            let b = index < rhs.count ? rhs[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    // MARK: - install

    /// Downloads, verifies and swaps the bundle, then quits this process.
    /// `target` is normally the running bundle; tests point it at a copy.
    func install(_ release: ReleaseInfo, into target: URL = Bundle.main.bundleURL,
                 progress: @escaping (String) -> Void,
                 completion: @escaping (Result<Void, Error>) -> Void) {
        guard let zipURL = release.zipURL else {
            completion(.failure(UpdateError.noAsset))
            return
        }
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("D3Board-update-\(release.version)-\(UUID().uuidString)")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

                DispatchQueue.main.async { progress("正在下载 \(release.version)…") }
                let zip = work.appendingPathComponent("update.zip")
                do {
                    try Updater.download(zipURL, to: zip)
                } catch {
                    throw UpdateError.download(error.localizedDescription)
                }

                DispatchQueue.main.async { progress("正在校验…") }
                let extract = work.appendingPathComponent("extract")
                let unzip = runProcess("/usr/bin/ditto", ["-x", "-k", zip.path, extract.path], timeout: 120)
                guard unzip.code == 0 else {
                    throw UpdateError.unpack(unzip.out.isEmpty ? "ditto exit \(unzip.code)" : unzip.out)
                }
                let newApp = extract.appendingPathComponent("D3Board.app")
                guard FileManager.default.fileExists(atPath: newApp.path) else {
                    throw UpdateError.unpack("zip 里没有 D3Board.app")
                }
                let plist = newApp.appendingPathComponent("Contents/Info.plist")
                let unpacked = NSDictionary(contentsOf: plist)?["CFBundleShortVersionString"] as? String ?? "?"
                guard unpacked == release.version else {
                    throw UpdateError.mismatch(expected: release.version, found: unpacked)
                }

                DispatchQueue.main.async { progress("正在替换，马上重启…") }
                try Updater.scheduleSwap(newApp: newApp, target: target, workDirectory: work)
                DispatchQueue.main.async { completion(.success(())) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    private static func download(_ url: URL, to destination: URL) throws {
        // Synchronous wrapper: URLSession's async APIs would need concurrency,
        // and this runs on a background queue anyway.
        var result: Result<Void, Error>?
        let semaphore = DispatchSemaphore(value: 0)
        let task = URLSession.shared.downloadTask(with: url) { temporary, response, error in
            defer { semaphore.signal() }
            if let error {
                result = .failure(error)
                return
            }
            guard let temporary else {
                result = .failure(UpdateError.download("空响应"))
                return
            }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                result = .failure(UpdateError.download("HTTP \(http.statusCode)"))
                return
            }
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: temporary, to: destination)
                result = .success(())
            } catch {
                result = .failure(error)
            }
        }
        task.resume()
        if semaphore.wait(timeout: .now() + 600) == .timedOut {
            task.cancel()
            throw UpdateError.download("超时")
        }
        if let result { try result.get() }
    }

    /// Writes a script that swaps the bundle after this process is gone.
    private static func scheduleSwap(newApp: URL, target: URL, workDirectory: URL) throws {
        let app = target
        let parent = app.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw UpdateError.notWritable(parent.path)
        }

        let scriptURL = workDirectory.appendingPathComponent("swap.sh")
        let ownerPID = ProcessInfo.processInfo.processIdentifier
        let script = """
        #!/bin/sh
        # Written by D3Board's updater. Waits for the app to exit, then swaps in
        # the new bundle and reopens it. Waits on the pid, not on a pgrep pattern:
        # how the app was launched (absolute path, relative path, Finder) must not
        # matter. If the process never exits we leave the old bundle alone — a
        # swap underneath a live process would leave it running from a bundle
        # whose files were just replaced.
        APP="\(app.path)"
        NEW="\(newApp.path)"
        OWNER=\(ownerPID)
        i=0
        while [ "$i" -lt 300 ]; do
          /bin/kill -0 "$OWNER" 2>/dev/null || break
          /bin/sleep 0.2
          i=$((i + 1))
        done
        if /bin/kill -0 "$OWNER" 2>/dev/null; then
          exit 0
        fi
        /bin/rm -rf "$APP.old"
        if ! /bin/mv "$APP" "$APP.old"; then
          /usr/bin/open "$APP"
          exit 1
        fi
        if ! /usr/bin/ditto "$NEW" "$APP"; then
          /bin/rm -rf "$APP"
          /bin/mv "$APP.old" "$APP"
          /usr/bin/open "$APP"
          exit 1
        fi
        /usr/bin/xattr -dr com.apple.quarantine "$APP" 2>/dev/null
        /usr/bin/open "$APP"
        /bin/rm -rf "$APP.old"
        """
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        } catch {
            throw UpdateError.spawn(error.localizedDescription)
        }

        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [scriptURL.path]
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        do {
            try helper.run()
        } catch {
            throw UpdateError.spawn(error.localizedDescription)
        }
    }
}
