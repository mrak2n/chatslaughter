import Foundation
import Testing
@testable import ChatSlaughterCore

struct PolicyTests {
    @Test
    func testSavedMessagesAreProtected() {
        #expect(throws: (any Error).self) { try SweepPolicy.plan(Chat(id: 1, title: "Saved", kind: .person, isSavedMessages: true)) }
    }
    @Test
    func testSecretChatsAreProtected() {
        #expect(throws: (any Error).self) { try SweepPolicy.plan(Chat(id: 1, title: "Secret", kind: .secret)) }
    }
    @Test
    func testOwnerCannotLeaveThroughBulkOperation() {
        for kind in [ChatKind.group, .channel] {
            #expect(throws: (any Error).self) { try SweepPolicy.plan(Chat(id: 2, title: "Owned", kind: kind), membership: "chatMemberStatusCreator") }
        }
    }
    @Test
    func testUnknownMembershipIsBlocked() {
        let chat = Chat(id: 2, title: "Group", kind: .group)
        #expect(throws: (any Error).self) { try SweepPolicy.plan(chat) }
        #expect(throws: (any Error).self) { try SweepPolicy.plan(chat, membership: "futureStatus") }
    }
    @Test
    func testPrivateChatRequiresSelfDeleteCapability() {
        #expect(throws: (any Error).self) { try SweepPolicy.plan(Chat(id: 1, title: "Private", kind: .person, canDeleteForSelf: false)) }
    }
    @Test
    func testActionsMatchChatTypes() throws {
        #expect(try SweepPolicy.plan(Chat(id: 1, title: "Person", kind: .person)).action == .deleteForSelf)
        #expect(try SweepPolicy.plan(Chat(id: 2, title: "Channel", kind: .channel), membership: "chatMemberStatusMember").action == .leave)
    }
    @Test
    func testDeleteRequestNeverRevokesForOtherUser() {
        let request = TDRequest.deleteForSelf(123)
        #expect(request["@type"] as? String == "deleteChatHistory")
        #expect(request["chat_id"] as? Int64 == 123)
        #expect(request["revoke"] as? Bool == false)
        #expect(request["remove_from_chat_list"] as? Bool == true)
    }
    @Test
    func testFloodWaitFormatsAndHiddenErrors() {
        #expect(SweepError.telegram(429, "Too Many Requests: retry after 12").floodWait == 12)
        #expect(SweepError.telegram(429, "FLOOD_WAIT_42").floodWait == 42)
        #expect(SweepError.telegram(400, "FLOOD_WAIT_42").floodWait == nil)
        #expect(!(SweepError.telegram(406, "sensitive").localizedDescription.contains("sensitive")))
    }
}

@MainActor
private final class FakeGateway: SweepGateway {
    var calls: [String] = []
    var plans: [Int64: PlanItem] = [:]
    var errors: [String: [SweepError]] = [:]
    var afterPerform: (() -> Void)?
    func freshPlan(chatID: Int64) async throws -> PlanItem {
        guard let plan = plans[chatID] else { throw SweepError.blocked("Missing") }
        return plan
    }
    func canRemoveAfterLeaving(chatID: Int64) async throws -> Bool { true }
    func perform(_ request: [String: Any]) async throws {
        let name = request["@type"] as! String
        calls.append(name)
        if var pending = errors[name], !pending.isEmpty {
            let error = pending.removeFirst(); errors[name] = pending; throw error
        }
        afterPerform?()
    }
}

struct QueueTests {
    @MainActor
    private func fixture() -> (FakeGateway, [PlanItem]) {
        let api = FakeGateway()
        let items = [1, 2, 3].map { PlanItem(chat: Chat(id: Int64($0), title: "Chat \($0)", kind: .person), action: .deleteForSelf) }
        api.plans = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        return (api, items)
    }
    @Test
    @MainActor
    func testSerialQueueCompletesEveryItem() async {
        let (api, items) = fixture()
        let queue = SweepExecutor(gateway: api, sleep: { _ in })
        await queue.run(items)
        #expect(queue.results.map(\.id) == [1, 2, 3])
        #expect(queue.results.allSatisfy { $0.outcome == .success })
        #expect(!(queue.running))
    }
    @Test
    @MainActor
    func testStopDoesNotSendNextMutation() async {
        let (api, items) = fixture()
        let queue = SweepExecutor(gateway: api, sleep: { _ in })
        api.afterPerform = { queue.stop() }
        await queue.run(items)
        #expect(api.calls.count == 1)
        #expect(queue.results.map(\.outcome) == [.success, .skipped, .skipped])
    }
    @Test
    @MainActor
    func testTimedOutMutationIsNeverReplayedAndStopsQueue() async {
        let (api, items) = fixture()
        api.errors["deleteChatHistory"] = [.timeout]
        let queue = SweepExecutor(gateway: api, sleep: { _ in })
        await queue.run(items)
        #expect(api.calls.count == 1)
        #expect(queue.results.last?.outcome == .skipped)
        #expect(queue.stopRequested)
    }
    @Test
    @MainActor
    func testExplicitRateLimitCanRetry() async {
        let (api, items) = fixture()
        api.errors["deleteChatHistory"] = [.telegram(429, "FLOOD_WAIT_1")]
        let queue = SweepExecutor(gateway: api, sleep: { _ in })
        await queue.run([items[0]])
        #expect(api.calls.count == 2)
        #expect(queue.results[0].outcome == .success)
    }
    @Test
    @MainActor
    func testStopInterruptsFloodWait() async {
        let (api, items) = fixture()
        api.errors["deleteChatHistory"] = [.telegram(429, "FLOOD_WAIT_10")]
        var queue: SweepExecutor!
        queue = SweepExecutor(gateway: api, sleep: { _ in queue.stop() })
        await queue.run(items)
        #expect(api.calls.count == 1)
        #expect(queue.results.allSatisfy { $0.outcome == .skipped })
    }
    @Test
    @MainActor
    func testChangedChatTypeRequiresNewReview() async {
        let (api, items) = fixture()
        api.plans[1] = PlanItem(chat: Chat(id: 1, title: "Changed", kind: .channel), action: .leave)
        let queue = SweepExecutor(gateway: api, sleep: { _ in })
        await queue.run([items[0]])
        #expect(api.calls.isEmpty)
        if case .failed = queue.results[0].outcome {} else { Issue.record("Expected blocked action") }
    }
    @Test
    @MainActor
    func testLeaveSucceedsButRemovalFailureIsReportedAsPartial() async throws {
        let api = FakeGateway()
        let item = try SweepPolicy.plan(Chat(id: 8, title: "Group", kind: .group), membership: "chatMemberStatusMember")
        api.plans[8] = item
        api.errors["deleteChatHistory"] = [.telegram(400, "cannot delete")]
        let queue = SweepExecutor(gateway: api, sleep: { _ in })
        await queue.run([item])
        #expect(api.calls == ["leaveChat", "deleteChatHistory"])
        if case .partial = queue.results[0].outcome {} else { Issue.record("Expected partial outcome") }
    }
    @Test
    @MainActor
    func testLongRateLimitStopsWithoutSleepingOrReplaying() async {
        let (api, items) = fixture()
        api.errors["deleteChatHistory"] = [.telegram(429, "FLOOD_WAIT_3600")]
        let queue = SweepExecutor(gateway: api, sleep: { _ in Issue.record("Unexpected wait") })
        await queue.run(items)
        #expect(api.calls.count == 1)
        #expect(queue.stopRequested)
    }
}

@Suite(.serialized)
struct TDLibLifecycleTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CHATSLAUGHTER_TEST_TDLIB"] == "1"))
    @MainActor
    func testInstalledLibraryStartsAnswersAndCloses() async throws {
        let transport = TDTransport()
        try transport.start()
        for _ in 0..<500 {
            if transport.version != nil && transport.authorizationType != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(!(transport.version ?? "").isEmpty)
        #expect(transport.authorizationType == "authorizationStateWaitTdlibParameters")
        let response = try await transport.request(["@type": "getLogVerbosityLevel"], timeout: 5)
        #expect(response["@type"] as? String == "logVerbosityLevel")
        await transport.close()
        #expect(transport.isClosed)
    }
}
