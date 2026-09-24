// Mirrors crypto/ProvisionClaim.kt: the provisioning claim in progress, held by the app rather
// than by a screen (MESHSAT-1306). The Hub hands the credentials out only once its brokers
// accept them, which took 63 s in the owner's test on 21 Sep 2026. The claim used to run in the
// Setup screen, so leaving the screen dropped it. Here it runs to the end wherever the person
// goes, and `state` says where it stands for as long as it takes.
//
// Applying the bundle (settings, Keychain, the credentials table, the gateway restart) is the
// app's job through `ProvisionApplier`, so this file has no Apple dependency.
import Foundation
import MeshSatNet

public protocol ProvisionApplier: Sendable {
    func apply(_ bundle: ProvisionImporter.ProvisionBundle) async throws
}

public final class ProvisionClaim: @unchecked Sendable {
    public enum State: Sendable, Equatable {
        case idle
        /// Asking the Hub; `attempts` answers so far were "not ready yet".
        case waiting(bridgeId: String, hubHost: String, startedMs: Int64, attempts: Int)
        /// A scanned code's credentials, for the person to confirm.
        case ready(ProvisionImporter.ProvisionBundle)
        case applied(bridgeId: String)
        case failed(String)
    }

    public let state = StateBroadcast<State>(.idle)
    private let http: any HttpGetter
    private let applier: any ProvisionApplier
    private let now: @Sendable () -> Int64
    private let sleep: @Sendable (Int64) async throws -> Void
    private let lock = NSLock()
    private var job: Task<Void, Never>?

    public init(
        http: any HttpGetter, applier: any ProvisionApplier,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
        sleep: @escaping @Sendable (Int64) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0) * 1_000_000) }
    ) {
        self.http = http
        self.applier = applier
        self.now = now
        self.sleep = sleep
    }

    /// A QR code the person scanned: claim, then ask them to confirm with what came back,
    /// since scanning was their choice (MESHSAT-1235).
    public func fromQr(_ url: String) {
        let request = try? ProvisionImporter.parseLink(url)
        let http = self.http
        let sleep = self.sleep
        let now = self.now
        run(bridgeId: request?.bridgeId ?? "", hubHost: request?.hubHost ?? "", confirm: true) { onWaiting in
            try await ProvisionImporter.processQr(url, http: http, onWaiting: onWaiting, sleep: sleep, now: now)
        }
    }

    /// A deep link the person already confirmed: claim and apply.
    public func fromLink(_ request: ProvisionImporter.ProvisionRequest) {
        let http = self.http
        let sleep = self.sleep
        let now = self.now
        run(bridgeId: request.bridgeId, hubHost: request.hubHost, confirm: false) { onWaiting in
            try await ProvisionImporter.claimBundle(request, http: http, onWaiting: onWaiting, sleep: sleep, now: now)
        }
    }

    /// The person confirmed a `ready` bundle.
    public func apply() {
        guard case .ready(let bundle) = state.value else { return }
        state.send(.idle)  // the dialog goes at once: a second tap applies nothing
        let task = Task { [self] in await applyNow(bundle) }
        replaceJob(task)
    }

    /// Back to `idle`, abandoning a claim still waiting.
    public func dismiss() {
        replaceJob(nil)
        state.send(.idle)
    }

    private func replaceJob(_ task: Task<Void, Never>?) {
        lock.lock()
        let old = job
        job = task
        lock.unlock()
        old?.cancel()
    }

    private func run(
        bridgeId: String, hubHost: String, confirm: Bool,
        claim: @escaping @Sendable (@escaping @Sendable (Int) -> Void) async throws -> ProvisionImporter.ProvisionBundle
    ) {
        let started = now()
        state.send(.waiting(bridgeId: bridgeId, hubHost: hubHost, startedMs: started, attempts: 0))
        let task = Task { [self] in
            do {
                let bundle = try await claim { attempt in
                    self.state.send(.waiting(bridgeId: bridgeId, hubHost: hubHost, startedMs: started, attempts: attempt))
                }
                if Task.isCancelled { return }
                if confirm { state.send(.ready(bundle)) } else { await applyNow(bundle) }
            } catch is CancellationError {
                return
            } catch let e as ProvisionImporter.ProvisionError {
                if Task.isCancelled { return }
                state.send(.failed(e.message.isEmpty ? "The Hub did not hand out the settings" : e.message))
            } catch {
                if Task.isCancelled { return }
                state.send(.failed("Provisioning failed: \(error)"))
            }
        }
        replaceJob(task)
    }

    private func applyNow(_ bundle: ProvisionImporter.ProvisionBundle) async {
        do {
            try await applier.apply(bundle)
            state.send(.applied(bridgeId: bundle.bridgeId))
        } catch {
            state.send(.failed("Could not save the Hub settings: \(error)"))
        }
    }
}
