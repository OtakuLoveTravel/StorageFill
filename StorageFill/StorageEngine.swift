//
//  StorageEngine.swift
//  StorageFill
//
//  写入 / 删除引擎。
//  设计要点：
//  1. 只在 App 自己的沙盒里写文件（iOS 沙盒限制，App 无法碰别人的数据）。
//  2. 写到"可用空间 - 保留余量"就停，避免把系统写到 0 导致卡死。
//  3. 每一轮结束删掉自己的文件，可用空间会回涨一部分——那部分就是系统在
//     空间紧张时回收的缓存/日志，这才是"清洗"的真正效果。
//

import Foundation
import UIKit

final class StorageEngine: ObservableObject {

    // MARK: - 对外状态

    enum Phase: String {
        case idle       = "待机"
        case filling    = "写入中"
        case clearing   = "清理中"
        case cooldown   = "冷却中"
        case finished   = "已完成"
        case stopped    = "已停止"
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var currentCycle: Int = 0
    @Published private(set) var plannedCycles: Int = 3
    @Published private(set) var writtenThisCycle: Int64 = 0
    @Published private(set) var targetThisCycle: Int64 = 0
    @Published private(set) var totalWritten: Int64 = 0
    @Published private(set) var speedMBps: Double = 0
    @Published private(set) var freeBytes: Int64 = 0
    @Published private(set) var freeAtStart: Int64 = 0
    @Published private(set) var lastFreed: Int64? = nil
    @Published private(set) var logs: [LogLine] = []

    struct LogLine: Identifiable {
        let id = UUID()
        let time: Date
        let text: String
        let level: Level
        enum Level { case info, good, warn }
    }

    var isRunning: Bool { worker != nil }

    // MARK: - 内部

    private var worker: Thread?
    private let stateLock = NSLock()
    private var _cancelled = false

    private var isCancelled: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _cancelled }
        set { stateLock.lock(); _cancelled = newValue; stateLock.unlock() }
    }

    /// 8 MB 一块，兼顾速度与"最后一块不浪费"的精度
    private static let chunkSize = 8 * 1024 * 1024

    /// 复用的填充块（伪随机内容，避免全零数据在文件系统层面被特殊处理）
    private static let chunkData: Data = {
        var bytes = [UInt8](repeating: 0, count: chunkSize)
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        for i in 0..<bytes.count {
            seed ^= seed << 13
            seed ^= seed >> 7
            seed ^= seed << 17
            bytes[i] = UInt8(truncatingIfNeeded: seed >> 24)
        }
        return Data(bytes)
    }()

    static var fillDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("FillBuffer", isDirectory: true)
    }

    init() {
        refreshFreeSpace()
        // 上次异常退出可能留下大量残留文件，放后台线程清理，避免启动卡顿
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.purgeLeftoversSilently()
        }
    }

    // MARK: - 可用空间

    static func availableBytes() -> Int64 {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
           let capacity = values.volumeAvailableCapacity {
            return Int64(capacity)
        }
        return 0
    }

    func refreshFreeSpace() {
        let v = Self.availableBytes()
        DispatchQueue.main.async { self.freeBytes = v }
    }

    // MARK: - 控制

    func start(reserveBytes: Int64, cycles: Int) {
        guard worker == nil else { return }
        isCancelled = false
        logs.removeAll()
        currentCycle = 0
        totalWritten = 0
        writtenThisCycle = 0
        targetThisCycle = 0
        speedMBps = 0
        lastFreed = nil
        plannedCycles = cycles
        phase = .idle
        freeAtStart = Self.availableBytes()
        freeBytes = freeAtStart
        UIApplication.shared.isIdleTimerDisabled = true
        appendLog("开始：可用 \(fmt(freeAtStart))，保留 \(fmt(reserveBytes))，共 \(cycles) 轮", .info)

        let thread = Thread { [weak self] in
            self?.runSession(reserveBytes: reserveBytes, cycles: cycles)
        }
        thread.qualityOfService = .userInitiated
        thread.name = "StorageFillWorker"
        worker = thread
        thread.start()
    }

    func stop() {
        guard worker != nil else { return }
        isCancelled = true
        appendLog("收到停止指令，等当前文件写完就停…", .warn)
    }

    // MARK: - 主循环

    private func runSession(reserveBytes: Int64, cycles: Int) {
        for cycle in 1...max(1, cycles) {
            if isCancelled { break }

            DispatchQueue.main.async {
                self.currentCycle = cycle
                self.writtenThisCycle = 0
                self.speedMBps = 0
            }
            appendLog("————— 第 \(cycle)/\(cycles) 轮 —————", .info)

            // 1) 写入
            let free = Self.availableBytes()
            DispatchQueue.main.async {
                self.freeBytes = free
                self.phase = .filling
            }
            let target = max(0, free - reserveBytes)
            DispatchQueue.main.async { self.targetThisCycle = target }
            appendLog("可用 \(fmt(free)) → 本轮写 \(fmt(target))", .info)

            let fillResult = fillToTarget(target)
            appendLog("写入 \(fmt(fillResult.written))，\(fillResult.note)",
                      fillResult.written >= target ? .good : .warn)

            if isCancelled { break }

            // 2) 删除
            DispatchQueue.main.async { self.phase = .clearing }
            appendLog("删除临时文件…", .info)
            let removed = clearAll()
            appendLog("已释放 \(fmt(removed))", .good)

            let after = Self.availableBytes()
            DispatchQueue.main.async {
                self.freeBytes = after
                self.totalWritten += fillResult.written
            }
            appendLog("现可用 \(fmt(after))", .info)

            // 3) 冷却，给系统一点时间真正回收
            if cycle < cycles && !isCancelled {
                DispatchQueue.main.async { self.phase = .cooldown }
                appendLog("冷却 3 秒…", .info)
                sleep(seconds: 3)
            }
        }

        let cancelled = isCancelled
        let now = Self.availableBytes()
        DispatchQueue.main.async {
            self.phase = cancelled ? .stopped : .finished
            self.freeBytes = now
            self.speedMBps = 0
            self.worker = nil
            self.lastFreed = now - self.freeAtStart
            UIApplication.shared.isIdleTimerDisabled = false
        }
        let delta = now - freeAtStart
        appendLog(cancelled ? "已停止" : "全部完成", .warn)
        appendLog("相对开始时可用空间变化：\(delta >= 0 ? "+" : "")\(fmt(delta))",
                  delta > 0 ? .good : .info)
    }

    // MARK: - 写入

    @discardableResult
    private func fillToTarget(_ target: Int64) -> (written: Int64, note: String) {
        guard target > 0 else { return (0, "可用空间不足，跳过") }

        let fm = FileManager.default
        let dir = Self.fillDirectory
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableDir = dir
            try? mutableDir.setResourceValues(values)
        } catch {
            return (0, "无法创建目录：\(error.localizedDescription)")
        }

        var written: Int64 = 0
        var note = "完成"
        var index = 0
        var lastTick = Date()
        var lastBytes: Int64 = 0

        while written < target {
            if isCancelled { note = "已取消"; break }

            let remaining = target - written
            let size = Int(min(Int64(Self.chunkSize), remaining))
            let url = dir.appendingPathComponent(String(format: "fill_%05d.bin", index))
            let payload = size == Self.chunkSize ? Self.chunkData : Self.chunkData.prefix(size)

            do {
                // 非原子写入：边写边占空间，空间不够时立刻抛 ENOSPC
                try payload.write(to: url)
            } catch {
                note = "空间已满（\(shortError(error))）"
                break
            }

            written += Int64(size)
            index += 1

            // 每 32 MB 刷新一次 UI（够流畅也不至于太频繁）
            if index % 4 == 0 {
                let now = Date()
                let dt = now.timeIntervalSince(lastTick)
                if dt >= 0.3 {
                    let mbps = Double(written - lastBytes) / dt / 1_048_576.0
                    lastTick = now
                    lastBytes = written
                    publishProgress(written: written, speed: mbps)
                } else {
                    publishProgress(written: written, speed: nil)
                }
            }
        }

        publishProgress(written: written, speed: 0)
        return (written, note)
    }

    private func publishProgress(written: Int64, speed: Double?) {
        DispatchQueue.main.async {
            self.writtenThisCycle = written
            if let speed { self.speedMBps = speed }
        }
    }

    // MARK: - 清理

    @discardableResult
    private func clearAll() -> Int64 {
        let fm = FileManager.default
        let dir = Self.fillDirectory
        var removed: Int64 = 0

        guard let items = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        for item in items {
            if let size = (try? item.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                removed += Int64(size)
            }
            try? fm.removeItem(at: item)
        }
        // 用 APFS 的 clone 语义兜底：直接把目录删了也没问题，反正下次会重建
        try? fm.removeItem(at: dir)
        return removed
    }

    private func purgeLeftoversSilently() {
        let dir = Self.fillDirectory
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        _ = clearAll()
    }

    // MARK: - 工具

    private func sleep(seconds: TimeInterval) {
        var remaining = seconds
        while remaining > 0 && !isCancelled {
            Thread.sleep(forTimeInterval: 0.2)
            remaining -= 0.2
        }
    }

    private func appendLog(_ text: String, _ level: LogLine.Level) {
        let line = LogLine(time: Date(), text: text, level: level)
        DispatchQueue.main.async {
            self.logs.append(line)
            if self.logs.count > 400 { self.logs.removeFirst(self.logs.count - 400) }
        }
    }

    private func shortError(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain { return "磁盘空间不足" }
        if ns.domain == NSPOSIXErrorDomain && ns.code == 28 { return "磁盘空间不足" }
        return ns.localizedDescription
    }
}

// MARK: - 格式化

func fmt(_ bytes: Int64) -> String {
    let sign = bytes < 0 ? "-" : ""
    let value = abs(bytes)
    let gb = Double(value) / 1_073_741_824.0
    if gb >= 1 { return sign + String(format: "%.2f GB", gb) }
    let mb = Double(value) / 1_048_576.0
    if mb >= 1 { return sign + String(format: "%.0f MB", mb) }
    return sign + "\(value) B"
}
