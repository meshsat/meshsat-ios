// Mirrors interop/PyPeer.kt: an upstream Python RNS + LXMF peer (Fixtures/interop/rnsnode.py, the
// Bridge's script unchanged) driven over stdin/stdout JSON lines.
import Foundation
import XCTest

final class PyPeer: @unchecked Sendable {
    typealias Event = [String: Any]

    struct Opts {
        var transport = false
        var connect: String?
        var listen = 0
        /// An AutoInterface on this network device (a veth end).
        var auto: String?
        /// An RNodeInterface on this serial port (a software RNode's pty) with these radio parameters.
        var rnode: String?
        var rnodeParams: String?
        var name = "rnsnode"
        var stampCost = 0
        var enforce = false
        var loglevel = 0
        /// Also run an LXMF propagation node at this stamp cost (13 is the minimum upstream allows).
        var propagationNode = false
        var propagationCost = 13

        init(name: String = "rnsnode", transport: Bool = false, connect: String? = nil, listen: Int = 0) {
            self.name = name
            self.transport = transport
            self.connect = connect
            self.listen = listen
        }
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    let name: String
    let cfgDir: URL
    private let proc: Process
    private let stdin: FileHandle
    private let lock = NSLock()
    private var log: [Event] = []
    private var exited = false

    private(set) var identity = ""
    private(set) var delivery = ""
    private(set) var raw = ""
    private(set) var transportId = ""
    /// The lxmf.propagation destination when started with `propagationNode`, else "".
    private(set) var propagation = ""

    private static let startedLock = NSLock()
    nonisolated(unsafe) private static var started: [PyPeer] = []
    /// Set when a wait timed out, so the peers' logs are dumped at the end even if the test did not notice.
    nonisolated(unsafe) static var waitFailed = false

    private static func script() throws -> String {
        guard let url = Bundle.module.url(forResource: "rnsnode", withExtension: "py", subdirectory: "Fixtures/interop") else {
            throw Failure(description: "Fixtures/interop/rnsnode.py missing from the test bundle")
        }
        return url.path
    }

    private init(name: String, proc: Process, cfgDir: URL, stdin: FileHandle) {
        self.name = name
        self.proc = proc
        self.cfgDir = cfgDir
        self.stdin = stdin
    }

    static func start(_ o: Opts) async throws -> PyPeer {
        let py = try PyEnv.python()
        let cfgDir = FileManager.default.temporaryDirectory.appendingPathComponent("rnspeer-\(o.name)-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: cfgDir, withIntermediateDirectories: true)
        var args = [try script(), "--config-dir", cfgDir.path, "--name", o.name]
        if o.transport { args += ["--transport", "yes"] }
        if let c = o.connect { args += ["--connect", c] }
        if o.listen != 0 { args += ["--listen", String(o.listen)] }
        if let a = o.auto { args += ["--auto", a] }
        if let r = o.rnode {
            args += ["--rnode", r]
            if let p = o.rnodeParams { args += ["--rnode-params", p] }
        }
        if o.stampCost > 0 { args += ["--stamp-cost", String(o.stampCost)] }
        if o.enforce { args.append("--enforce-stamps") }
        if o.propagationNode { args += ["--propagation-node", "--propagation-cost", String(o.propagationCost)] }
        if o.loglevel > 0 { args += ["--loglevel", String(o.loglevel)] }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: py)
        proc.arguments = args
        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        try proc.run()
        let p = PyPeer(name: o.name, proc: proc, cfgDir: cfgDir, stdin: inPipe.fileHandleForWriting)
        register(p)
        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading
        Thread.detachNewThread { [weak p] in
            var buf = Data()
            while true {
                let chunk = outHandle.availableData
                if chunk.isEmpty { break }
                buf.append(chunk)
                while let nl = buf.firstIndex(of: 0x0A) {
                    let line = buf[buf.startIndex..<nl]
                    buf.removeSubrange(buf.startIndex...nl)
                    if let ev = (try? JSONSerialization.jsonObject(with: Data(line))) as? Event { p?.append(ev) }
                }
            }
            p?.markExited()
        }
        Thread.detachNewThread {
            while true {
                let chunk = errHandle.availableData
                if chunk.isEmpty { break }
                FileHandle.standardError.write(Data("[py \(o.name)] ".utf8) + chunk)
            }
        }
        let ready = try await p.wait("ready", timeoutMs: 30_000)
        p.identity = ready["identity"] as? String ?? ""
        p.delivery = ready["delivery"] as? String ?? ""
        p.raw = ready["raw"] as? String ?? ""
        p.transportId = ready["transport_id"] as? String ?? ""
        p.propagation = ready["propagation"] as? String ?? ""
        if let v = ready["rns"] as? String, v != PyEnv.rnsVersion {
            throw Failure(description: "peer runs RNS \(v), want \(PyEnv.rnsVersion)")
        }
        return p
    }

    private func append(_ ev: Event) {
        lock.lock()
        log.append(ev)
        lock.unlock()
        if ev["event"] as? String == "error" {
            FileHandle.standardError.write(Data("[py \(name)] error event: \(ev["error"] ?? "")\n".utf8))
        }
    }

    private func markExited() {
        lock.lock()
        exited = true
        lock.unlock()
    }

    private static func register(_ p: PyPeer) {
        startedLock.lock()
        started.append(p)
        startedLock.unlock()
    }

    /// Stops every peer started so far; call from tearDown.
    static func stopAll(dumpLogs: Bool) {
        startedLock.lock()
        let ps = started
        started = []
        startedLock.unlock()
        let dump = dumpLogs || waitFailed
        waitFailed = false
        for p in ps { p.stop(dumpLog: dump) }
    }

    func send(_ cmd: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: cmd)
        lock.lock()
        defer { lock.unlock() }
        stdin.write(data + Data([0x0A]))
    }

    func send(_ cmd: String, _ kv: [String: Any] = [:]) throws {
        var m = kv
        m["cmd"] = cmd
        try send(m)
    }

    /// The first event named `name` matching `pred`; events already received are searched first.
    @discardableResult
    func wait(_ name: String, _ pred: ((Event) -> Bool)? = nil, timeoutMs: Int64 = 10_000) async throws -> Event {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while true {
            let found: Event? = {
                lock.lock()
                defer { lock.unlock() }
                if let i = log.firstIndex(where: { $0["event"] as? String == name && (pred?($0) ?? true) }) { return log.remove(at: i) }
                return nil
            }()
            if let found { return found }
            let gone: Bool = {
                lock.lock()
                defer { lock.unlock() }
                return exited
            }()
            if gone { throw Failure(description: "peer \(self.name) exited while waiting for \(name)") }
            if Date() >= deadline {
                Self.waitFailed = true
                let seen: [String] = {
                    lock.lock()
                    defer { lock.unlock() }
                    return log.suffix(12).map {
                        ($0["event"] as? String ?? "?") + (($0["dest"] as? String).map { ":" + String($0.prefix(8)) } ?? "")
                    }
                }()
                throw Failure(description: "timeout waiting for \(name) from peer \(self.name); last events: \(seen)")
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// The event when it arrives within `timeoutMs`, else nil.
    func tryWait(_ name: String, _ pred: ((Event) -> Bool)? = nil, timeoutMs: Int64) async -> Event? {
        try? await wait(name, pred, timeoutMs: timeoutMs)
    }

    func stop(dumpLog: Bool) {
        try? send("quit")
        let deadline = Date().addingTimeInterval(3)
        while proc.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if proc.isRunning { proc.terminate() }
        if dumpLog, let text = try? String(contentsOf: cfgDir.appendingPathComponent("rns.log"), encoding: .utf8) {
            let tail = text.split(separator: "\n").suffix(120).joined(separator: "\n")
            FileHandle.standardError.write(Data("[py \(name) rns.log tail]\n\(tail)\n".utf8))
        }
        try? FileManager.default.removeItem(at: cfgDir)
    }
}

/// JSON numbers arrive as NSNumber on both platforms.
func num(_ v: Any?) -> Int { (v as? NSNumber)?.intValue ?? (v as? Int) ?? -1 }
func bool(_ v: Any?) -> Bool { (v as? NSNumber)?.boolValue ?? (v as? Bool) ?? false }
