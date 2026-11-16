import Foundation

public enum ChatKind: String, CaseIterable, Codable, Identifiable {
    case person, bot, group, channel, secret
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .person: return "Личные"
        case .bot: return "Боты"
        case .group: return "Группы"
        case .channel: return "Каналы"
        case .secret: return "Секретные"
        }
    }
    public var symbol: String {
        switch self {
        case .person: return "person"
        case .bot: return "command"
        case .group: return "person.2"
        case .channel: return "megaphone"
        case .secret: return "lock"
        }
    }
}

public struct Chat: Identifiable, Hashable {
    public let id: Int64
    public var title: String
    public var kind: ChatKind
    public var peerID: Int64
    public var lastActivity: Date?
    public var archived: Bool
    public var pinned: Bool
    public var unread: Int
    public var canDeleteForSelf: Bool
    public var isSavedMessages: Bool

    public init(id: Int64, title: String, kind: ChatKind, peerID: Int64 = 0,
                lastActivity: Date? = nil, archived: Bool = false, pinned: Bool = false,
                unread: Int = 0, canDeleteForSelf: Bool = true, isSavedMessages: Bool = false) {
        self.id = id; self.title = title; self.kind = kind; self.peerID = peerID
        self.lastActivity = lastActivity; self.archived = archived; self.pinned = pinned
        self.unread = unread; self.canDeleteForSelf = canDeleteForSelf
        self.isSavedMessages = isSavedMessages
    }

    public var protectionReason: String? {
        if isSavedMessages { return "Избранное защищено" }
        if kind == .secret { return "Секретные чаты не поддерживаются" }
        if (kind == .person || kind == .bot) && !canDeleteForSelf { return "Удаление недоступно" }
        return nil
    }
}

public enum SweepAction: String {
    case deleteForSelf, leave
    public var title: String {
        self == .deleteForSelf ? "Удалить только у меня" : "Выйти из группы / канала"
    }
}

public struct PlanItem: Identifiable {
    public let chat: Chat
    public let action: SweepAction
    public var id: Int64 { chat.id }
    public init(chat: Chat, action: SweepAction) { self.chat = chat; self.action = action }
}

public enum SweepPolicy {
    /// Membership is fetched again immediately before executing a leave operation.
    public static func plan(_ chat: Chat, membership: String? = nil) throws -> PlanItem {
        if let reason = chat.protectionReason { throw SweepError.blocked(reason) }
        if chat.kind == .group || chat.kind == .channel {
            guard let membership else { throw SweepError.blocked("Не удалось проверить роль в чате") }
            guard membership != "chatMemberStatusCreator" else {
                throw SweepError.blocked("Вы владелец чата: передайте права через Telegram")
            }
            guard ["chatMemberStatusMember", "chatMemberStatusAdministrator", "chatMemberStatusRestricted",
                   "chatMemberStatusLeft", "chatMemberStatusBanned"].contains(membership) else {
                throw SweepError.blocked("Неизвестная роль в чате")
            }
            return PlanItem(chat: chat, action: .leave)
        }
        return PlanItem(chat: chat, action: .deleteForSelf)
    }
}

public enum SweepError: LocalizedError {
    case blocked(String), unavailable(String), timeout, closed, telegram(Int, String)
    public var errorDescription: String? {
        switch self {
        case .blocked(let s), .unavailable(let s): return s
        case .timeout: return "Ответ не получен. Результат операции неизвестен; проверьте чат в Telegram."
        case .closed: return "Соединение закрыто"
        case .telegram(let code, let message):
            return code == 406 ? "Telegram отклонил запрос" : "Telegram: \(message) (\(code))"
        }
    }
    public var floodWait: Int? {
        guard case .telegram(let code, let message) = self, code == 429 else { return nil }
        // TDLib has used both FLOOD_WAIT_N and "Too Many Requests: retry after N".
        let digits = message.split(whereSeparator: { !$0.isNumber }).last.flatMap { Int($0) }
        return digits.flatMap { $0 > 0 ? $0 : nil }
    }
}

public struct SweepResult: Identifiable {
    public enum Outcome: Equatable {
        case success, failed(String), partial(String), skipped
        public var title: String {
            switch self {
            case .success: return "Готово"
            case .failed(let s): return s
            case .partial(let s): return s
            case .skipped: return "Пропущено"
            }
        }
    }
    public let id: Int64
    public let title: String
    public let outcome: Outcome
    public init(item: PlanItem, outcome: Outcome) {
        id = item.id; title = item.chat.title; self.outcome = outcome
    }
}

public enum TDRequest {
    public static func deleteForSelf(_ chatID: Int64) -> [String: Any] {
        ["@type": "deleteChatHistory", "chat_id": chatID, "remove_from_chat_list": true, "revoke": false]
    }
    public static func leave(_ chatID: Int64) -> [String: Any] {
        ["@type": "leaveChat", "chat_id": chatID]
    }
}
