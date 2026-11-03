import AppKit
import SwiftUI

extension MetricSection {
    /// 返回板块在设置中的中文名称；构建板块选择按钮时读取。
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

    /// 判断按钮是否使用选中样式；设置页渲染板块按钮时读取。
    var isHighlighted: Bool { isSelected }
    /// 返回辅助功能状态文字；VoiceOver 读取板块按钮时使用。
    var accessibilityValue: String { isSelected ? "显示" : "不显示" }
    /// 返回按钮背景色；设置页根据选择状态渲染时读取。
    var background: Color { isSelected ? .accentColor : Color(nsColor: .controlColor) }
    /// 返回按钮前景色；设置页根据选择状态渲染时读取。
    var foreground: Color { isSelected ? .white : .primary }
}

struct SettingsView: View {
    @ObservedObject var loginItemManager: LoginItemManager
    @ObservedObject var settings: MonitoringSettings
    let onBack: () -> Void

    @State private var loginError: String?

    /// 构建设置页的登录项、监控选项和应用信息；导航进入设置时由 SwiftUI 调用。
    /// 两个 ObservableObject 分别驱动系统登录项与监控配置，ScrollView 限制主体滚动而底部返回按钮保持固定。
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
        // 页面出现时重新读取系统登录项状态，避免显示进入设置前的旧值。
        .onAppear { loginItemManager.refresh() }
    }

    /// 构建登录启动设置及错误提示；设置页主体渲染时调用。
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

    /// 构建刷新、历史与板块选择控件；设置页主体渲染时调用。
    /// Picker 直接绑定 Published 枚举；板块按钮通过显式 set 写 UserDefaults，三列 LazyVGrid 只创建可见单元。
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
                        // 用户点击时立即持久化选择，MonitoringStore 会按顺序更新采样计划。
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

    /// 构建设置摘要、版本和日志位置；设置页主体渲染时调用。
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

    /// 读取应用短版本号；设置页信息区刷新时读取。
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    /// 应用登录启动开关并显示失败原因；用户切换登录项 Toggle 时调用。
    private func setLoginEnabled(_ enabled: Bool) {
        loginError = nil
        do {
            try loginItemManager.setEnabled(enabled)
        } catch {
            loginError = "无法更改登录启动：\(error.localizedDescription)"
        }
    }
}
