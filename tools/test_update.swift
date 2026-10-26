import Foundation

// Headless test of the update pipeline, against the real GitHub release:
//   mkdir -p /tmp/d3ut && cp tools/test_update.swift /tmp/d3ut/main.swift
//   swiftc -O -swift-version 5 Sources/Engine.swift Sources/Updater.swift /tmp/d3ut/main.swift -o /tmp/d3ut/test
//   /tmp/d3ut/test
//
// Two processes on purpose. The swap helper waits for the process that asked for
// the update to exit before it touches the bundle, so the parent spawns a child
// to run the install and then checks the disk itself. Nothing here touches
// /Applications: the target is a throwaway copy of dist/D3Board.app.
// Needs network access to api.github.com.

func pump(_ seconds: Double) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

var failures: [String] = []
func check(_ condition: Bool, _ label: String) {
    print("\(condition ? "PASS" : "FAIL")  \(label)")
    if !condition { failures.append(label) }
}

// MARK: - child: run one install, then exit so the helper can swap

if CommandLine.arguments.count >= 5, CommandLine.arguments[1] == "--child-install" {
    let version = CommandLine.arguments[2]
    let zip = URL(string: CommandLine.arguments[3])!
    let target = URL(fileURLWithPath: CommandLine.arguments[4])
    let release = ReleaseInfo(version: version, notes: "", pageURL: zip, zipURL: zip)
    var result: Result<Void, Error>?
    Updater.shared.install(release, into: target, progress: { print("  · \($0)") }) { result = $0 }
    let deadline = Date().addingTimeInterval(600)
    while result == nil && Date() < deadline {
        pump(0.2)
    }
    if case .failure(let error)? = result {
        print("FAIL  install: \(error.localizedDescription)")
        exit(1)
    }
    exit(result == nil ? 1 : 0)
}

// MARK: - version comparison

check(Updater.isNewer("1.2.0", than: "1.1.0"), "1.2.0 > 1.1.0")
check(Updater.isNewer("1.1.10", than: "1.1.9"), "numeric compare, not lexical")
check(Updater.isNewer("1.2", than: "1.1.9"), "short remote version")
check(Updater.isNewer("1.1.1", than: "1.1"), "short local version")
check(!Updater.isNewer("1.1.0", than: "1.1.0"), "same version is not newer")
check(!Updater.isNewer("1.0.9", than: "1.1.0"), "older is not newer")
check(!Updater.isNewer("2.0.0", than: "10.9.9"), "compares numerically per component")

// MARK: - release lookup

let api = URL(string: "https://api.github.com/repos/wajipu/d3board/releases/latest")!
var request = URLRequest(url: api)
request.setValue("D3Board-test", forHTTPHeaderField: "User-Agent")
request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
request.timeoutInterval = 30

var payload: Data?
var status = -1
let semaphore = DispatchSemaphore(value: 0)
URLSession.shared.dataTask(with: request) { data, response, error in
    if let error { print("FAIL  release lookup: \(error.localizedDescription)") }
    payload = data
    status = (response as? HTTPURLResponse)?.statusCode ?? -1
    semaphore.signal()
}.resume()
_ = semaphore.wait(timeout: .now() + 40)
check(status == 200, "GET /releases/latest → 200 (got \(status))")

guard let data = payload,
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let tag = json["tag_name"] as? String else {
    print("FAIL  could not parse release json")
    exit(1)
}
let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
print("release  \(tag)")

var zipURL: URL?
if let assets = json["assets"] as? [[String: Any]] {
    for asset in assets where (asset["name"] as? String)?.hasSuffix(".zip") == true {
        if let link = asset["browser_download_url"] as? String { zipURL = URL(string: link) }
        break
    }
}
check(zipURL != nil, "release ships a .zip asset")
guard let zipURL else { exit(1) }

// MARK: - install into a throwaway bundle

let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("d3board-update-test", isDirectory: true)
try? FileManager.default.removeItem(at: sandbox)
try! FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)

let source = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("dist/D3Board.app")
guard FileManager.default.fileExists(atPath: source.path) else {
    print("FAIL  build a dist bundle first (ARCHS=arm64 ./build.sh)")
    exit(1)
}
let target = sandbox.appendingPathComponent("D3Board.app")
check(runProcess("/usr/bin/ditto", [source.path, target.path], timeout: 120).code == 0,
      "copied a scratch bundle")

func versionOnDisk() -> String? {
    guard let plist = NSDictionary(contentsOf: target.appendingPathComponent("Contents/Info.plist")) else {
        return nil
    }
    return plist["CFBundleShortVersionString"] as? String
}
let before = versionOnDisk() ?? "?"
print("scratch  \(before)")
check(before != version, "scratch bundle differs from the release, so the swap is observable")

let child = Process()
child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
child.arguments = ["--child-install", version, zipURL.absoluteString, target.path]
child.standardOutput = FileHandle.standardOutput
child.standardError = FileHandle.standardError
try! child.run()
child.waitUntilExit()
check(child.terminationStatus == 0, "child install exited 0")

var swapped = false
for _ in 0..<80 {
    if versionOnDisk() == version { swapped = true; break }
    pump(0.25)
}
check(swapped, "bundle on disk is now \(version) (was \(before))")
check(versionOnDisk() == version, "Info.plist version matches the release")

pump(1.5)
let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: sandbox.path)) ?? []
check(!leftovers.contains("D3Board.app.old"), "no .old bundle left behind")

// The helper reopens the bundle it just swapped; close that test instance.
_ = runProcess("/usr/bin/pkill", ["-f", target.path], timeout: 10)
try? FileManager.default.removeItem(at: sandbox)

print(failures.isEmpty ? "UPDATE TEST PASS" : "UPDATE TEST FAIL (\(failures.count))")
exit(failures.isEmpty ? 0 : 1)
