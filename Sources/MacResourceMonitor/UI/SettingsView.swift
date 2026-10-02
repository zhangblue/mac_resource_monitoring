import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var loginItemManager: LoginItemManager
    @ObservedObject var settings: MonitoringSettings
    let onBack: () -> Void

    @State private var loginError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button(action: onBack) {
                    Label("返回", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                Spacer()
                Text("设置")
                    .font(.headline)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 5) {
                Toggle("登录时自动启动", isOn: Binding(
                    get: { loginItemManager.isEnabled },
                    set: { setLoginEnabled($0) }
                ))
                Text(loginItemManager.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let loginError {
                    Text(loginError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("监控").font(.subheadline.weight(.semibold))
                Picker("刷新时间", selection: $settings.refreshInterval) {
                    ForEach(RefreshInterval.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                Picker("保留最近时间", selection: $settings.historyDuration) {
                    ForEach(HistoryDuration.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text(settings.summary)
                LabeledContent("版本", value: version)
                VStack(alignment: .leading, spacing: 4) {
                    Text("本地诊断日志位置")
                        .foregroundStyle(.secondary)
                    Text(DiagnosticLogger.displayPath)
                        .font(.caption)
                        .textSelection(.enabled)
                    Text("发生采集异常时创建")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)

            Spacer(minLength: 0)

            Divider()
            Button("退出应用") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
        }
        .padding(16)
        .frame(width: 380)
        .frame(minHeight: 300)
        .onAppear { loginItemManager.refresh() }
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private func setLoginEnabled(_ enabled: Bool) {
        loginError = nil
        do {
            try loginItemManager.setEnabled(enabled)
        } catch {
            loginError = "无法更改登录启动：\(error.localizedDescription)"
        }
    }
}
