import Foundation
import Combine

// CoreThreadSummary vive en CoreModels.swift para que la Share Extension
// pueda compilar SupabaseCoreClient sin este archivo.

/// Tracks, per thread, when the current user last viewed its replies.
/// Persisted locally so unread indicators survive app restarts.
/// Only accessed from the main thread (SwiftUI views).
final class ThreadReadTracker: ObservableObject {
    static let shared = ThreadReadTracker()

    private static let defaultsKey = "zia.threads.lastRead"
    @Published private(set) var lastRead: [String: Date]

    private init() {
        let stored = UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: Double] ?? [:]
        lastRead = stored.mapValues { Date(timeIntervalSince1970: $0) }
    }

    func markRead(_ threadId: String, at date: Date = Date()) {
        if let current = lastRead[threadId], current >= date { return }
        lastRead[threadId] = date
        persist()
    }

    /// A thread is unread when someone else replied after the last time the
    /// user opened it (or the user has never opened it).
    func isUnread(_ summary: CoreThreadSummary, currentUserId: String) -> Bool {
        guard summary.replyCount > 0 else { return false }
        guard summary.lastReplyUserId != currentUserId else { return false }
        guard let readAt = lastRead[summary.root.id] else { return true }
        return summary.lastReplyAt > readAt
    }

    private func persist() {
        let raw = lastRead.mapValues { $0.timeIntervalSince1970 }
        UserDefaults.standard.set(raw, forKey: Self.defaultsKey)
    }
}
