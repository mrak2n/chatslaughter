import SwiftUI
import ChatSlaughterCore

struct LoginView: View {
    @ObservedObject var client: TelegramClient
    @State private var apiID = ""
    @State private var apiHash = ""
    @State private var value = ""
    @State private var submitting = false

    private var heading: String {
        switch client.auth {
        case .setup: return "Подключить Telegram"
        case .phone: return "Номер телефона"
        case .code: return "Код из Telegram или SMS"
        case .password: return "Облачный пароль"
        case .email: return "Адрес электронной почты"
        case .emailCode: return "Код из письма"
        case .closed: return "Сессия завершена"
        case .unsupported: return "Вход приостановлен"
        default: return "Подключение…"
        }
    }
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "bubble.left.and.text.bubble.right").font(.system(size: 44, weight: .light)).foregroundStyle(.secondary)
            VStack(spacing: 8) {
                Text("chatslaughter").font(.largeTitle).fontWeight(.semibold)
                Text("Массовая очистка чатов").foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 14) {
                Text(heading).font(.headline)
                switch client.auth {
                case .setup:
                    TextField("API ID", text: $apiID)
                    SecureField("API Hash", text: $apiHash)
                    Link("Получить API ID и API Hash ↗", destination: URL(string: "https://my.telegram.org/apps")!).font(.callout)
                    Text("Ключи и сессия хранятся на этом Mac. Приложение использует Telegram API и не связано с Telegram.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Продолжить") { submit() }.buttonStyle(.borderedProminent)
                        .disabled(submitting || apiID.isEmpty || apiHash.isEmpty)
                    Divider()
                    Button("Посмотреть демонстрацию") { client.showDemo() }
                case .phone, .code, .email, .emailCode:
                    TextField(client.auth == .phone ? "+7 999 123-45-67" : "Введите значение", text: $value)
                        .onSubmit { submit() }
                    nextButton
                case .password(let hint):
                    if !hint.isEmpty { Text("Подсказка: \(hint)").font(.caption).foregroundStyle(.secondary) }
                    SecureField("Пароль двухэтапной аутентификации", text: $value).onSubmit { submit() }
                    nextButton
                case .unsupported(let message): Text(message).foregroundStyle(.secondary)
                case .closed: Text("Закройте и снова откройте chatslaughter для нового подключения.").foregroundStyle(.secondary)
                default: ProgressView().frame(maxWidth: .infinity)
                }
            }
            .textFieldStyle(.roundedBorder)
            .frame(width: 340)
            .disabled(submitting)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .onAppear {
            let stored = client.storedCredentials(); apiID = stored.0; apiHash = stored.1
        }
        .onChange(of: client.auth) { _ in value = "" }
    }
    private var nextButton: some View {
        Button("Продолжить") { submit() }.buttonStyle(.borderedProminent).disabled(value.isEmpty || submitting)
    }
    private func submit() {
        guard !submitting else { return }
        submitting = true
        let input = value
        Task {
            if client.auth == .setup { await client.connect(apiID: apiID, apiHash: apiHash) }
            else { await client.submit(input) }
            value = ""; submitting = false
        }
    }
}
