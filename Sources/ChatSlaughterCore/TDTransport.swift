import Foundation
import Darwin

/// One receive loop owns TDLib's global JSON receiver. All application state stays on MainActor.
@MainActor
public final class TDTransport {
    private typealias Create = @convention(c) () -> Int32
    private typealias Send = @convention(c) (Int32, UnsafePointer<CChar>?) -> Void
    private typealias Receive = @convention(c) (Double) -> UnsafePointer<CChar>?
    private typealias Execute = @convention(c) (UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
    private var handle: UnsafeMutableRawPointer?
    private var sendFunction: Send?
    private var clientID: Int32 = 0
    private var pending: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var deadlines: [String: Task<Void, Never>] = [:]
    public var onUpdate: (([String: Any]) -> Void)?
    public private(set) var isClosed = true
    public private(set) var version: String?
    public private(set) var authorizationType: String?

    public init() {}

    public func start(libraryPath: String? = nil) throws {
        guard handle == nil else { throw SweepError.blocked("Клиент уже запущен") }
        let paths = [libraryPath, ProcessInfo.processInfo.environment["CHATSLAUGHTER_TDLIB_PATH"],
                     Bundle.main.privateFrameworksPath.map { $0 + "/libtdjson.dylib" },
                     "/opt/homebrew/lib/libtdjson.dylib", "/usr/local/lib/libtdjson.dylib"].compactMap { $0 }
        guard let loaded = paths.lazy.compactMap({ dlopen($0, RTLD_NOW | RTLD_LOCAL) }).first else {
            throw SweepError.unavailable("TDLib не найдена. Установите brew install tdlib или используйте сборку с библиотекой.")
        }
        func symbol<T>(_ name: String, _: T.Type) throws -> T {
            guard let pointer = dlsym(loaded, name) else { throw SweepError.unavailable("Несовместимая TDLib: \(name)") }
            return unsafeBitCast(pointer, to: T.self)
        }
        let create: Create
        let send: Send
        let receive: Receive
        do {
            create = try symbol("td_create_client_id", Create.self)
            send = try symbol("td_send", Send.self)
            receive = try symbol("td_receive", Receive.self)
            let execute = try symbol("td_execute", Execute.self)
            // No TDLib logs containing phone numbers, authorization codes, or account content.
            _ = "{\"@type\":\"setLogStream\",\"log_stream\":{\"@type\":\"logStreamEmpty\"}}".withCString { execute($0) }
        } catch { dlclose(loaded); throw error }
        // Keep the dynamic library mapped for the process lifetime: the receive loop uses its functions.
        handle = loaded; sendFunction = send; clientID = create(); isClosed = false
        let id = clientID
        DispatchQueue(label: "app.chatslaughter.tdlib.receive", qos: .utility).async { [weak self] in
            while true {
                guard let pointer = receive(0.25) else { continue }
                let data = Data(String(cString: pointer).utf8) // Copy before next td_receive.
                guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      (object["@client_id"] as? NSNumber)?.int32Value == id else { continue }
                let closed = (object["authorization_state"] as? [String: Any])?["@type"] as? String == "authorizationStateClosed"
                DispatchQueue.main.async { self?.accept(object) }
                if closed { break }
            }
        }
        // First request starts delivery of updates.
        sendRaw(["@type": "getAuthorizationState"])
    }

    public func request(_ object: [String: Any], timeout: UInt64 = 60) async throws -> [String: Any] {
        guard !isClosed else { throw SweepError.closed }
        let token = UUID().uuidString
        var payload = object; payload["@extra"] = token
        return try await withCheckedThrowingContinuation { continuation in
            pending[token] = continuation
            deadlines[token] = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: timeout * 1_000_000_000) } catch { return }
                guard let self, let waiting = self.pending.removeValue(forKey: token) else { return }
                self.deadlines.removeValue(forKey: token)
                waiting.resume(throwing: SweepError.timeout)
            }
            sendRaw(payload)
        }
    }

    private func sendRaw(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8) else { return }
        string.withCString { sendFunction?(clientID, $0) }
    }

    private func accept(_ object: [String: Any]) {
        if object["@type"] as? String == "updateOption", object["name"] as? String == "version" {
            version = (object["value"] as? [String: Any])?["value"] as? String
        }
        if object["@type"] as? String == "updateAuthorizationState" {
            authorizationType = (object["authorization_state"] as? [String: Any])?["@type"] as? String
        }
        if let token = object["@extra"] as? String, let waiting = pending.removeValue(forKey: token) {
            deadlines.removeValue(forKey: token)?.cancel()
            if object["@type"] as? String == "error" {
                waiting.resume(throwing: SweepError.telegram(object["code"] as? Int ?? 0, object["message"] as? String ?? "Unknown"))
            } else { waiting.resume(returning: object) }
        }
        onUpdate?(object)
        if (object["authorization_state"] as? [String: Any])?["@type"] as? String == "authorizationStateClosed" {
            isClosed = true
            let waiting = pending; pending.removeAll()
            deadlines.values.forEach { $0.cancel() }; deadlines.removeAll()
            waiting.values.forEach { $0.resume(throwing: SweepError.closed) }
        }
    }

    public func close() async {
        guard !isClosed else { return }
        sendRaw(["@type": "close"])
        // Do not tear down the receive thread before authorizationStateClosed.
        while !isClosed { try? await Task.sleep(nanoseconds: 100_000_000) }
    }
}
