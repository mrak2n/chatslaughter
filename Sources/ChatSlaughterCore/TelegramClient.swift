import Foundation
import Combine

public enum AuthStep: Equatable {
    case setup, connecting, phone, code, password(String), email, emailCode, ready, unsupported(String), closed
}

@MainActor
public final class TelegramClient: ObservableObject, SweepGateway {
    @Published public private(set) var auth: AuthStep = .setup
    @Published public private(set) var chats: [Chat] = []
    @Published public private(set) var loading = false
    @Published public var errorMessage: String?
    @Published public private(set) var demo = false
    @Published public private(set) var connection = "Не подключено"
    @Published public private(set) var accountName = ""
    public private(set) var transport: TDTransport?
    private var rawChats: [Int64: [String: Any]] = [:]
    private var users: [Int64: [String: Any]] = [:]
    private var meID: Int64?
    private var apiID = 0
    private var apiHash = ""
    private var encryptionKey = Data()
    private var legacy = false
    private var parametersSent = false
    private var publishTask: Task<Void, Never>?
    private var connecting = false

    public init() {}

    public func connect(apiID: String, apiHash: String) async {
        guard transport == nil, !connecting else { return }
        connecting = true
        defer { connecting = false }
        guard let id = Int(apiID), id > 0, id <= Int(Int32.max),
              apiHash.count == 32, apiHash.allSatisfy({ $0.isHexDigit }) else {
            errorMessage = "Введите числовой API ID и API Hash из 32 шестнадцатеричных символов"; return
        }
        demo = false; rawChats = [:]; users = [:]; chats = []; errorMessage = nil
        self.apiID = id; self.apiHash = apiHash; auth = .connecting
        do {
            encryptionKey = try Keychain.databaseKey()
            let credentials = try JSONSerialization.data(withJSONObject: ["api_id": apiID, "api_hash": apiHash])
            try Keychain.write(credentials, account: "api")
            let client = TDTransport()
            client.onUpdate = { [weak self] in self?.update($0) }
            try client.start(); transport = client
            // Old TDLib queues getOption until parameters are supplied. The initial
            // updateOption carries version before authorization on both supported schemas.
            for _ in 0..<500 {
                if client.version != nil { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            guard let version = client.version else { throw SweepError.timeout }
            legacy = version == "1.8.0"
            // getAuthorizationState can arrive before version. Initialization starts only here.
            try await initialize()
        } catch {
            errorMessage = error.localizedDescription
            if transport == nil { auth = .setup }
            else { auth = .unsupported("Не удалось инициализировать TDLib. Перезапустите приложение после устранения ошибки.") }
        }
    }

    public func storedCredentials() -> (String, String) {
        guard let data = try? Keychain.read("api"),
              let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] else { return ("", "") }
        return (value["api_id"] ?? "", value["api_hash"] ?? "")
    }

    private func initialize() async throws {
        guard !parametersSent, let transport else { return }
        parametersSent = true
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true).appendingPathComponent("ChatSlaughter/tdlib")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        var parameters: [String: Any] = [
            "use_test_dc": false, "database_directory": root.path,
            "files_directory": root.appendingPathComponent("files").path,
            "use_file_database": false, "use_chat_info_database": true,
            "use_message_database": false, "use_secret_chats": false,
            "api_id": apiID, "api_hash": apiHash, "system_language_code": "ru",
            "device_model": "Mac", "system_version": ProcessInfo.processInfo.operatingSystemVersionString,
            "application_version": "0.1.0"
        ]
        if legacy {
            parameters["@type"] = "tdlibParameters"; parameters["enable_storage_optimizer"] = true
            _ = try await transport.request(["@type": "setTdlibParameters", "parameters": parameters])
        } else {
            parameters["@type"] = "setTdlibParameters"
            parameters["database_encryption_key"] = encryptionKey.base64EncodedString()
            _ = try await transport.request(parameters)
        }
    }

    public func submit(_ value: String) async {
        guard let transport else { return }
        var request: [String: Any]
        switch auth {
        case .phone: request = ["@type": "setAuthenticationPhoneNumber", "phone_number": value]
        case .code: request = ["@type": "checkAuthenticationCode", "code": value]
        case .password: request = ["@type": "checkAuthenticationPassword", "password": value]
        case .email: request = ["@type": "setAuthenticationEmailAddress", "email_address": value]
        case .emailCode: request = ["@type": "checkAuthenticationEmailCode", "code": ["@type": "emailAddressAuthenticationCode", "code": value]]
        default: return
        }
        errorMessage = nil
        do { _ = try await transport.request(request) }
        catch { errorMessage = error.localizedDescription }
    }

    private func update(_ object: [String: Any]) {
        switch object["@type"] as? String {
        case "updateAuthorizationState":
            guard let state = object["authorization_state"] as? [String: Any] else { return }
            switch state["@type"] as? String {
            case "authorizationStateWaitTdlibParameters": break // connect() owns initialization
            case "authorizationStateWaitEncryptionKey":
                Task { await self.report { _ = try await self.transport?.request([
                    "@type": "checkDatabaseEncryptionKey", "encryption_key": self.encryptionKey.base64EncodedString()]) } }
            case "authorizationStateWaitPhoneNumber": auth = .phone
            case "authorizationStateWaitCode": auth = .code
            case "authorizationStateWaitPassword": auth = .password(state["password_hint"] as? String ?? "")
            case "authorizationStateWaitEmailAddress": auth = .email
            case "authorizationStateWaitEmailCode": auth = .emailCode
            case "authorizationStateReady":
                auth = .ready
                Task { await self.report {
                    let me = try await self.transport?.request(["@type": "getMe"])
                    self.meID = (me?["id"] as? NSNumber)?.int64Value
                    self.accountName = [me?["first_name"] as? String, me?["last_name"] as? String].compactMap { $0 }.joined(separator: " ")
                    await self.reload()
                } }
            case "authorizationStateClosing", "authorizationStateLoggingOut": connection = "Закрытие сессии…"
            case "authorizationStateClosed": auth = .closed; connection = "Сессия закрыта"
            default: auth = .unsupported("Этот способ входа не поддерживается. Войдите в существующий аккаунт через официальный Telegram и повторите попытку.")
            }
        case "updateConnectionState":
            let state = (object["state"] as? [String: Any])?["@type"] as? String
            connection = state == "connectionStateReady" ? "Подключено" : "Подключение…"
        case "updateUser":
            if let user = object["user"] as? [String: Any], let id = (user["id"] as? NSNumber)?.int64Value {
                users[id] = user; schedulePublish()
            }
        case "updateNewChat":
            if let chat = object["chat"] as? [String: Any], let id = (chat["id"] as? NSNumber)?.int64Value {
                rawChats[id] = chat; schedulePublish()
            }
        case "updateChatPosition", "updateChatLastMessage", "updateChatDraftMessage":
            guard let id = (object["chat_id"] as? NSNumber)?.int64Value, var chat = rawChats[id] else { return }
            if let position = object["position"] as? [String: Any] {
                var positions = chat["positions"] as? [[String: Any]] ?? []
                let list = (position["list"] as? [String: Any])?["@type"] as? String
                positions.removeAll { ($0["list"] as? [String: Any])?["@type"] as? String == list }
                if order(position) != 0 { positions.append(position) }; chat["positions"] = positions
            }
            if let positions = object["positions"] { chat["positions"] = positions }
            if object["@type"] as? String == "updateChatLastMessage" { chat["last_message"] = object["last_message"] }
            rawChats[id] = chat; schedulePublish()
        case "updateChatTitle", "updateChatReadInbox":
            guard let id = (object["chat_id"] as? NSNumber)?.int64Value else { return }
            if let title = object["title"] { rawChats[id]?["title"] = title }
            if let count = object["unread_count"] { rawChats[id]?["unread_count"] = count }
            schedulePublish()
        default: break
        }
    }

    private func report(_ work: () async throws -> Void) async {
        do { try await work() } catch { errorMessage = error.localizedDescription }
    }

    public func reload() async {
        guard !loading, !demo, let transport, auth == .ready else { return }
        loading = true; defer { loading = false; publish() }
        do {
            for list in ["chatListMain", "chatListArchive"] {
                while true {
                    do { _ = try await transport.request(["@type": "loadChats", "chat_list": ["@type": list], "limit": 100]) }
                    catch SweepError.telegram(404, _) { break } // All chats loaded; no arbitrary 100-chat cap.
                }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    private func order(_ position: [String: Any]) -> Int64 {
        if let string = position["order"] as? String { return Int64(string) ?? 0 }
        return (position["order"] as? NSNumber)?.int64Value ?? 0
    }

    private func decode(_ value: [String: Any]) throws -> Chat {
        guard let id = (value["id"] as? NSNumber)?.int64Value,
              let type = value["type"] as? [String: Any] else { throw SweepError.blocked("Некорректные данные чата") }
        let kind: ChatKind; let peer: Int64
        switch type["@type"] as? String {
        case "chatTypePrivate":
            peer = (type["user_id"] as? NSNumber)?.int64Value ?? 0
            kind = (users[peer]?["type"] as? [String: Any])?["@type"] as? String == "userTypeBot" ? .bot : .person
        case "chatTypeBasicGroup": kind = .group; peer = (type["basic_group_id"] as? NSNumber)?.int64Value ?? 0
        case "chatTypeSupergroup":
            kind = type["is_channel"] as? Bool == true ? .channel : .group
            peer = (type["supergroup_id"] as? NSNumber)?.int64Value ?? 0
        default: kind = .secret; peer = 0
        }
        let positions = value["positions"] as? [[String: Any]] ?? []
        let timestamp = (value["last_message"] as? [String: Any])?["date"] as? Double
        return Chat(id: id, title: value["title"] as? String ?? "Без названия", kind: kind, peerID: peer,
                    lastActivity: timestamp.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil },
                    archived: positions.contains { ($0["list"] as? [String: Any])?["@type"] as? String == "chatListArchive" && order($0) != 0 },
                    pinned: positions.contains { $0["is_pinned"] as? Bool == true },
                    unread: value["unread_count"] as? Int ?? 0,
                    canDeleteForSelf: value["can_be_deleted_only_for_self"] as? Bool ?? false,
                    isSavedMessages: kind == .person && (meID == nil || peer == meID))
    }

    private func schedulePublish() {
        guard publishTask == nil else { return }
        publishTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            self?.publishTask = nil; self?.publish()
        }
    }

    private func publish() {
        guard !demo else { return }
        chats = rawChats.values.filter { value in
            (value["positions"] as? [[String: Any]] ?? []).contains { order($0) != 0 }
        }.compactMap { try? decode($0) }.sorted {
            ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast)
        }
    }

    public func freshPlan(chatID: Int64) async throws -> PlanItem {
        if demo {
            guard let chat = chats.first(where: { $0.id == chatID }) else { throw SweepError.blocked("Чат не найден") }
            return try SweepPolicy.plan(chat, membership: "chatMemberStatusMember")
        }
        guard let transport, auth == .ready else { throw SweepError.closed }
        let raw = try await transport.request(["@type": "getChat", "chat_id": chatID])
        let chat = try decode(raw)
        var membership: String?
        if chat.kind == .group || chat.kind == .channel {
            guard let meID else { throw SweepError.blocked("Аккаунт ещё не определён") }
            let member = try await transport.request(["@type": "getChatMember", "chat_id": chatID,
                "member_id": ["@type": "messageSenderUser", "user_id": meID]])
            membership = (member["status"] as? [String: Any])?["@type"] as? String
        }
        return try SweepPolicy.plan(chat, membership: membership)
    }

    public func canRemoveAfterLeaving(chatID: Int64) async throws -> Bool {
        if demo { return true }
        guard let transport, auth == .ready else { throw SweepError.closed }
        let raw = try await transport.request(["@type": "getChat", "chat_id": chatID])
        return raw["can_be_deleted_only_for_self"] as? Bool == true
    }

    public func perform(_ request: [String: Any]) async throws {
        guard ["deleteChatHistory", "leaveChat"].contains(request["@type"] as? String ?? "") else {
            throw SweepError.blocked("Недопустимая операция")
        }
        if request["@type"] as? String == "deleteChatHistory", request["revoke"] as? Bool != false {
            throw SweepError.blocked("Удаление у собеседника запрещено")
        }
        if demo {
            try await Task.sleep(nanoseconds: 150_000_000)
            if let id = (request["chat_id"] as? NSNumber)?.int64Value,
               request["@type"] as? String == "deleteChatHistory" { chats.removeAll { $0.id == id } }
            return
        }
        guard auth == .ready, let transport else { throw SweepError.closed }
        _ = try await transport.request(request)
    }

    public func showDemo() {
        guard transport == nil else { return }
        demo = true; auth = .ready; connection = "Демо · без подключения к Telegram"
        chats = [
            Chat(id: 1, title: "Избранное", kind: .person, pinned: true, isSavedMessages: true),
            Chat(id: 2, title: "Александр", kind: .person, lastActivity: Date(), unread: 2),
            Chat(id: 3, title: "Design Community", kind: .group, lastActivity: Date(timeIntervalSinceNow: -86400)),
            Chat(id: 4, title: "Старый бот уведомлений", kind: .bot, lastActivity: Date(timeIntervalSinceNow: -86400 * 180)),
            Chat(id: 5, title: "Новости разработки", kind: .channel, lastActivity: Date(timeIntervalSinceNow: -86400 * 5)),
            Chat(id: 6, title: "Архив проекта 2024", kind: .group, lastActivity: Date(timeIntervalSinceNow: -86400 * 365), archived: true),
            Chat(id: 7, title: "Тестовый бот", kind: .bot, lastActivity: Date(timeIntervalSinceNow: -86400 * 90))
        ]
    }

    public func exitDemo() { guard demo else { return }; demo = false; chats = []; auth = .setup; connection = "Не подключено" }
    public func logout() async {
        guard let transport else { return }
        await report { _ = try await transport.request(["@type": "logOut"]) }
    }
    public func shutdown() async { await transport?.close() }
}
