actor ProcessMetricsProvider: ProcessMetricsProviding {
    private let system: ProcessSystemProvider
    private let network: NetTopProcessProvider

    init(system: ProcessSystemProvider = ProcessSystemProvider(), network: NetTopProcessProvider = NetTopProcessProvider()) {
        self.system = system
        self.network = network
    }

    func sample() async -> ProcessRawSnapshot {
        await sample(system: true, network: true)
    }

    func sample(system: Bool, network: Bool) async -> ProcessRawSnapshot {
        async let systemReading: Reading<[ProcessSystemCounter]> = system
            ? Self.readSystem(self.system) : .unavailable("notSelected")
        async let networkReading: Reading<[ProcessNetworkCounter]> = network
            ? Self.readNetwork(self.network) : .unavailable("notSelected")
        return await .init(system: systemReading, network: networkReading)
    }

    func cancel() async { await network.cancel() }

    private static func readSystem(_ provider: ProcessSystemProvider) -> Reading<[ProcessSystemCounter]> {
        do { return .value(try provider.sample()) }
        catch { return .unavailable("processListFailed") }
    }

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
