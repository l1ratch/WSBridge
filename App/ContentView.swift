import SwiftUI
import NetworkExtension
import UIKit

struct ContentView: View {
    @StateObject private var tunnel = TunnelManager()

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: tunnel.status == .connected ? "bolt.fill" : "bolt.slash")
                .font(.system(size: 64))
                .foregroundStyle(tunnel.status == .connected ? .green : .secondary)
            Text(statusText)
                .font(.title3)
            Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button(tunnel.status == .connected ? "Выключить" : "Включить") {
                Task { await tunnel.toggle() }
            }
            .buttonStyle(.borderedProminent)
            TextField("CF worker: name.user.workers.dev (опц.)", text: $tunnel.workerDomain)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(tunnel.status == .connected)
                .padding(.horizontal, 40)
            Text(workerHint)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
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
            if let journal = tunnel.journalText {
                ScrollView {
                    Text(journal)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 300)
                .padding(.horizontal)
                Button("Скопировать журнал") {
                    UIPasteboard.general.string = journal
                }
                .buttonStyle(.bordered)
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

    private var workerHint: String {
        tunnel.workerDomain.trimmingCharacters(in: .whitespaces).isEmpty
            ? "Без worker'а используются общие домены kws — они сейчас деградируют (503)."
            : "Pipe-режим: байты идут через твой worker напрямую в DC. Включи туннель заново, чтобы применилось."
    }
}
