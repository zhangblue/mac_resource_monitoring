import Combine
import ServiceManagement

@MainActor
protocol LoginService: AnyObject {
    /// 返回系统登录项当前状态；管理器初始化、刷新和执行开关操作前读取。
    var status: SMAppService.Status { get }
    /// 注册主应用登录项；用户在设置中打开“登录时启动”时调用。
    func register() throws
    /// 注销主应用登录项；用户在设置中关闭“登录时启动”时调用。
    func unregister() throws
}

@MainActor
final class MainAppLoginService: LoginService {
    private let service = SMAppService.mainApp

    /// 转发系统主应用登录项状态；LoginItemManager 查询状态时读取。
    var status: SMAppService.Status { service.status }

    /// 调用系统服务注册当前应用；登录项管理器启用开关时调用。
    func register() throws { try service.register() }

    /// 调用系统服务注销当前应用；登录项管理器关闭开关时调用。
    func unregister() throws { try service.unregister() }
}

@MainActor
final class LoginItemManager: ObservableObject {
    @Published private(set) var status: SMAppService.Status

    private let service: LoginService

    /// 使用可替换的登录服务初始化管理器；应用启动或测试注入模拟服务时调用。
    init(service: LoginService) {
        self.service = service
        status = service.status
    }

    /// 使用系统主应用服务初始化；设置界面创建默认管理器时调用。
    convenience init() {
        self.init(service: MainAppLoginService())
    }

    /// 判断当前状态是否应显示为已启用；设置界面渲染开关时读取。
    var isEnabled: Bool {
        switch status {
        case .enabled, .requiresApproval: return true
        case .notRegistered, .notFound: return false
        @unknown default: return false
        }
    }

    /// 返回面向用户的登录项状态文本；设置界面刷新状态时读取。
    var statusText: String {
        switch status {
        case .enabled: return "已开启"
        case .requiresApproval: return "等待系统批准"
        case .notRegistered: return "已关闭"
        case .notFound: return "服务不可用"
        @unknown default: return "状态未知"
        }
    }

    /// 从系统服务重新读取状态；设置页面出现或注册操作结束后调用。
    func refresh() {
        status = service.status
    }

    /// 根据用户选择注册或注销登录项；设置开关变化时调用，并在结束后刷新状态。
    /// 所有状态访问限定在 @MainActor；通过 defer 在成功或抛错后都回读系统真实状态，避免 UI 乐观值与系统不一致。
    func setEnabled(_ enabled: Bool) throws {
        defer { refresh() }
        switch (enabled, service.status) {
        case (true, .enabled), (false, .notRegistered), (false, .notFound):
            return
        case (true, _):
            // 仅在系统尚未启用时请求注册，避免重复系统调用。
            try service.register()
        case (false, .enabled), (false, .requiresApproval):
            // 已启用或等待批准的服务都需要显式注销，才能与关闭状态一致。
            try service.unregister()
        @unknown default:
            return
        }
    }
}
