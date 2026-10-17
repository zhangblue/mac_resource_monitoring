actor ProcessMetricsProvider: ProcessMetricsProviding {
    private let system: ProcessSystemProvider
    private let network: NetTopProcessProvider

    init(system: ProcessSystemProvider = ProcessSystemProvider(), network: NetTopProcessProvider = NetTopProcessProvider()) {
        self.system = system
        self.network = network
    }

    func sample() async -> ProcessRawSnapshot {
        async let systemReading = Self.readSystem(system)
        async let networkReading = Self.readNetwork(network)
        return await .init(system: systemReading, network: networkReading)
    }

    func cancel() async { await network.cancel() }

    private static func readSystem(_ provider: ProcessSystemProvider) -> Reading<[ProcessSystemCounter]> {
        do { return .value(try provider.sample()) }
        catch { return .unavailable("processListFailed") }
    }

    private static func readNetwork(_ provider: NetTopProcessProvider) async -> Reading<[ProcessNetworkCounter]> {
        do { return .value(try await provider.sample()) }
        catch let error as NetTopProcessProviderError { return .unavailable(String(describing: error)) }
        catch is CancellationError { return .unavailable("cancelled") }
        catch { return .unavailable("commandFailed") }
    }
}
