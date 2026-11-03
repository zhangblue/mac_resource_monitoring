import Darwin
import Foundation

enum ProcessSystemProviderError: Error, Equatable {
    case processListFailed
}

protocol ProcessInfoAccessing: Sendable {
    /// 获取系统全部 PID；进程系统采样开始时调用。
    func allPIDs() throws -> [Int32]
    /// 读取指定 PID 的任务和身份信息；遍历进程或解析身份时调用。
    func taskAllInfo(for pid: Int32) -> proc_taskallinfo?
}

protocol ProcessIdentityResolving: Sendable {
    /// 解析 PID 及启动时间组成的稳定身份；关联 nettop 记录时调用。
    func identity(for pid: Int32) -> ProcessIdentity?
}

struct LibprocProcessInfoAccess: ProcessInfoAccessing {
    private let listPIDs: @Sendable (UnsafeMutableRawPointer?, Int32) -> Int32
    private let readTaskInfo: @Sendable (Int32, UnsafeMutableRawPointer, Int32) -> Int32

    /// 注入 libproc 调用；生产环境使用系统函数，测试用替身构造边界结果。
    init(
        listPIDs: @escaping @Sendable (UnsafeMutableRawPointer?, Int32) -> Int32 = { proc_listallpids($0, $1) },
        readTaskInfo: @escaping @Sendable (Int32, UnsafeMutableRawPointer, Int32) -> Int32 = {
            proc_pidinfo($0, PROC_PIDTASKALLINFO, 0, $1, $2)
        }
    ) {
        self.listPIDs = listPIDs
        self.readTaskInfo = readTaskInfo
    }

    /// 两阶段读取系统 PID 列表；进程采样器每轮枚举进程时调用。
    /// 第一次 proc_listallpids 获取数量，第二次传入字节容量；额外预留 32 项应对两次调用间新建的进程。
    func allPIDs() throws -> [Int32] {
        // 先读取数量再分配略有余量的缓冲区，降低进程列表增长导致截断的概率。
        let count = listPIDs(nil, 0)
        guard count >= 0 else { throw ProcessSystemProviderError.processListFailed }
        var pids = [Int32](repeating: 0, count: Int(count) + 32)
        let actual = pids.withUnsafeMutableBytes { listPIDs($0.baseAddress, Int32($0.count)) }
        guard actual >= 0 else { throw ProcessSystemProviderError.processListFailed }
        return Array(pids.prefix(Int(actual)))
    }

    /// 读取单个进程的 proc_taskallinfo；枚举进程和解析身份时调用，短读返回空值。
    func taskAllInfo(for pid: Int32) -> proc_taskallinfo? {
        var info = proc_taskallinfo()
        let expected = Int32(MemoryLayout<proc_taskallinfo>.size)
        let size = withUnsafeMutablePointer(to: &info) { readTaskInfo(pid, $0, expected) }
        return size == expected ? info : nil
    }
}

struct ProcessSystemProvider: ProcessIdentityResolving, Sendable {
    private let access: any ProcessInfoAccessing

    /// 使用 libproc 访问层初始化；应用采集或测试注入访问替身时调用。
    init(access: any ProcessInfoAccessing = LibprocProcessInfoAccess()) { self.access = access }

    /// 采集所有可访问进程的 CPU 累计时间和常驻内存；CPU/内存进程榜单启用时调用。
    /// compactMap 跳过采样期间退出或无权限的进程，CPU 合并用户态与内核态纳秒，内存使用 resident size 字节。
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

    /// 读取单个 PID 的稳定身份；解析 nettop 网络行时调用。
    func identity(for pid: Int32) -> ProcessIdentity? {
        guard pid > 0, let info = access.taskAllInfo(for: pid) else { return nil }
        return Self.identity(pid: pid, info: info)
    }

    /// 将 libproc 信息组合为 PID+启动时间身份；系统采样和网络身份解析内部调用。
    private static func identity(pid: Int32, info: proc_taskallinfo) -> ProcessIdentity {
        .init(pid: pid, startTimeMicroseconds: info.pbsd.pbi_start_tvsec * 1_000_000 + info.pbsd.pbi_start_tvusec)
    }

    /// 将 C 定长字符元组转换为 Swift 字符串；提取进程名和命令名时调用。
    /// 通过 withUnsafeBytes 截取首个 NUL 之前内容，再按 UTF-8 解码，避免依赖元组具体长度。
    private static func string<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
    }
}
