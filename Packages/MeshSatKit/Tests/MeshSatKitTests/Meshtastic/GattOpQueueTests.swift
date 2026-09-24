// Mirrors GattOpQueueTest.kt: one GATT operation at a time (MESHSAT-1236). Android drops an
// operation issued while another is in flight, which is how the fromNum subscription used to
// go missing.
import MeshSatMeshtastic
import XCTest

final class GattOpQueueTests: XCTestCase {
    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ s: String) {
            lock.lock()
            items.append(s)
            lock.unlock()
        }
        var list: [String] {
            lock.lock()
            defer { lock.unlock() }
            return items
        }
    }

    private func settle() async { try? await Task.sleep(for: .milliseconds(100)) }

    func testTheNextOperationStartsOnlyAfterThePreviousOneCompleted() async {
        let queue = GattOpQueue(timeoutMs: 2_000)
        let started = Log()
        let first = queue.enqueue("w:a") {
            started.add("a")
            return true
        }
        let second = queue.enqueue("w:b") {
            started.add("b")
            return true
        }

        await settle()
        XCTAssertEqual(started.list, ["a"])

        queue.complete("w:a", status: 0)
        let r1 = await first.await()
        XCTAssertEqual(r1, 0)
        await settle()
        XCTAssertEqual(started.list, ["a", "b"])

        queue.complete("w:b", status: 0)
        let r2 = await second.await()
        XCTAssertEqual(r2, 0)
    }

    func testAnOperationTheStackRefusesFailsWithoutBlockingTheQueue() async {
        let queue = GattOpQueue(timeoutMs: 2_000)
        let refused = queue.enqueue("w:a") { false }
        let next = queue.enqueue("w:b") { true }
        let r = await refused.await()
        XCTAssertEqual(r, GattOpQueue.statusRefused)
        await settle()
        queue.complete("w:b", status: 0)
        let n = await next.await()
        XCTAssertEqual(n, 0)
    }

    func testAnOperationThatNeverCompletesTimesOutAndTheQueueMovesOn() async {
        let queue = GattOpQueue(timeoutMs: 200)
        let stuck = queue.enqueue("w:a") { true }
        let next = queue.enqueue("w:b") { true }
        let s = await stuck.await()
        XCTAssertEqual(s, GattOpQueue.statusTimeout)
        await settle()
        queue.complete("w:b", status: 0)
        let n = await next.await()
        XCTAssertEqual(n, 0)
    }

    func testALateCallbackForAnotherKeyDoesNotCompleteTheOperationInFlight() async {
        let queue = GattOpQueue(timeoutMs: 300)
        let op = queue.enqueue("w:b") { true }
        await settle()
        queue.complete("w:a", status: 0)
        let r = await op.await()
        XCTAssertEqual(r, GattOpQueue.statusTimeout)
    }

    func testCloseFailsWhatIsQueued() async {
        let queue = GattOpQueue(timeoutMs: 2_000)
        let inFlight = queue.enqueue("w:a") { true }
        let queued = queue.enqueue("w:b") { true }
        await settle()
        queue.close()
        let a = await inFlight.await()
        let b = await queued.await()
        let c = await queue.enqueue("w:c") { true }.await()
        XCTAssertEqual(a, GattOpQueue.statusClosed)
        XCTAssertEqual(b, GattOpQueue.statusClosed)
        XCTAssertEqual(c, GattOpQueue.statusClosed)
    }
}
