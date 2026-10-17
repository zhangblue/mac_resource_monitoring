import Darwin
import Foundation

enum ProcessSystemProviderError: Error, Equatable {
    case processListFailed
}

protocol ProcessInfoAccessing: Sendable {
    func allPIDs() throws -> [Int32]
    func taskAllInfo(for pid: Int32) -> proc_taskallinfo?
}

protocol ProcessIdentityResolving: Sendable {
    func identity(for pid: Int32) -> ProcessIdentity?
}

struct LibprocProcessInfoAccess: ProcessInfoAccessing {
    private let listPIDs: @Sendable (UnsafeMutableRawPointer?, Int32) -> Int32
    private let readTaskInfo: @Sendable (Int32, UnsafeMutableRawPointer, Int32) -> Int32

    init(
        listPIDs: @escaping @Sendable (UnsafeMutableRawPointer?, Int32) -> Int32 = { proc_listallpids($0, $1) },
        readTaskInfo: @escaping @Sendable (Int32, UnsafeMutableRawPointer, Int32) -> Int32 = {
            proc_pidinfo($0, PROC_PIDTASKALLINFO, 0, $1, $2)
        }
    ) {
        self.listPIDs = listPIDs
        self.readTaskInfo = readTaskInfo
    }

    func allPIDs() throws -> [Int32] {
        let count = listPIDs(nil, 0)
        guard count >= 0 else { throw ProcessSystemProviderError.processListFailed }
        var pids = [Int32](repeating: 0, count: Int(count) + 32)
        let actual = pids.withUnsafeMutableBytes { listPIDs($0.baseAddress, Int32($0.count)) }
        guard actual >= 0 else { throw ProcessSystemProviderError.processListFailed }
        return Array(pids.prefix(Int(actual)))
    }

    func taskAllInfo(for pid: Int32) -> proc_taskallinfo? {
        var info = proc_taskallinfo()
        let expected = Int32(MemoryLayout<proc_taskallinfo>.size)
        let size = withUnsafeMutablePointer(to: &info) { readTaskInfo(pid, $0, expected) }
        return size == expected ? info : nil
    }
}

struct ProcessSystemProvider: ProcessIdentityResolving, Sendable {
    private let access: any ProcessInfoAccessing

    init(access: any ProcessInfoAccessing = LibprocProcessInfoAccess()) { self.access = access }

    func sample() throws -> [ProcessSystemCounter] {
        try access.allPIDs().compactMap { pid in
            guard pid > 0, let info = access.taskAllInfo(for: pid) else { return nil }
            let name = Self.string(info.pbsd.pbi_name)
            let command = Self.string(info.pbsd.pbi_comm)
            return .init(identity: Self.identity(pid: pid, info: info),
                         name: !name.isEmpty ? name : (!command.isEmpty ? command : "PID \(pid)"),
                         cpuNanoseconds: info.ptinfo.pti_total_user + info.ptinfo.pti_total_system,
                         residentBytes: info.ptinfo.pti_resident_size)
        }
    }

    func identity(for pid: Int32) -> ProcessIdentity? {
        guard pid > 0, let info = access.taskAllInfo(for: pid) else { return nil }
        return Self.identity(pid: pid, info: info)
    }

    private static func identity(pid: Int32, info: proc_taskallinfo) -> ProcessIdentity {
        .init(pid: pid, startTimeMicroseconds: info.pbsd.pbi_start_tvsec * 1_000_000 + info.pbsd.pbi_start_tvusec)
    }

    private static func string<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
    }
}
