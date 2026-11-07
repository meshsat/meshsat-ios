// Mirrors interop/PyEnv.kt: the pinned upstream Python environment the interop and oracle tests run
// RNS and LXMF from (the Bridge's internal/interop/rnsenv).
//
// Resolution: $MESHSAT_RNS_VENV/bin/python3, else $XDG_CACHE_HOME (or ~/.cache)/meshsat/rns-venv-<RNS
// version>/bin/python3. Missing venv: the test is skipped unless MESHSAT_INTEROP=1, which creates it
// with python3 -m venv and pip. A venv whose versions differ from the pin fails loudly.
// MESHSAT_RNS_VERSION / MESHSAT_LXMF_VERSION override the pin for a run against another release.
// On the runner: scripts/interop-docker.sh (swift:6.2-noble plus python3, the venv on a host mount).
import Foundation
import XCTest

enum PyEnv {
    /// What CrossTalk 2.6.0 ships.
    static let rnsPin = "1.5.5"
    static let lxmfPin = "1.2.0"

    static var rnsVersion: String { env("MESHSAT_RNS_VERSION") ?? rnsPin }
    static var lxmfVersion: String { env("MESHSAT_LXMF_VERSION") ?? lxmfPin }
    static var interop: Bool { env("MESHSAT_INTEROP") == "1" }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var resolved: String?
    nonisolated(unsafe) private static var failure: String?

    static func env(_ name: String) -> String? {
        guard let v = ProcessInfo.processInfo.environment[name], !v.isEmpty else { return nil }
        return v
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// The venv interpreter; throws XCTSkip when it is not there and must not be made.
    static func python() throws -> String {
        lock.lock()
        defer { lock.unlock() }
        if let r = resolved { return r }
        if let f = failure { throw Failure(description: f) }
        let dir = venvDir()
        let py = dir.appendingPathComponent("bin/python3").path
        if !FileManager.default.isExecutableFile(atPath: py) {
            guard interop else {
                throw XCTSkip("Python RNS \(rnsVersion) venv not present at \(dir.path) (set MESHSAT_INTEROP=1 to create it)")
            }
            try create(dir)
        }
        if let f = try checkVersions(py) {
            failure = f
            throw Failure(description: f)
        }
        resolved = py
        return py
    }

    /// A console script from the venv (rnsd, lxmd, ...).
    static func bin(_ name: String) throws -> String {
        let f = URL(fileURLWithPath: try python()).deletingLastPathComponent().appendingPathComponent(name).path
        guard FileManager.default.isExecutableFile(atPath: f) else { throw Failure(description: "\(name) not in venv \(f)") }
        return f
    }

    private static func venvDir() -> URL {
        if let v = env("MESHSAT_RNS_VENV") { return URL(fileURLWithPath: v) }
        let cache =
            env("XDG_CACHE_HOME").map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache")
        return cache.appendingPathComponent("meshsat/rns-venv-\(rnsVersion)")
    }

    private static func create(_ dir: URL) throws {
        try FileManager.default.createDirectory(at: dir.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try run(["python3", "-m", "venv", dir.path], timeoutSec: 120)
        _ = try run(
            [
                dir.appendingPathComponent("bin/pip").path, "install", "--disable-pip-version-check", "-q", "rns==\(rnsVersion)",
                "lxmf==\(lxmfVersion)",
            ],
            timeoutSec: 600)
    }

    private static func checkVersions(_ py: String) throws -> String? {
        let out = try run([py, "-c", "import RNS, LXMF; print(RNS.__version__ + ' ' + LXMF.__version__)"], timeoutSec: 60)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = out.split(separator: " ").map(String.init)
        guard parts.count == 2 else { return "venv python cannot import RNS/LXMF: \(out)" }
        if parts[0] != rnsVersion || parts[1] != lxmfVersion {
            let pinned = "tests are pinned to RNS \(rnsVersion) / LXMF \(lxmfVersion) (recreate \(venvDir().path))"
            return "venv has RNS \(parts[0]) / LXMF \(parts[1]), " + pinned
        }
        return nil
    }

    /// Runs a command to completion and returns stdout; a non-zero exit fails with stderr.
    static func run(_ cmd: [String], timeoutSec: Int) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cmd[0].hasPrefix("/") ? cmd[0] : "/usr/bin/env")
        p.arguments = cmd[0].hasPrefix("/") ? Array(cmd.dropFirst()) : cmd
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        let deadline = Date().addingTimeInterval(Double(timeoutSec))
        while p.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if p.isRunning {
            p.terminate()
            throw Failure(description: "timeout: \(cmd)")
        }
        let stdout = String(decoding: outData, as: UTF8.self)
        if p.terminationStatus != 0 {
            throw Failure(
                description: "\(cmd.prefix(2)) failed (\(p.terminationStatus)):\n\(String(decoding: errData, as: UTF8.self))\n\(stdout)")
        }
        return stdout
    }

    /// Runs an inline Python script with args in the venv and returns its stdout.
    static func py(_ script: String, _ args: String...) throws -> String {
        try run([try python(), "-c", script] + args, timeoutSec: 120)
    }

    /// Runs a script that prints key=value lines and returns them as a map.
    static func pyKv(_ script: String, _ args: String...) throws -> [String: String] {
        var out: [String: String] = [:]
        for line in try run([try python(), "-c", script] + args, timeoutSec: 120).split(separator: "\n") where line.contains("=") {
            let i = line.firstIndex(of: "=")!
            out[String(line[..<i])] = String(line[line.index(after: i)...])
        }
        return out
    }
}
