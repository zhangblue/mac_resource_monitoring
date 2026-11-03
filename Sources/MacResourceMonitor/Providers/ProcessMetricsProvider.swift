actor ProcessMetricsProvider: ProcessMetricsProviding {
    private let system: ProcessSystemProvider
    private let network: NetTopProcessProvider

    /// 组装系统进程和 nettop 提供器；应用启动或测试注入替身时调用。
    init(system: ProcessSystemProvider = ProcessSystemProvider(), network: NetTopProcessProvider = NetTopProcessProvider()) {
        self.system = system
        self.network = network
    }

    /// 同时采集系统与网络进程数据；兼容全量接口时调用。
    func sample() async -> ProcessRawSnapshot {
        await sample(system: true, network: true)
    }

    /// 按需并发采集进程系统或网络数据；监控引擎根据启用板块调用。
    /// actor 防止同一 nettop 提供器被并发重入，两个分支通过 async let 并行；未选择分支直接返回 notSelected。
    func sample(system: Bool, network: Bool) async -> ProcessRawSnapshot {
        async let systemReading: Reading<[ProcessSystemCounter]> = system
            ? Self.readSystem(self.system) : .unavailable("notSelected")
        async let networkReading: Reading<[ProcessNetworkCounter]> = network
            ? Self.readNetwork(self.network) : .unavailable("notSelected")
        return await .init(system: systemReading, network: networkReading)
    }

    /// 取消进行中的 nettop 采集；停止、睡眠或板块切换时调用。
    func cancel() async { await network.cancel() }

    /// 将系统进程采集错误转换为稳定分类；按需采集系统进程数据时调用。
    private static func readSystem(_ provider: ProcessSystemProvider) -> Reading<[ProcessSystemCounter]> {
        do { return .value(try provider.sample()) }
        catch { return .unavailable("processListFailed") }
    }

    /// 将 nettop 结果和错误转换为稳定分类；按需采集网络进程数据时调用。
    private static func readNetwork(_ provider: NetTopProcessProvider) async -> Reading<[ProcessNetworkCounter]> {
        do { return .value(try await provider.sample()) }
        catch let error as NetTopProcessProviderError {
            switch error {
            case .timedOut: return .unavailable("nettopTimedOut")
            case .outputTooLarge: return .unavailable("nettopOutputTooLarge")
            case .nonzeroExit: return .unavailable("nettopExitFailed")
            case .invalidCSV, .missingColumns, .noProcessRows: return .unavailable("nettopInvalidCSV")
            case .commandFailed, .cancelled, .alreadyRunning: return .unavailable("nettopLaunchFailed")
            }
        }
        catch { return .unavailable("nettopLaunchFailed") }
    }
}
