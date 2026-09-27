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
                // Градиент: живой цветной верх, склейка в центре, чёрный низ
                LinearGradient(
                    stops: [
                        .init(color: tunnel.status == .connected ? Color(hex: 0x2FA96E) : Color(hex: 0x35507E), location: 0),
                        .init(color: tunnel.status == .connected ? Color(hex: 0x0E3D2E) : Color(hex: 0x131B2B), location: 0.45),
                        .init(color: .black, location: 1.0),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
                .animation(.easeInOut(duration: 0.6), value: tunnel.status)
                .ignoresSafeArea()

                if tunnel.status == .connected {
                    Circle()
                        .fill(Color.green.opacity(0.30))
                        .frame(width: 420, height: 420)
                        .blur(radius: 130)
                        .offset(y: -40)
                        .allowsHitTesting(false)
                }

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
}

/// Меню: List (не Form — Form глушит glassEffect на рядах) + стеклянные кнопки.
struct MenuView: View {
    @ObservedObject var tunnel: TunnelManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
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
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { dismiss() }
                        .bold()
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
            HStack(spacing: 12) {
                Button {
                    tunnel.fetchStats()
                } label: {
                    Label("Обновить", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .glassCapsule()

                Button {
                    UIPasteboard.general.string = tunnel.journalText ?? ""
                } label: {
                    Label("Скопировать", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .glassCapsule()
                .disabled((tunnel.journalText ?? "").isEmpty)

                if let url = exportFileURL {
                    ShareLink(item: url) {
                        Label("Поделиться", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .glassCapsule()
                }
            }
            .padding(10)
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

// MARK: - Liquid Glass с деградацией

/// Стеклянная капсула: iOS 26 — родной glassEffect; ниже — ultraThinMaterial.
extension View {
    @ViewBuilder
    func glassCapsule() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: .capsule)
        } else {
            self.background(.ultraThinMaterial, in: .capsule)
        }
    }

    @ViewBuilder
    func glassCircle() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: .circle)
        } else {
            self.background(.ultraThinMaterial, in: .circle)
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
