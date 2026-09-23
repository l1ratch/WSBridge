import SwiftUI
import NetworkExtension

struct ContentView: View {
    @StateObject private var tunnel = TunnelManager()

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: tunnel.status == .connected ? "bolt.fill" : "bolt.slash")
                .font(.system(size: 64))
                .foregroundStyle(tunnel.status == .connected ? .green : .secondary)
            Text(statusText)
                .font(.title3)
            Button(tunnel.status == .connected ? "Выключить" : "Включить") {
                Task { await tunnel.toggle() }
            }
            .buttonStyle(.borderedProminent)
            Button("Статистика туннеля") {
                tunnel.fetchStats()
            }
            .buttonStyle(.bordered)
            if let stats = tunnel.stats {
                Text(stats)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal)
            }
            if let errorMessage = tunnel.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            Spacer()
        }
        .padding(.top, 100)
        .task { await tunnel.reload() }
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
