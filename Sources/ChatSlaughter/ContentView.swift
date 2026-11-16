import SwiftUI
import ChatSlaughterCore

private enum Scope: String, CaseIterable, Identifiable {
    case all, person, bot, group, channel, archive
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "Все чаты"
        case .archive: return "Архив"
        default: return ChatKind(rawValue: rawValue)?.title ?? rawValue
        }
    }
    var symbol: String {
        switch self {
        case .all: return "bubble.left.and.bubble.right"
        case .archive: return "archivebox"
        default: return ChatKind(rawValue: rawValue)?.symbol ?? "bubble.left"
        }
    }
    func includes(_ chat: Chat) -> Bool {
        switch self {
        case .all: return true
        case .archive: return chat.archived
        default: return chat.kind.rawValue == rawValue
        }
    }
}

struct ContentView: View {
    @ObservedObject var client: TelegramClient
    @ObservedObject var executor: SweepExecutor
    @State private var scope: Scope? = .all
    @State private var query = ""
    @State private var selected: Set<Int64> = []
    @State private var plan: [PlanItem] = []
    @State private var blocked: [String] = []
    @State private var reviewing = false
    @State private var reviewPresented = false
    @State private var resultsPresented = false
    @State private var accepted = false
    @State private var olderOnly = false

    private var visible: [Chat] {
        client.chats.filter { chat in
            (scope ?? .all).includes(chat)
            && (query.isEmpty || chat.title.localizedCaseInsensitiveContains(query))
            && (!olderOnly || (chat.lastActivity.map { $0 < Date(timeIntervalSinceNow: -90 * 86400) } ?? false))
        }
    }
    private var selectableIDs: Set<Int64> { Set(visible.filter { $0.protectionReason == nil }.map(\.id)) }
    private var busy: Bool { executor.running || reviewing }

    var body: some View {
        Group {
            if client.auth == .ready { workspace }
            else { LoginView(client: client) }
        }
        .alert("Не удалось выполнить действие", isPresented: Binding(
            get: { client.errorMessage != nil }, set: { if !$0 { client.errorMessage = nil } }
        )) { Button("OK") { client.errorMessage = nil } }
        message: { Text(client.errorMessage ?? "") }
        .sheet(isPresented: $reviewPresented) { reviewSheet }
        .sheet(isPresented: $resultsPresented) { resultsSheet }
    }

    private var workspace: some View {
        NavigationSplitView {
            List(selection: $scope) {
                Section("Библиотека") {
                    ForEach(Scope.allCases) { item in
                        Label {
                            HStack {
                                Text(item.title)
                                Spacer()
                                Text("\(client.chats.filter { item.includes($0) }.count)")
                                    .foregroundStyle(.secondary).monospacedDigit()
                            }
                        } icon: { Image(systemName: item.symbol) }
                        .tag(item)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    if client.demo {
                        Label("Демонстрация", systemImage: "play.rectangle").font(.caption)
                        Button("Подключить аккаунт") { selected = []; client.exitDemo() }.disabled(busy)
                    } else {
                        Text(client.accountName).font(.callout).lineLimit(1)
                        Label(client.connection, systemImage: "network").font(.caption).foregroundStyle(.secondary)
                        Button("Завершить сессию", role: .destructive) { Task { await client.logout() } }.disabled(busy)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding()
            }
            .disabled(busy)
        } detail: {
            VStack(spacing: 0) {
                if client.demo {
                    HStack {
                        Image(systemName: "play.rectangle")
                        Text("Демо: вымышленные чаты. Действия не затрагивают Telegram.")
                        Spacer()
                    }
                    .font(.callout).padding(10).background(.quaternary)
                }
                Table(visible, selection: $selected) {
                    TableColumn("Чат") { chat in
                        HStack(spacing: 10) {
                            Image(systemName: chat.kind.symbol).foregroundStyle(.secondary).frame(width: 22)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(chat.title).lineLimit(1)
                                if let reason = chat.protectionReason {
                                    Text(reason).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            if chat.pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary) }
                        }.padding(.vertical, 4)
                    }.width(min: 220, ideal: 300)
                    TableColumn("Тип") { chat in Text(chat.kind.title).foregroundStyle(.secondary) }.width(80)
                    TableColumn("Активность") { chat in
                        if let date = chat.lastActivity { Text(date, format: .dateTime.day().month(.abbreviated).year()) }
                        else { Text("—").foregroundStyle(.tertiary) }
                    }.width(115)
                    TableColumn("Архив") { chat in
                        if chat.archived { Image(systemName: "archivebox").foregroundStyle(.secondary) }
                    }.width(45)
                }
                .disabled(busy)
                .overlay {
                    if visible.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: client.loading ? "arrow.down.circle" : "magnifyingglass").font(.largeTitle)
                            Text(client.loading ? "Загрузка чатов…" : "Нет чатов по выбранным условиям")
                        }.foregroundStyle(.secondary)
                    }
                }
                Divider()
                HStack(spacing: 12) {
                    if executor.running {
                        ProgressView(value: Double(executor.results.count), total: Double(max(executor.total, 1))).frame(width: 100)
                        Text("\(executor.results.count)/\(executor.total) · \(executor.status)").lineLimit(1)
                        Spacer()
                        Button(executor.stopRequested ? "Остановка…" : "Остановить") { executor.stop() }.disabled(executor.stopRequested)
                    } else {
                        Text("\(visible.count) чатов · выбрано \(selected.count)").foregroundStyle(.secondary)
                        Spacer()
                        if !executor.results.isEmpty {
                            Button("Результаты") { resultsPresented = true }
                        }
                        Button(reviewing ? "Проверка…" : "Просмотреть действия…") { Task { await prepareReview() } }
                            .disabled(selected.isEmpty || reviewing || client.loading)
                            .keyboardShortcut(.return, modifiers: .command)
                    }
                }.font(.callout).padding(12)
            }
            .navigationTitle((scope ?? .all).title)
            .searchable(text: $query, prompt: "Найти чат")
            .toolbar {
                ToolbarItemGroup {
                    Toggle(isOn: $olderOnly) { Label("Старше 90 дней", systemImage: "clock") }
                        .help("Показать чаты без сообщений за последние 90 дней").disabled(busy)
                    Button { selected = selectableIDs } label: { Label("Выбрать видимые", systemImage: "checkmark.circle") }
                        .help("Выбрать все доступные чаты по текущему фильтру")
                        .keyboardShortcut("a", modifiers: .command).disabled(busy)
                    Button { selected = [] } label: { Label("Снять выбор", systemImage: "circle") }.disabled(busy || selected.isEmpty)
                    Button { Task { await client.reload() } } label: { Label("Обновить", systemImage: "arrow.clockwise") }
                        .keyboardShortcut("r", modifiers: .command).disabled(busy || client.loading || client.demo)
                }
            }
            .onChange(of: query) { _ in selected.formIntersection(selectableIDs) }
            .onChange(of: scope) { _ in selected.formIntersection(selectableIDs) }
            .onChange(of: olderOnly) { _ in selected.formIntersection(selectableIDs) }
            .onChange(of: selected) { _ in selected.formIntersection(selectableIDs) }
            .onChange(of: client.chats) { _ in selected.formIntersection(selectableIDs) }
        }
    }

    private func prepareReview() async {
        guard !busy else { return }
        reviewing = true; accepted = false; plan = []; blocked = []
        let snapshot = visible.filter { selected.contains($0.id) }
        for chat in snapshot {
            do { plan.append(try await client.freshPlan(chatID: chat.id)) }
            catch { blocked.append("\(chat.title): \(error.localizedDescription)") }
        }
        reviewing = false; reviewPresented = true
    }

    private var reviewSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(client.demo ? "Проверить демо-действия" : "Проверить действия").font(.title2).bold()
            Text("Личные чаты удаляются только у вас. Выход из группы или канала прекращает участие; для возврата может потребоваться приглашение.")
                .foregroundStyle(.secondary)
            List {
                ForEach(plan) { item in
                    HStack {
                        Label(item.chat.title, systemImage: item.chat.kind.symbol)
                        Spacer()
                        Text(item.action == .leave ? "Выйти из чата" : "Удалить только у меня")
                            .foregroundStyle(.secondary).font(.callout)
                    }
                }
                if !blocked.isEmpty {
                    Section("Пропущены") {
                        ForEach(Array(blocked.enumerated()), id: \.offset) { _, reason in Text(reason).font(.callout).foregroundStyle(.secondary) }
                    }
                }
            }.frame(minHeight: 150, maxHeight: 310)
            Toggle("Понимаю, что выполненное удаление нельзя отменить", isOn: $accepted)
            HStack {
                Text("\(plan.count) действий").foregroundStyle(.secondary)
                Spacer()
                Button("Отмена") { reviewPresented = false }.keyboardShortcut(.cancelAction)
                Button(client.demo ? "Запустить демо" : "Выполнить \(plan.count) действий", role: .destructive) {
                    let snapshot = plan
                    reviewPresented = false; selected = []
                    Task { await executor.run(snapshot); resultsPresented = true }
                }.disabled(!accepted || plan.isEmpty)
            }
        }.padding(24).frame(width: 690)
    }

    private var resultsSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(client.demo ? "Результаты демонстрации" : "Результаты обработки").font(.title2).bold()
            Text(executor.status).foregroundStyle(.secondary)
            List(executor.results) { result in
                HStack(alignment: .top) {
                    Image(systemName: result.outcome == .success ? "checkmark.circle" : "info.circle")
                        .foregroundStyle(result.outcome == .success ? Color.green : Color.secondary)
                    Text(result.title).frame(width: 210, alignment: .leading)
                    Text(result.outcome.title).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }.frame(height: 300)
            Text("Остановка отменяет оставшуюся очередь. Уже выполненные действия сохраняются.").font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Готово") { resultsPresented = false }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 690)
    }
}
