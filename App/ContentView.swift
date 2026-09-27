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
                // Авторский градиент: цветной верх (синий → цвет состояния),
                // насыщенное слияние в центре, чистая тьма к низу.
                LinearGradient(
                    stops: [
                        .init(color: Color(hex: 0x243B6B), location: 0.00),
                        .init(color: tunnel.status == .connected ? Color(hex: 0x1E9E63) : Color(hex: 0x3D5A8F), location: 0.22),
                        .init(color: tunnel.status == .connected ? Color(hex: 0x136B47) : Color(hex: 0x1B2942), location: 0.50),
                        .init(color: Color(hex: 0x070D18), location: 0.80),
                        .init(color: .black, location: 1.00),
                    ],
                    startPoint: .topLeading, endPoint: .bottom
                )
                .animation(.easeInOut(duration: 0.7), value: tunnel.status)
                .ignoresSafeArea()

                if tunnel.status == .connected {
                    Circle()
                        .fill(Color(hex: 0x1E9E63).opacity(0.30))
                        .frame(width: 460, height: 460)
                        .blur(radius: 140)
                        .offset(y: -60)
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
        ZStack {
            // Градиент под стеклом кнопок — есть что преломлять,
            // нет однотонной подложки.
            LinearGradient(
                stops: [
                    .init(color: Color(hex: 0x16233C), location: 0),
                    .init(color: Color(hex: 0x0A0F1C), location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                if let journal = tunnel.journalText, !journal.isEmpty {
                    ScrollView {
                        Text(journal)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.92))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                } else {
                    Spacer()
                    ProgressView()
                        .tint(.white)
                    Spacer()
                }
                HStack(spacing: 12) {
                    Button {
                        tunnel.fetchStats()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.title3)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .glassCapsule(interactive: true)

                    Button {
                        UIPasteboard.general.string = tunnel.journalText ?? ""
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.title3)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .glassCapsule(interactive: true)
                    .disabled((tunnel.journalText ?? "").isEmpty)

                    if let url = exportFileURL {
                        ShareLink(item: url) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.title3)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                        }
                        .glassCapsule(interactive: true)
                    }
                }
                .padding(10)
            }
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

/// Стеклянная капсула: iOS 26 — родной glassEffect (+ interactive: живая
/// деформация под пальцем); ниже — ultraThinMaterial.
extension View {
    @ViewBuilder
    func glassCapsule(interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(interactive ? .regular.interactive() : .regular, in: .capsule)
        } else {
            self.background(.ultraThinMaterial, in: .capsule)
        }
    }

    @ViewBuilder
    func glassCircle(interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(interactive ? .regular.interactive() : .regular, in: .circle)
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
