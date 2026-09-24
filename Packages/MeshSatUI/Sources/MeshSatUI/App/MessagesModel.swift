// The Messages tab's state, as ui/screens/MessagesScreen.kt collects it from the Room DAOs: the
// recent or searched messages, the conversations, today's count, the conversation keys and the
// global key, mirrored from the store's observations into one @Observable object.
import Foundation
import MeshSatEngine
import MeshSatPlatform
import MeshSatStore
import Observation

@Observable
@MainActor
public final class MessagesModel {
    private let gateway: GatewayController
    public private(set) var allMessages: [MessageRecord] = []
    public private(set) var conversations: [ConversationSummary] = []
    public private(set) var messagesToday = 0
    public private(set) var conversationKeys: [ConversationKey] = []
    public var globalKey: String { gateway.settings.encryptionKey }
    public var searchQuery = "" {
        didSet { if searchQuery != oldValue { observeMessages() } }
    }
    private var messagesTask: Task<Void, Never>?
    private var tasks: [Task<Void, Never>] = []

    public init(gateway: GatewayController) {
        self.gateway = gateway
        observeMessages()
        let db = gateway.db
        tasks.append(
            Task { [weak self] in
                do {
                    for try await list in db.messages.getConversations() { self?.conversations = list }
                } catch {}
            })
        tasks.append(
            Task { [weak self] in
                do {
                    for try await n in db.messages.countSince(Self.startOfToday()) { self?.messagesToday = n }
                } catch {}
            })
        tasks.append(
            Task { [weak self] in
                do {
                    for try await keys in db.conversationKeys.getAll() { self?.conversationKeys = keys }
                } catch {}
            })
    }

    static func startOfToday() -> Int64 { Int64(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 * 1000) }

    private func observeMessages() {
        messagesTask?.cancel()
        let db = gateway.db
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        messagesTask = Task { [weak self] in
            do {
                let observation = query.isEmpty ? db.messages.getRecent(limit: 100) : db.messages.search(query, limit: 100)
                for try await list in observation { self?.allMessages = list }
            } catch {}
        }
    }

    /// The key that decrypts a peer's messages: the conversation's own, else the global one, else nil.
    public func activeKey(for peer: String) -> String? {
        if let k = conversationKeys.first(where: { $0.sender == peer })?.hexKey, !k.isEmpty { return k }
        return globalKey.isEmpty ? nil : globalKey
    }

    public func conversationKey(for peer: String) -> ConversationKey? { conversationKeys.first { $0.sender == peer } }

    public func saveConversationKey(peer: String, hexKey: String) {
        let db = gateway.db
        Task { try? await db.conversationKeys.upsert(ConversationKey(sender: peer, hexKey: hexKey, label: "")) }
    }

    public func removeConversationKey(peer: String) {
        let db = gateway.db
        Task { try? await db.conversationKeys.deleteBySender(peer) }
    }

    /// One conversation's messages, newest first, as the chat shows them.
    public func observeConversation(_ peer: String) -> AsyncStream<[MessageRecord]> {
        let observation = gateway.db.messages.getConversation(peer)
        return AsyncStream { continuation in
            let task = Task {
                do {
                    for try await list in observation { continuation.yield(list) }
                } catch {}
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
