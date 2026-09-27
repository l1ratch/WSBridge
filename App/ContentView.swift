import SwiftUI
import NetworkExtension
import UIKit

/// Главный экран: только молния-кнопка. Меню — системный ellipsis сверху справа.
/// iOS 26: настоящий Liquid Glass (glassEffect); 17-25: деградация в material.
struct ContentView: View {
    @StateObject private var tunnel = TunnelManager()
    @State private var showMenu = false

    var body: some View {
        NavigationStack {
            ZStack {
                // Точка слияния: глубокий нейтральный navy — цвет центра,
                // куда оба свечения растворяются.
                Color(hex: 0x0D1526).ignoresSafeArea()

                // Верхнее свечение: насыщенный цвет состояния (изумруд / синий),
                // гауссов спад — гладкий, без полос и швов. Статично;
                // анимация только при смене состояния (crossfade цвета).
                Ellipse()
                    .fill(topWashColor)
                    .frame(width: 560, height: 520)
                    .blur(radius: 110)
                    .opacity(0.55)
                    .offset(y: -250)
                    .animation(.easeInOut(duration: 0.8), value: tunnel.status)
                    .ignoresSafeArea()

                // Нижняя глубина: почти чёрный синий, тоже тает к центру.
                Ellipse()
                    .fill(Color(hex: 0x040810))
                    .frame(width: 700, height: 480)
                    .blur(radius: 130)
                    .opacity(0.85)
                    .offset(y: 400)
                    .ignoresSafeArea()

                VStack(spacing: 48) {
                    // Молния — и индикатор, и кнопка: тап включает/выключает.
                    Button {
                        Task { await tunnel.toggle() }
                    } label: {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 140, weight: .bold))
                            .foregroundStyle(
                                tunnel.status == .connected
                                ? AnyShapeStyle(LinearGradient(colors: [.white, .green],
                                                               startPoint: .top, endPoint: .bottom))
                                : AnyShapeStyle(Color(.systemGray2)))
                            .shadow(color: tunnel.status == .connected ? .green.opacity(0.65) : .black.opacity(0.2),
                                    radius: tunnel.status == .connected ? 40 : 8)
                            .padding(56)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(tunnel.status == .connecting || tunnel.status == .disconnecting)

                    // Статус скрыт по просьбе владельца (не удалён).
                    Text(statusText)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .hidden()

                    if let errorMessage = tunnel.errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .glassCapsule()
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showMenu = true
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.title3.weight(.semibold))
                    }
                }
            }
            .sheet(isPresented: $showMenu) {
                MenuView(tunnel: tunnel)
            }
            .task { await tunnel.reload() }
        }
    }

    private var statusText: String {
        switch tunnel.status {
        case .connected: "Туннель активен"
        case .connecting: "Подключение…"
        case .reasserting: "Переподключение…"
        case .disconnecting: "Отключение…"
        default: "Туннель выключен"
        }
    }

    /// Цвет верхнего свечения: живой изумруд при работе, глубокий индиго в покое.
    private var topWashColor: Color {
        tunnel.status == .connected ? Color(hex: 0x17A05E) : Color(hex: 0x1E3A6E)
    }
}

/// Меню: штатный Form. На iOS 26 система сама рисует Liquid Glass.
struct MenuView: View {
    @ObservedObject var tunnel: TunnelManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Диагностика") {
                    NavigationLink {
                        JournalView(tunnel: tunnel)
                    } label: {
                        Label("Журнал туннеля", systemImage: "doc.text")
                    }
                    NavigationLink {
                        StatsView(tunnel: tunnel)
                    } label: {
                        Label("Статистика", systemImage: "chart.bar")
                    }
                }
                Section("Настройки") {
                    TextField("CF worker или реле ip:port", text: $tunnel.workerDomain)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(tunnel.status == .connected)
                    Text(workerHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Информация") {
                    LabeledContent("Версия", value: versionString)
                    LabeledContent("Туннель", value: TunnelManager.providerBundleId)
                    Text("Telegram через WebSocket-мост Cloudflare (порт tg-ws-proxy). Пустое поле worker'а = общие kws-фронты — рекомендуется.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Меню")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }

    private var versionString: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    private var workerHint: String {
        let wd = tunnel.workerDomain.trimmingCharacters(in: .whitespaces)
        if wd.isEmpty {
            return "Пусто = kws-фронты Cloudflare (основной режим)."
        }
        if wd.contains(":") {
            return "Прямой режим: сырой TCP на реле host:port, без CF."
        }
        return "Pipe-режим через свой CF worker. Перезапусти туннель, чтобы применилось."
    }
}

/// Журнал: моноширинный текст + системный toolbar (стеклянный на iOS 26).
struct JournalView: View {
    @ObservedObject var tunnel: TunnelManager

    var body: some View {
        ScrollView {
            Text(tunnel.journalText ?? "")
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("Журнал")
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                Button {
                    tunnel.fetchStats()
                } label: {
                    Label("Обновить", systemImage: "arrow.clockwise")
                }
                Spacer()
                Button {
                    UIPasteboard.general.string = tunnel.journalText ?? ""
                } label: {
                    Label("Скопировать", systemImage: "doc.on.doc")
                }
                .disabled((tunnel.journalText ?? "").isEmpty)
                Spacer()
                if let url = exportFileURL {
                    ShareLink(item: url) {
                        Label("Поделиться", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .onAppear {
            if tunnel.journalText == nil { tunnel.fetchStats() }
        }
    }

    private var exportFileURL: URL? {
        guard let text = tunnel.journalText, !text.isEmpty else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WSBridge-journal.log")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}

/// Статистика живого туннеля (Darwin-события от расширения).
struct StatsView: View {
    @ObservedObject var tunnel: TunnelManager

    var body: some View {
        ScrollView {
            Text(tunnel.stats ?? "Нет данных — туннель не запущен")
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("Статистика")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Обновить") { tunnel.fetchStats() }
            }
        }
        .onAppear { tunnel.fetchStats() }
    }
}

// MARK: - Liquid Glass с деградацией

extension View {
    @ViewBuilder
    func glassCapsule(interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(interactive ? .regular.interactive() : .regular, in: .capsule)
        } else {
            self.background(.ultraThinMaterial, in: .capsule)
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
