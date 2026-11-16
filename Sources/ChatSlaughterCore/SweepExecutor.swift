import Foundation
import Combine

@MainActor
public protocol SweepGateway: AnyObject {
    func freshPlan(chatID: Int64) async throws -> PlanItem
    func canRemoveAfterLeaving(chatID: Int64) async throws -> Bool
    func perform(_ request: [String: Any]) async throws
}

/// Serial, never replays a timed-out mutation. Stop takes effect after the current request.
@MainActor
public final class SweepExecutor: ObservableObject {
    @Published public private(set) var running = false
    @Published public private(set) var results: [SweepResult] = []
    @Published public private(set) var status = ""
    @Published public private(set) var total = 0
    @Published public private(set) var stopRequested = false
    private let gateway: SweepGateway
    private let sleep: (UInt64) async throws -> Void

    public init(gateway: SweepGateway, sleep: @escaping (UInt64) async throws -> Void = {
        try await Task.sleep(nanoseconds: $0)
    }) { self.gateway = gateway; self.sleep = sleep }

    public func stop() { stopRequested = true }

    public func run(_ plan: [PlanItem]) async {
        guard !running else { return }
        running = true; stopRequested = false; results = []; total = plan.count
        defer { running = false; status = stopRequested ? "Очередь остановлена" : "Обработка завершена" }
        for item in plan {
            if stopRequested { results.append(SweepResult(item: item, outcome: .skipped)); continue }
            status = item.chat.title
            var left = false
            do {
                let fresh = try await retry { try await self.gateway.freshPlan(chatID: item.id) }
                guard fresh.action == item.action, fresh.chat.kind == item.chat.kind else {
                    throw SweepError.blocked("Тип чата изменился; требуется новый просмотр")
                }
                guard !stopRequested else { throw CancellationError() }
                if item.action == .leave {
                    try await retry { try await self.gateway.perform(TDRequest.leave(item.id)) }
                    left = true
                    // Leaving can succeed even when removing the remaining local entry fails.
                    // Finish this chat before honoring Stop, and report any partial outcome.
                    if try await gateway.canRemoveAfterLeaving(chatID: item.id) {
                        try await gateway.perform(TDRequest.deleteForSelf(item.id))
                    }
                } else {
                    try await retry { try await self.gateway.perform(TDRequest.deleteForSelf(item.id)) }
                }
                results.append(SweepResult(item: item, outcome: .success))
            } catch is CancellationError {
                results.append(SweepResult(item: item, outcome: left ? .partial("Вышли; удаление записи не завершено") : .skipped))
                stopRequested = true
            } catch {
                results.append(SweepResult(item: item, outcome: left
                    ? .partial("Вышли; запись не удалена: \(error.localizedDescription)")
                    : .failed(error.localizedDescription)))
                // Unknown outcome or exhausted rate limit: require a new review, never advance blindly.
                if case SweepError.timeout = error { stopRequested = true }
                if (error as? SweepError)?.floodWait != nil { stopRequested = true }
            }
            if !stopRequested { try? await sleep(700_000_000) }
        }
    }

    private func retry<T>(_ operation: () async throws -> T) async throws -> T {
        for attempt in 0...2 {
            if stopRequested { throw CancellationError() }
            do { return try await operation() }
            catch {
                guard let wait = (error as? SweepError)?.floodWait, attempt < 2, wait <= 300 else { throw error }
                for remaining in stride(from: wait, through: 1, by: -1) {
                    if stopRequested { throw CancellationError() }
                    status = "Ограничение Telegram: \(remaining) с · можно остановить"
                    try await sleep(1_000_000_000)
                }
            }
        }
        throw SweepError.blocked("Повтор запроса остановлен")
    }
}
