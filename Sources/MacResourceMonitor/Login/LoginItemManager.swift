import Combine
import ServiceManagement

@MainActor
protocol LoginService: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

@MainActor
final class MainAppLoginService: LoginService {
    private let service = SMAppService.mainApp

    var status: SMAppService.Status { service.status }

    func register() throws { try service.register() }

    func unregister() throws { try service.unregister() }
}

@MainActor
final class LoginItemManager: ObservableObject {
    @Published private(set) var status: SMAppService.Status

    private let service: LoginService

    init(service: LoginService) {
        self.service = service
        status = service.status
    }

    convenience init() {
        self.init(service: MainAppLoginService())
    }

    var isEnabled: Bool {
        switch status {
        case .enabled, .requiresApproval: return true
        case .notRegistered, .notFound: return false
        @unknown default: return false
        }
    }

    var statusText: String {
        switch status {
        case .enabled: return "已开启"
        case .requiresApproval: return "等待系统批准"
        case .notRegistered: return "已关闭"
        case .notFound: return "服务不可用"
        @unknown default: return "状态未知"
        }
    }

    func refresh() {
        status = service.status
    }

    func setEnabled(_ enabled: Bool) throws {
        defer { refresh() }
        switch (enabled, service.status) {
        case (true, .enabled), (false, .notRegistered), (false, .notFound):
            return
        case (true, _):
            try service.register()
        case (false, .enabled), (false, .requiresApproval):
            try service.unregister()
        @unknown default:
            return
        }
    }
}
