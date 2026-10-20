import AppKit
import SwiftUI

extension MetricSection {
    var settingsLabel: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "内存"
        case .upload: "上传"
        case .download: "下载"
        case .chipTemperature: "芯片温度"
        case .fan: "风扇"
        case .diskCapacity: "磁盘容量"
        }
    }
}

struct SectionButtonAppearance {
    let isSelected: Bool

    var isHighlighted: Bool { isSelected }
    var accessibilityValue: String { isSelected ? "显示" : "不显示" }
    var background: Color { isSelected ? .accentColor : Color(nsColor: .controlColor) }
    var foreground: Color { isSelected ? .white : .primary }
}

struct SettingsView: View {
    @ObservedObject var loginItemManager: LoginItemManager
    @ObservedObject var settings: MonitoringSettings
    let onBack: () -> Void

    @State private var loginError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("设置").font(.headline)
                Spacer()
            }
            .padding(16)

            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    loginSection
                    monitoringSection
                    Divider()
                    informationSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            .frame(maxHeight: .infinity)

            Divider()
            HStack {
                Button(action: onBack) {
                    Label("返回首页", systemImage: "chevron.left")
                }
                .accessibilityIdentifier("monitoring.settings.returnHome")
                Spacer()
                Button("退出应用") { NSApplication.shared.terminate(nil) }
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 380)
        .frame(minHeight: 300, maxHeight: 520)
        .onAppear { loginItemManager.refresh() }
    }

    private var loginSection: some View {
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
    }

    private var monitoringSection: some View {
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

            Text("显示板块").font(.subheadline.weight(.semibold))
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                ForEach(MetricSection.allCases, id: \.self) { section in
                    let appearance = SectionButtonAppearance(isSelected: settings.selection.contains(section))
                    Button {
                        settings.set(section, enabled: !appearance.isSelected)
                    } label: {
                        Text(section.settingsLabel)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(appearance.foreground)
                            .frame(maxWidth: .infinity, minHeight: 28)
                            .background(appearance.background, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("monitoring.section.\(section.rawValue)")
                    .accessibilityLabel(section.settingsLabel)
                    .accessibilityValue(appearance.accessibilityValue)
                    .accessibilityAddTraits(appearance.isSelected ? .isSelected : [])
                }
            }
        }
    }

    private var informationSection: some View {
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
