// Mirrors NodeFirmwareUpdateTest.kt and NodeFirmwareReleaseTest.kt (MESHSAT-1672): the node
// firmware update's checks, the OTA loader's line protocol run against a scripted loader, the
// handover request and answers, and the release manifest.
import Crypto
import Foundation
import MeshSatNet
import MeshSatProto
import XCTest

@testable import MeshSatMeshtastic

final class NodeFirmwareUpdateTests: XCTestCase {
    private let env = "meshsat-tbeam-s3-rockblock9704"

    private func appImage(size: Int = 200_000, envName: String? = nil, version: String = "2.8.0.fc4f3bb") -> [UInt8] {
        var b = [UInt8](repeating: 0, count: size)
        b[0] = 0xE9
        // esp_app_desc magic 0xABCD5432 at 32, little-endian
        b[32] = 0x32
        b[33] = 0x54
        b[34] = 0xCD
        b[35] = 0xAB
        b.replaceSubrange(48..<(48 + version.utf8.count), with: Array(version.utf8))
        b.replaceSubrange(80..<88, with: Array("firmware".utf8))
        let name = Array((envName ?? env).utf8)
        b.replaceSubrange(5000..<(5000 + name.count), with: name)
        return b
    }

    private func ok(_ c: NodeFirmwareImage.Check, file: StaticString = #filePath, line: UInt = #line) -> NodeFirmwareImage? {
        guard case .ok(let image) = c else {
            XCTFail("refused: \(c)", file: file, line: line)
            return nil
        }
        return image
    }

    private func refused(_ c: NodeFirmwareImage.Check) -> Bool {
        if case .refused = c { return true }
        return false
    }

    func testAnAppImageBuiltForTheNodesEnvIsTakenWithItsVersionAndSha256() throws {
        let image = try XCTUnwrap(ok(NodeFirmwareImage.check(appImage(), nodeEnv: env)))
        XCTAssertEqual(image.version, "2.8.0.fc4f3bb")
        XCTAssertEqual(image.project, "firmware")
        XCTAssertEqual(image.sha256Hex.count, 64)
        XCTAssertEqual(image.sha256.count, 32)
        XCTAssertEqual(image.sha256, Array(SHA256.hash(data: appImage())))
    }

    func testAnImageForAnotherEnvAFactoryImageATooLargeOrTooSmallFileAreRefused() {
        XCTAssertTrue(refused(NodeFirmwareImage.check(appImage(envName: "tbeam-s3-core"), nodeEnv: env)))
        var factory = appImage()
        factory.replaceSubrange(32..<36, with: [0, 0, 0, 0])
        XCTAssertTrue(refused(NodeFirmwareImage.check(factory, nodeEnv: env)))
        XCTAssertTrue(refused(NodeFirmwareImage.check(appImage(size: NodeFirmwareImage.appSlotBytes + 1), nodeEnv: env)))
        XCTAssertTrue(refused(NodeFirmwareImage.check([UInt8](repeating: 0, count: 1000), nodeEnv: env)))
        XCTAssertTrue(refused(NodeFirmwareImage.check(appImage(), nodeEnv: "")))
        var notEsp = appImage()
        notEsp[0] = 0
        XCTAssertTrue(refused(NodeFirmwareImage.check(notEsp, nodeEnv: env)))
    }

    func testA9704ImageIsRefusedForA9603NodeAlthoughItsNameStartsTheSame() {
        let b = appImage(envName: "meshsat-tbeam-s3-rockblock9704")
        XCTAssertTrue(refused(NodeFirmwareImage.check(b, nodeEnv: "meshsat-tbeam-s3-rockblock")))
        XCTAssertNotNil(ok(NodeFirmwareImage.check(b, nodeEnv: "meshsat-tbeam-s3-rockblock9704")))
        XCTAssertNotNil(ok(NodeFirmwareImage.check(appImage(envName: "meshsat-tbeam-s3-rockblock"), nodeEnv: "meshsat-tbeam-s3-rockblock")))
    }

    func testTheOtaCommandNamesSizeAndLowercaseHashAndChunksFitTheMtu() {
        XCTAssertEqual(NodeOtaProtocol.otaCommand(size: 2_417_568, sha256Hex: "ABCDEF"), "OTA 2417568 abcdef\n")
        XCTAssertEqual(NodeOtaProtocol.chunkSize(mtu: 23), 20)
        XCTAssertEqual(NodeOtaProtocol.chunkSize(mtu: 247), 244)
        XCTAssertEqual(NodeOtaProtocol.chunkSize(mtu: 517), 512)
        XCTAssertEqual(NodeOtaProtocol.chunkSize(maxWrite: 514), 512)
        XCTAssertEqual(NodeOtaProtocol.chunkSize(maxWrite: 182), 182)
    }

    func testTheLoadersAnswersAreReadLineByLineAcrossAndWithinNotifications() {
        var partial: [UInt8] = []
        XCTAssertEqual(NodeOtaLines.splitLines(&partial, Array("ERAS".utf8)), [])
        XCTAssertEqual(NodeOtaLines.splitLines(&partial, Array("ING\r\nOK\n".utf8)), ["ERASING", "OK"])
        XCTAssertEqual(NodeOtaLines.splitLines(&partial, Array("ACK\n".utf8)), ["ACK"])
        XCTAssertEqual(NodeOtaProtocol.parseReply("OK"), .ok)
        XCTAssertEqual(NodeOtaProtocol.parseReply("OK lilygo 2.8.0 3 v1.0.1"), .ok)
        XCTAssertEqual(NodeOtaProtocol.parseReply("ACK"), .ack)
        XCTAssertEqual(NodeOtaProtocol.parseReply("ERASING"), .erasing)
        XCTAssertEqual(NodeOtaProtocol.parseReply("ERR Hash Mismatch"), .error("Hash Mismatch"))
        XCTAssertEqual(NodeOtaProtocol.parseReply("ERR"), .error("unspecified error"))
    }

    func testTheNodesHandoverAnswersAreRecognisedOtherNotificationsAreNot() {
        XCTAssertTrue(NodeOtaProtocol.isHandoverAnswer("Rebooting to BLE OTA"))
        XCTAssertTrue(NodeOtaProtocol.isRebootingToBle("Rebooting to BLE OTA"))
        XCTAssertTrue(NodeOtaProtocol.isHandoverAnswer("Cannot start OTA: Invalid `ota_hash` provided."))
        XCTAssertFalse(NodeOtaProtocol.isRebootingToBle("Cannot start OTA: Invalid `ota_hash` provided."))
        XCTAssertTrue(NodeOtaProtocol.isHandoverAnswer("OTA Loader does not support BLE"))
        XCTAssertTrue(NodeOtaProtocol.isHandoverAnswer("Unable to switch to the OTA partition."))
        XCTAssertFalse(NodeOtaProtocol.isHandoverAnswer("Low battery"))
    }

    func testTheHandoverRequestIsAnAdminOtaRequestForBleWithTheImagesHash() throws {
        let sha = [UInt8](repeating: 0xA5, count: 32)
        let bytes = MeshtasticProtoAdapter.buildAdminOtaRequest(myNodeNum: 0x1234_5678, sha256: sha)
        let toRadio = try Meshtastic_ToRadio(serializedBytes: bytes)
        guard case .packet(let pkt)? = toRadio.payloadVariant, case .decoded(let data)? = pkt.payloadVariant else {
            return XCTFail("not a packet")
        }
        XCTAssertEqual(pkt.to, 0x1234_5678)
        XCTAssertEqual(data.portnum, .adminApp)
        let admin = try Meshtastic_AdminMessage(serializedBytes: data.payload)
        guard case .otaRequest(let event)? = admin.payloadVariant else { return XCTFail("not an ota_request") }
        XCTAssertEqual(event.rebootOtaMode, .otaBle)
        XCTAssertEqual(Array(event.otaHash), sha)
    }

    func testMyNodeInfoCarriesTheBuildAndAClientNotificationIsReadAsItsText() throws {
        var mi = Meshtastic_MyNodeInfo()
        mi.myNodeNum = 7
        mi.pioEnv = env
        var fr = Meshtastic_FromRadio()
        fr.myInfo = mi
        XCTAssertEqual(MeshtasticProtocol.parseFromRadioFull(try fr.serializedBytes())?.myInfoEnv, env)
        var note = Meshtastic_ClientNotification()
        note.message = "Rebooting to BLE OTA"
        var fr2 = Meshtastic_FromRadio()
        fr2.clientNotification = note
        XCTAssertEqual(MeshtasticProtocol.parseFromRadioFull(try fr2.serializedBytes()), .clientNotification("Rebooting to BLE OTA"))
    }

    // MARK: The exchange, against a scripted loader

    func testAWholeUpdateSendsTheCommandThenEveryChunkAgainstItsAck() async throws {
        let image = try XCTUnwrap(ok(NodeFirmwareImage.check(appImage(size: 100_000), nodeEnv: env)))
        let lines = NodeOtaLines()
        let loader = ScriptedLoader(lines: lines, maxWrite: 512)
        let steps = StepLog()
        let outcome = await NodeOtaProtocol.run(image: image, link: loader, lines: lines, clock: FastClock()) { steps.add($0) }
        XCTAssertEqual(outcome, .done)
        XCTAssertEqual(loader.command, "OTA 100000 \(image.sha256Hex)\n")
        XCTAssertEqual(loader.received, image.bytes)
        XCTAssertEqual(loader.chunkSizes.max(), 512)
        XCTAssertEqual(loader.chunkSizes.count, (100_000 + 511) / 512)
        XCTAssertEqual(steps.all.first, .erasing)
        XCTAssertTrue(steps.all.contains(.verifying))
        XCTAssertEqual(steps.all.last, .sending(sent: 100_000, total: 100_000))
    }

    func testARefusedHashFailsBeforeAnythingIsErasedAndALaterErrorKeepsTheImageForARetry() async throws {
        let image = try XCTUnwrap(ok(NodeFirmwareImage.check(appImage(size: 100_000), nodeEnv: env)))
        let lines = NodeOtaLines()
        let rejecting = ScriptedLoader(lines: lines, maxWrite: 512, onCommand: ["ERR Hash Rejected"])
        let first = await NodeOtaProtocol.run(image: image, link: rejecting, lines: lines, clock: FastClock()) { _ in }
        XCTAssertEqual(first, .failed("The node refused the update: Hash Rejected", stage: .refused))
        let lines2 = NodeOtaLines()
        let midway = ScriptedLoader(lines: lines2, maxWrite: 512, failAtChunk: 10)
        let second = await NodeOtaProtocol.run(image: image, link: midway, lines: lines2, clock: FastClock()) { _ in }
        XCTAssertEqual(second, .failed("The node's updater refused the firmware: Write Failed", stage: .erased))
        let lines3 = NodeOtaLines()
        let silent = ScriptedLoader(lines: lines3, maxWrite: 512, silentAtChunk: 3)
        let third = await NodeOtaProtocol.run(image: image, link: silent, lines: lines3, clock: FastClock()) { _ in }
        XCTAssertEqual(third, .failed("The node's updater stopped answering at byte 1536.", stage: .erased))
    }

    // MARK: Interruptions (MESHSAT-1684): what each one leaves on the node, and that a retry is offered

    private func interrupted(_ loader: (NodeOtaLines) -> ScriptedLoader) async throws -> NodeOtaProtocol.Outcome {
        let image = try XCTUnwrap(ok(NodeFirmwareImage.check(appImage(size: 100_000), nodeEnv: env)))
        let lines = NodeOtaLines()
        return await NodeOtaProtocol.run(image: image, link: loader(lines), lines: lines, clock: FastClock()) { _ in }
    }

    func testAtTheHandoverOnlyAnAcceptOrADroppedLinkKeepsTheImage() {
        XCTAssertEqual(NodeOtaProtocol.handover(said: "Rebooting to BLE OTA", linkUp: false), .accepted)
        XCTAssertEqual(NodeOtaProtocol.handover(said: "Cannot start OTA: Invalid `ota_hash` provided.", linkUp: true), .refused)
        XCTAssertEqual(NodeOtaProtocol.handover(said: nil, linkUp: true), .noAnswer)
        XCTAssertEqual(NodeOtaProtocol.handover(said: nil, linkUp: false), .linkDropped)
        XCTAssertTrue(NodeOtaProtocol.keepsImage(.accepted))
        XCTAssertTrue(NodeOtaProtocol.keepsImage(.linkDropped))
        XCTAssertFalse(NodeOtaProtocol.keepsImage(.refused))
        XCTAssertFalse(NodeOtaProtocol.keepsImage(.noAnswer))
    }

    func testFromTheCommandOnEveryFailureDuringTheEraseMayHaveErasedTheFirmware() async throws {
        let silent = try await interrupted { ScriptedLoader(lines: $0, maxWrite: 512, onCommand: []) }
        XCTAssertEqual(silent, .failed("The node's updater did not answer the update command.", stage: .eraseUncertain))
        XCTAssertTrue(silent.mayBeErased)
        let stuck = try await interrupted { ScriptedLoader(lines: $0, maxWrite: 512, onCommand: ["ERASING"]) }
        XCTAssertEqual(stuck, .failed("The node's updater did not finish erasing.", stage: .eraseUncertain))
        let failedErase = try await interrupted { ScriptedLoader(lines: $0, maxWrite: 512, onCommand: ["ERASING", "ERR Erase Failed"]) }
        XCTAssertEqual(failedErase, .failed("The node refused the update: Erase Failed", stage: .eraseUncertain))
        let lost = try await interrupted { ScriptedLoader(lines: $0, maxWrite: 512, onCommand: ["ERASING"], dropAfterCommand: true) }
        XCTAssertEqual(lost, .failed("The link to the node's updater dropped while it was getting ready.", stage: .eraseUncertain))
        let unwritten = try await interrupted { ScriptedLoader(lines: $0, maxWrite: 512, commandWriteFails: true) }
        XCTAssertEqual(unwritten, .failed("The node's updater did not take the update command.", stage: .eraseUncertain))
    }

    func testARefusalBeforeTheEraseLeavesTheFirmwareAndAFailureAfterTheReadyAckLeavesNone() async throws {
        let refused = try await interrupted { ScriptedLoader(lines: $0, maxWrite: 512, onCommand: ["ERR Hash Rejected"]) }
        XCTAssertEqual(refused, .failed("The node refused the update: Hash Rejected", stage: .refused))
        XCTAssertFalse(refused.mayBeErased)
        let afterReady = try await interrupted { ScriptedLoader(lines: $0, maxWrite: 512, silentAtChunk: 1) }
        XCTAssertEqual(afterReady, .failed("The node's updater stopped answering at byte 512.", stage: .erased))
        XCTAssertTrue(afterReady.mayBeErased)
        let lostAfter = try await interrupted { ScriptedLoader(lines: $0, maxWrite: 512, dropAtChunk: 2) }
        XCTAssertEqual(lostAfter, .failed("The link to the node's updater dropped at byte 1024.", stage: .erased))
    }

    func testTheWordsAreAndroidsWordForWord() {
        typealias Rec = NodeFirmwareRecovery
        XCTAssertEqual(
            Rec.whatTheNodeHas(.intact, refused: false),
            " The node waits in its updater with its firmware still on it and starts it only after an update: retry with the same file.")
        XCTAssertEqual(
            Rec.whatTheNodeHas(.intact, refused: true),
            " The node waits in its updater with its firmware still on it: retry with the file this update started with.")
        XCTAssertEqual(
            Rec.whatTheNodeHas(.unknown, refused: false),
            " The node waits in its updater, and whether its old firmware is still on it is not known: "
                + "retry with the file the update started with.")
        XCTAssertEqual(
            Rec.whatTheNodeHas(.mayBeErased, refused: false),
            " The node may have erased its firmware and waits in its updater: retry with the same file.")
        XCTAssertEqual(
            Rec.whatTheNodeHas(.erased, refused: false), " The node erased its firmware and waits in its updater: retry with the same file."
        )
        XCTAssertEqual(
            "Bluetooth is off." + Rec.whatTheNodeHas(.erased, refused: false, bluetoothOff: true),
            "Bluetooth is off. The node erased its firmware and waits in its updater: switch Bluetooth on and retry with the same file.")
        for known in [Rec.Known.unknown, .mayBeErased, .erased] {
            for refused in [false, true] {
                XCTAssertFalse(Rec.whatTheNodeHas(known, refused: refused).contains("still on it and"), "\(known)")
                XCTAssertFalse(Rec.whatTheNodeHas(known, refused: refused).contains("with its firmware still on it"), "\(known)")
            }
        }
    }

    // MARK: The recovery session across attempts (R63-F1), as NodeFirmwareRecoveryFlowTest.kt

    private func failed(_ stage: NodeOtaProtocol.Stage, _ reason: String = "The node's updater did not answer over Bluetooth.")
        -> NodeOtaProtocol.Outcome
    { .failed(reason, stage: stage) }

    private func text(_ r: NodeFirmwareRecovery.Result, file: StaticString = #filePath, line: UInt = #line) -> String {
        guard case .failed(let t) = r else {
            XCTFail("expected a failure, got \(r)", file: file, line: line)
            return ""
        }
        return t
    }

    func testARetryAcrossAttemptsKeepsTheStrongestStateTheSessionSaw() async throws {
        let image = try XCTUnwrap(ok(NodeFirmwareImage.check(appImage(), nodeEnv: env)))
        let session = NodeFirmwareRecovery()
        session.began(image, address: "44:1B:F6:F9:41:7D")
        let step1 = text(await session.attempt { self.failed(.eraseUncertain) })
        XCTAssertTrue(step1.contains("may have erased its firmware"), step1)
        XCTAssertEqual(session.known, .mayBeErased)
        // The retry's transport starts again at "not commanded": the session keeps what it saw.
        let second = text(await session.attempt { self.failed(.notCommanded) })
        XCTAssertTrue(second.contains("may have erased its firmware"), second)
        XCTAssertFalse(second.contains("still on it"), second)
        XCTAssertEqual(session.known, .mayBeErased)
        let step2 = text(await session.attempt { self.failed(.erased) })
        XCTAssertTrue(step2.contains("erased its firmware and waits"), step2)
        XCTAssertEqual(session.known, .erased)
        let fourth = text(await session.attempt { self.failed(.refused, "The node refused the update: Hash Rejected") })
        XCTAssertTrue(fourth.contains("erased its firmware and waits"), fourth)
        XCTAssertFalse(fourth.contains("still on it"), fourth)
        XCTAssertEqual(session.kept?.image, image, "the image is kept")
        let done = await session.attempt { .done }
        XCTAssertEqual(done, .done)
        XCTAssertNil(session.known, "a finished update clears the session")
        XCTAssertNil(session.kept)
    }

    func testARecoveryWithNoHistoryNeverSaysTheOldFirmwareIsStillThere() async throws {
        let image = try XCTUnwrap(ok(NodeFirmwareImage.checkForWaitingUpdater(appImage())))
        let session = NodeFirmwareRecovery()
        session.beganByHand(image, address: "")
        let first = text(await session.attempt { self.failed(.notCommanded) })
        XCTAssertTrue(first.contains("whether its old firmware is still on it is not known"), first)
        XCTAssertFalse(first.contains("with its firmware still on it"), first)
        XCTAssertEqual(session.known, .unknown)
        let second = text(await session.attempt { self.failed(.refused, "The node refused the update: Hash Rejected") })
        XCTAssertTrue(second.contains("is not known"), second)
        XCTAssertFalse(second.contains("with its firmware still on it"), second)
        let step3 = text(await session.attempt { self.failed(.eraseUncertain) })
        XCTAssertTrue(step3.contains("may have erased"), step3)
        let fourth = text(await session.attempt { self.failed(.notCommanded) })
        XCTAssertTrue(fourth.contains("may have erased"), fourth)
        XCTAssertEqual(session.known, .mayBeErased)
    }

    func testPickingTheFileAgainForTheUpdaterKeepsWhatTheSessionKnows() async throws {
        let image = try XCTUnwrap(ok(NodeFirmwareImage.check(appImage(), nodeEnv: env)))
        let session = NodeFirmwareRecovery()
        session.began(image, address: "44:1B:F6:F9:41:7D")
        let step4 = text(await session.attempt { self.failed(.erased) })
        XCTAssertTrue(step4.contains("erased its firmware"), step4)
        session.beganByHand(image, address: "44:1B:F6:F9:41:7D")
        let again = text(await session.attempt { self.failed(.notCommanded) })
        XCTAssertTrue(again.contains("erased its firmware and waits"), again)
        XCTAssertEqual(session.known, .erased)
    }

    func testASessionThatNeverWroteItsCommandSaysTheFirmwareIsThereAndBluetoothOffKeepsTheSessionsWords() async throws {
        let image = try XCTUnwrap(ok(NodeFirmwareImage.check(appImage(), nodeEnv: env)))
        let session = NodeFirmwareRecovery()
        session.began(image, address: "44:1B:F6:F9:41:7D")
        let refused = text(await session.attempt { self.failed(.refused, "The node refused the update: Hash Rejected") })
        XCTAssertTrue(refused.contains("with its firmware still on it: retry with the file this update started with."), refused)
        XCTAssertEqual(session.known, .intact)
        _ = await session.attempt { self.failed(.erased) }
        XCTAssertEqual(
            session.bluetoothOffText(),
            "Bluetooth is off. The node erased its firmware and waits in its updater: switch Bluetooth on and retry with the same file.")
        XCTAssertEqual(
            NodeFirmwareRecovery().bluetoothOffText(),
            "Bluetooth is off. The node waits in its updater, and whether its old firmware is still on it is not known: "
                + "switch Bluetooth on and retry with the file the update started with.",
            "with no session, Bluetooth off says nothing is known")
    }

    func testANewHandoverStartsANewSession() async throws {
        let image = try XCTUnwrap(ok(NodeFirmwareImage.check(appImage(), nodeEnv: env)))
        let session = NodeFirmwareRecovery()
        session.began(image, address: "44:1B:F6:F9:41:7D")
        _ = await session.attempt { self.failed(.erased) }
        let done = await session.attempt { .done }
        XCTAssertEqual(done, .done)
        session.began(image, address: "44:1B:F6:F9:41:7D")
        let next = text(await session.attempt { self.failed(.notCommanded) })
        XCTAssertTrue(next.contains("with its firmware still on it"), next)
        XCTAssertEqual(session.known, .intact)
    }

    func testTheMergeOnlyMovesUp() {
        typealias Kno = NodeFirmwareRecovery.Known
        XCTAssertEqual(Kno.merge(.erased, .intact), .erased)
        XCTAssertEqual(Kno.merge(.erased, .unknown), .erased)
        XCTAssertEqual(Kno.merge(.unknown, .mayBeErased), .mayBeErased)
        XCTAssertEqual(Kno.merge(.unknown, .intact), .unknown)
        XCTAssertEqual(Kno.merge(.intact, .unknown), .unknown)
        XCTAssertEqual(Kno.merge(nil, .intact), .intact)
        XCTAssertEqual(Kno.of(.notCommanded), .intact)
        XCTAssertEqual(Kno.of(.refused), .intact)
        XCTAssertEqual(Kno.of(.eraseUncertain), .mayBeErased)
        XCTAssertEqual(Kno.of(.erased), .erased)
    }

    func testAWaitingUpdaterTakesAnAppImageWithoutTheEnvCheckButNeverAFactoryImage() {
        XCTAssertNotNil(ok(NodeFirmwareImage.checkForWaitingUpdater(appImage(envName: "something-else"))))
        var factory = appImage()
        factory.replaceSubrange(32..<36, with: [0, 0, 0, 0])
        XCTAssertTrue(refused(NodeFirmwareImage.checkForWaitingUpdater(factory)))
    }

    // MARK: The release manifest

    private let sha = String(repeating: "a", count: 64)

    private func manifest(schema: Int = 1, images: String? = nil) -> [UInt8] {
        let defaultImages = """
            [
              {"env": "meshsat-tbeam-s3-rockblock9704", "file": "firmware-meshsat-tbeam-s3-rockblock9704-2.8.0.4012de5.bin", \
            "size": 2419024, "sha256": "\(sha)"},
              {"env": "meshsat-tbeam-s3-rockblock", "file": "firmware-meshsat-tbeam-s3-rockblock-2.8.0.4012de5.bin", \
            "size": 2400000, "sha256": "\(String(repeating: "b", count: 64))"}
            ]
            """
        return Array(
            """
            {"schema": \(schema), "version": "2.8.0.4012de5", "tag": "meshsat-node-2.8.0.4012de5",
             "commit": "4012de597", "released_at": "2026-10-24T20:00:00Z",
             "images": \(images ?? defaultImages)}
            """.utf8)
    }

    private func parsed(_ bytes: [UInt8], file: StaticString = #filePath, line: UInt = #line) -> NodeFirmwareRelease.Manifest? {
        guard case .ok(let m) = NodeFirmwareRelease.parse(bytes) else {
            XCTFail("refused", file: file, line: line)
            return nil
        }
        return m
    }

    private func isRefused(_ p: NodeFirmwareRelease.Parsed) -> Bool {
        if case .refused = p { return true }
        return false
    }

    func testASchema1ManifestIsRead() throws {
        let m = try XCTUnwrap(parsed(manifest()))
        XCTAssertEqual(m.version, "2.8.0.4012de5")
        XCTAssertEqual(m.tag, "meshsat-node-2.8.0.4012de5")
        XCTAssertEqual(m.commit, "4012de597")
        XCTAssertEqual(m.images.count, 2)
        XCTAssertEqual(m.images[0].size, 2_419_024)
    }

    func testAnotherSchemaABrokenEntryNoImagesAndNoJsonAreRefused() {
        XCTAssertTrue(isRefused(NodeFirmwareRelease.parse(manifest(schema: 2))))
        XCTAssertTrue(isRefused(NodeFirmwareRelease.parse(manifest(images: "[]"))))
        XCTAssertTrue(
            isRefused(NodeFirmwareRelease.parse(manifest(images: #"[{"env": "x", "file": "f.bin", "size": 10, "sha256": "short"}]"#))))
        XCTAssertTrue(
            isRefused(NodeFirmwareRelease.parse(manifest(images: #"[{"env": "x", "file": "../f.bin", "size": 10, "sha256": "\#(sha)"}]"#))))
        let tooBig = NodeFirmwareImage.appSlotBytes + 1
        XCTAssertTrue(
            isRefused(
                NodeFirmwareRelease.parse(manifest(images: #"[{"env": "x", "file": "f.bin", "size": \#(tooBig), "sha256": "\#(sha)"}]"#))))
        XCTAssertTrue(isRefused(NodeFirmwareRelease.parse(Array("not json".utf8))))
        guard case .refused(let reason) = NodeFirmwareRelease.parse(manifest(schema: 2)) else { return XCTFail("taken") }
        XCTAssertTrue(reason.contains("schema 2"), reason)
    }

    func testTheNodesOwnBuildIsPickedByItsExactName() throws {
        let m = try XCTUnwrap(parsed(manifest()))
        guard case .found(_, let i9704) = NodeFirmwareRelease.pick(m, nodeEnv: "meshsat-tbeam-s3-rockblock9704") else {
            return XCTFail("9704")
        }
        XCTAssertEqual(i9704.env, "meshsat-tbeam-s3-rockblock9704")
        guard case .found(_, let i9603) = NodeFirmwareRelease.pick(m, nodeEnv: "meshsat-tbeam-s3-rockblock") else { return XCTFail("9603") }
        XCTAssertEqual(i9603.env, "meshsat-tbeam-s3-rockblock")
        guard case .refused = NodeFirmwareRelease.pick(m, nodeEnv: "meshsat-xiao-s3-rockblock") else { return XCTFail("xiao") }
        guard case .refused = NodeFirmwareRelease.pick(m, nodeEnv: "") else { return XCTFail("empty") }
    }

    func testTheDownloadMustBeTheManifestsSizeAndSha256() {
        let bytes = (0..<1000).map { UInt8(truncatingIfNeeded: $0) }
        let good = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let image = NodeFirmwareRelease.Image(env: "e", file: "f.bin", size: 1000, sha256: good)
        XCTAssertNil(NodeFirmwareRelease.verify(bytes, image))
        XCTAssertNotNil(NodeFirmwareRelease.verify(Array(bytes.prefix(999)), image))
        XCTAssertNotNil(NodeFirmwareRelease.verify(bytes, NodeFirmwareRelease.Image(env: "e", file: "f.bin", size: 1000, sha256: sha)))
    }

    /// The first manifest meshsat-firmware published (24 Oct 2026), as fetched from the release.
    func testTheFirstPublishedManifestIsReadAndEachBuildFindsItsOwnImage() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "manifest-2.8.0.1505094", withExtension: "json", subdirectory: "Fixtures/nodefirmware"))
        let m = try XCTUnwrap(parsed(Array(try Data(contentsOf: url))))
        XCTAssertEqual(m.version, "2.8.0.1505094")
        XCTAssertEqual(m.tag, "meshsat-node-2.8.0.1505094")
        for env in ["meshsat-tbeam-s3-rockblock", "meshsat-tbeam-s3-rockblock9704", "meshsat-xiao-s3-rockblock"] {
            guard case .found(_, let image) = NodeFirmwareRelease.pick(m, nodeEnv: env) else { return XCTFail(env) }
            XCTAssertEqual(image.file, "firmware-\(env)-2.8.0.1505094.bin")
            XCTAssertLessThanOrEqual(image.size, NodeFirmwareImage.appSlotBytes)
        }
        XCTAssertFalse(NodeFirmwareRelease.isCurrent(m, running: "2.8.0.4012de5"), "another commit is another version, not an older one")
    }

    func testTheImageUrlAndTheCurrentVersion() throws {
        let m = try XCTUnwrap(parsed(manifest()))
        XCTAssertEqual(
            NodeFirmwareRelease.imageURL(m, m.images[0]),
            "https://github.com/meshsat/meshsat-firmware/releases/download/meshsat-node-2.8.0.4012de5/"
                + "firmware-meshsat-tbeam-s3-rockblock9704-2.8.0.4012de5.bin")
        XCTAssertTrue(NodeFirmwareRelease.isCurrent(m, running: "2.8.0.4012de5"))
        XCTAssertFalse(NodeFirmwareRelease.isCurrent(m, running: "2.8.0.fc4f3bb"))
        XCTAssertFalse(NodeFirmwareRelease.isCurrent(m, running: ""))
        XCTAssertEqual(
            NodeFirmwareRelease.manifestURL, "https://github.com/meshsat/meshsat-firmware/releases/latest/download/manifest.json")
    }
}

extension MeshtasticProtocol.FromRadioResult {
    fileprivate var myInfoEnv: String? {
        if case .myInfo(let mi) = self { return mi.pioEnv }
        return nil
    }
}

/// Time that passes only as the code under test sleeps, so the timeouts run in no time.
private final class FastClock: DriverClock, @unchecked Sendable {
    private let lock = NSLock()
    private var now: Int64 = 1_700_000_000_000
    func nowMs() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return now
    }
    func sleep(ms: Int64) async {
        advance(ms)
        await Task.yield()
    }
    private func advance(_ ms: Int64) {
        lock.lock()
        now += ms
        lock.unlock()
    }
}

private final class StepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [NodeOtaProtocol.Step] = []
    func add(_ s: NodeOtaProtocol.Step) {
        lock.lock()
        steps.append(s)
        lock.unlock()
    }
    var all: [NodeOtaProtocol.Step] {
        lock.lock()
        defer { lock.unlock() }
        return steps
    }
}

/// The loader as esp32-unified-ota v1.0.1 answers: ERASING and OK to the command, ACK to every
/// chunk, OK to the last; or a scripted refusal or silence.
private final class ScriptedLoader: NodeOtaLink, @unchecked Sendable {
    private let lock = NSLock()
    private let lines: NodeOtaLines
    private let maxWrite: Int
    private let onCommand: [String]
    private let failAtChunk: Int?
    private let silentAtChunk: Int?
    private let dropAtChunk: Int?
    private let dropAfterCommand: Bool
    private let commandWriteFails: Bool
    private var expected = 0
    private(set) var command = ""
    private(set) var received: [UInt8] = []
    private(set) var chunkSizes: [Int] = []

    init(
        lines: NodeOtaLines, maxWrite: Int, onCommand: [String] = ["ERASING", "OK"], failAtChunk: Int? = nil, silentAtChunk: Int? = nil,
        dropAtChunk: Int? = nil, dropAfterCommand: Bool = false, commandWriteFails: Bool = false
    ) {
        self.lines = lines
        self.maxWrite = maxWrite
        self.onCommand = onCommand
        self.failAtChunk = failAtChunk
        self.silentAtChunk = silentAtChunk
        self.dropAtChunk = dropAtChunk
        self.dropAfterCommand = dropAfterCommand
        self.commandWriteFails = commandWriteFails
    }

    func maxWriteWithoutResponse() -> Int { maxWrite }

    func writeCommand(_ bytes: [UInt8]) async -> Bool {
        let text = String(decoding: bytes, as: UTF8.self)
        let parts = text.split(separator: " ")
        noteCommand(text, size: parts.count == 3 ? Int(parts[1]) ?? 0 : 0)
        if commandWriteFails { return false }
        // Split the answers across notifications, as a real link may.
        let joined = Array(onCommand.map { $0 + "\r\n" }.joined().utf8)
        lines.feed(Array(joined.prefix(3)))
        lines.feed(Array(joined.dropFirst(3)))
        if dropAfterCommand { lines.close() }
        return true
    }

    private func noteCommand(_ text: String, size: Int) {
        lock.lock()
        command = text
        expected = size
        lock.unlock()
    }

    /// The chunk's number and whether the image is complete with it.
    private func noteChunk(_ bytes: [UInt8]) -> (Int, Bool) {
        lock.lock()
        defer { lock.unlock() }
        received.append(contentsOf: bytes)
        chunkSizes.append(bytes.count)
        return (chunkSizes.count, received.count >= expected)
    }

    func writeChunk(_ bytes: [UInt8]) async -> Bool {
        let (n, done) = noteChunk(bytes)
        if n == silentAtChunk { return true }
        if n == dropAtChunk {
            lines.close()
            return true
        }
        if n == failAtChunk {
            lines.feed(Array("ERR Write Failed\n".utf8))
        } else {
            lines.feed(Array((done ? "OK\n" : "ACK\n").utf8))
        }
        return true
    }
}
