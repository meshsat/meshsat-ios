// Mirrors the Room Flow MeshSat Android's conversation screen collects for message_attachments (MESHSAT-1735): a
// received LXMF message is filed first and its voice note and photo just after, so the chat view must hear about
// attachments that land after their row. Found on the iPhone on 8 Nov 2026: the note and photo from a Python LXMF
// peer arrived and were stored, and the chat showed an empty bubble.
import Foundation
import MeshSatEngine
import MeshSatLXMF
import XCTest

@testable import MeshSatStore

final class MessageAttachmentStoreTests: XCTestCase {
    private let peer = "1947e885fcb1fd65496a8cc7441800a8"

    func testTheObservationSeesAttachmentsFiledAfterTheirMessage() async throws {
        let db = try AppDatabase.inMemory()
        let id = try await db.messages.insert(MessageRecord(timestamp: 1000, transport: "lxmf", direction: "rx", sender: peer, text: ""))
        var updates = db.attachments.observeConversation(peer).makeAsyncIterator()
        let before = try await updates.next()
        XCTAssertEqual(before, [], "the row alone has no attachments yet")

        _ = try await db.attachments.insertAttachments(
            messageId: id, [.audio(mode: 0x10, data: [0x4F, 0x67, 0x67]), .image(format: "webp", data: [1, 2])], now: 2000)
        let after = try await updates.next()
        XCTAssertEqual(after?.map(\.messageId), [id, id])
        XCTAssertEqual(after?.map(\.kind), ["audio", "image"])
    }

    func testAnotherConversationsAttachmentsAreNotInIt() async throws {
        let db = try AppDatabase.inMemory()
        let mine = try await db.messages.insert(MessageRecord(timestamp: 1000, transport: "lxmf", direction: "rx", sender: peer, text: ""))
        let other = try await db.messages.insert(
            MessageRecord(timestamp: 1001, transport: "lxmf", direction: "rx", sender: "00d75597173fbdb0286b16bfa0053422", text: ""))
        _ = try await db.attachments.insertAttachments(messageId: other, [.image(format: "webp", data: [9])], now: 2000)
        _ = try await db.attachments.insertAttachments(messageId: mine, [.image(format: "webp", data: [8])], now: 2001)
        var updates = db.attachments.observeConversation(peer).makeAsyncIterator()
        let list = try await updates.next()
        XCTAssertEqual(list?.map(\.messageId), [mine])
    }
}
