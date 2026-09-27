import SwiftUI
import NetworkExtension
import UIKit

/// Главный экран: только молния-кнопка. Всё остальное — в меню (кнопка «…»).
/// Стиль — эмуляция Liquid Glass для iOS 18 SDK: ultraThinMaterial, крупные
/// радиусы, тонкие светлые кромки (на iOS 26 смотрится родным, на 18 — стеклом).
struct ContentView: View {
    @StateObject private var tunnel = TunnelManager()
    @State private var showMenu = false

    var body: some View {
        NavigationStack {
            ZStack {
                // Глубокий фон: градиент + цветное свечение под молнией
                ZStack {
                    LinearGradient(
                        colors: tunnel.status == .connected
                            ? [Color(hex: 0x0B1E3A).opacity(0.95), Color(hex: 0x0E8A58).opacity(0.55),
                               Color(.systemBackground)]
                            : [Color(hex: 0x1C2430), Color(.systemBackground)],
                        startPoint: .top, endPoint: .bottom
                    )
                    if tunnel.status == .connected {
                        Circle()
                            .fill(Color.green.opacity(0.35))
                            .frame(width: 380, height: 380)
                            .blur(radius: 120)
                            .offset(y: -60)
                    }
                }
                .ignoresSafeArea()

                VStack(spacing: 44) {
                    // Молния — и индикатор, и кнопка: тап включает/выключает.
                    Button {
                        Task { await tunnel.toggle() }
                    } label: {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 110, weight: .bold))
                            .foregroundStyle(
                                tunnel.status == .connected
                                ? AnyShapeStyle(LinearGradient(colors: [.white, .green],
                                                               startPoint: .top, endPoint: .bottom))
                                : AnyShapeStyle(Color(.systemGray3)))
                            .shadow(color: tunnel.status == .connected ? .green.opacity(0.65) : .clear,
                                    radius: tunnel.status == .connected ? 40 : 0)
                            .padding(48)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(tunnel.status == .connecting || tunnel.status == .disconnecting)

                    VStack(spacing: 6) {
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
                                .padding(.horizontal, 32)
                                .padding(10)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
                        }
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
                            .padding(10)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                }
            }
            .sheet(isPresented: $showMenu) {
                MenuView(tunnel: tunnel)
                    .presentationDetents([.medium, .large])
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
}

/// Меню: стеклянные карточки-секции вместо системного Form.
struct MenuView: View {
    @ObservedObject var tunnel: TunnelManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    glassCard {
                        VStack(spacing: 0) {
                            menuRow(icon: "doc.text", title: "Журнал туннеля") {
                                JournalView(tunnel: tunnel)
                            }
                            divider
                            menuRow(icon: "chart.bar", title: "Статистика") {
                                StatsView(tunnel: tunnel)
                            }
                        }
                    }
                    glassCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Настройки", systemImage: "switch.2")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                            TextField("CF worker или реле ip:port", text: $tunnel.workerDomain)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .disabled(tunnel.status == .connected)
                                .padding(12)
                                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 14))
                            Text(workerHint)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(16)
                    }
                    glassCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Информация", systemImage: "info.circle")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                            LabeledContent("Версия", value: versionString)
                            LabeledContent("Туннель", value: TunnelManager.providerBundleId)
                            Text("Telegram через WebSocket-мост Cloudflare (порт tg-ws-proxy). Пустое поле worker'а = общие kws-фронты — рекомендуется.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(16)
                    }
                }
                .padding(16)
            }
            .background(
                LinearGradient(colors: [Color(hex: 0x0B1E3A).opacity(0.8), Color(.systemBackground)],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
            )
            .navigationTitle("Меню")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { dismiss() }
                        .bold()
                }
            }
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(.white.opacity(0.12))
            .frame(height: 0.5)
            .padding(.horizontal, 16)
    }

    private func glassCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26))
            .overlay(
                RoundedRectangle(cornerRadius: 26)
                    .strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
    }

    private func menuRow<Dest: View>(icon: String, title: String, @ViewBuilder destination: () -> Dest) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 34)
                Text(title)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
        }
        .buttonStyle(.plain)
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

/// Журнал расширения: обновление, копирование, экспорт файлом через системный sheet.
struct JournalView: View {
    @ObservedObject var tunnel: TunnelManager

    var body: some View {
        VStack(spacing: 0) {
            if let journal = tunnel.journalText, !journal.isEmpty {
                ScrollView {
                    Text(journal)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
            } else {
                Spacer()
                ProgressView()
                Spacer()
            }
            HStack(spacing: 14) {
                Button {
                    tunnel.fetchStats()
                } label: {
                    Label("Обновить", systemImage: "arrow.clockwise")
                }
                Button {
                    UIPasteboard.general.string = tunnel.journalText ?? ""
                } label: {
                    Label("Скопировать", systemImage: "doc.on.doc")
                }
                .disabled((tunnel.journalText ?? "").isEmpty)
                if let url = exportFileURL {
                    ShareLink(item: url) {
                        Label("Поделиться", systemImage: "square.and.arrow.up")
                    }
                }
            }
            .buttonStyle(.bordered)
            .padding(10)
            .background(.ultraThinMaterial)
        }
        .navigationTitle("Журнал")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if tunnel.journalText == nil { tunnel.fetchStats() }
        }
    }

    /// Журнал файлом во временную папку — для системного «Поделиться».
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
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Обновить") { tunnel.fetchStats() }
            }
        }
        .onAppear { tunnel.fetchStats() }
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
