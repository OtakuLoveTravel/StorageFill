//
//  ContentView.swift
//  StorageFill
//

import SwiftUI
import UIKit

struct ContentView: View {

    @StateObject private var engine = StorageEngine()

    @State private var reserveMB: Int = 500
    @State private var cycles: Int = 3
    @State private var showDetailLog: Bool = true

    private let reserveOptions = [200, 500, 1024, 2048]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    heroCard
                    configCard
                    startButton
                    if engine.currentCycle > 0 { progressCard }
                    logCard
                    noteCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("存储清洗")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { engine.refreshFreeSpace() }
        }
    }

    // MARK: - 顶部空间卡片

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("当前可用空间", systemImage: "internaldrive")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(engine.phase.rawValue)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(phaseColor.opacity(0.16))
                    .foregroundStyle(phaseColor)
                    .clipShape(Capsule())
            }

            Text(fmt(engine.freeBytes))
                .font(.system(size: 38, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)

            if let freed = engine.lastFreed {
                Text(freed >= 0
                     ? "上一轮结束后净增 \(fmt(freed))"
                     : "上一轮结束后净减 \(fmt(-freed))")
                    .font(.footnote)
                    .foregroundStyle(freed >= 0 ? .green : .orange)
            } else {
                Text("写入到「可用空间 − 保留余量」后自动删除，反复若干轮")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var phaseColor: Color {
        switch engine.phase {
        case .idle:      return .secondary
        case .filling:   return .blue
        case .clearing:  return .orange
        case .cooldown:  return .purple
        case .finished:  return .green
        case .stopped:   return .red
        }
    }

    // MARK: - 参数

    private var configCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("参数")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("保留余量")
                    Spacer()
                    Text(reserveMB >= 1024 ? String(format: "%.1f GB", Double(reserveMB) / 1024) : "\(reserveMB) MB")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .font(.subheadline)

                Picker("保留余量", selection: $reserveMB) {
                    ForEach(reserveOptions, id: \.self) { mb in
                        Text(mb >= 1024 ? String(format: "%.0f GB", Double(mb) / 1024) : "\(mb) MB")
                            .tag(mb)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(engine.isRunning)

                Text("留得越多越安全。500 MB 足够触发系统回收，又不会让手机卡死。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Text("循环轮数")
                    .font(.subheadline)
                Spacer()
                Stepper(value: $cycles, in: 1...20) {
                    Text("\(cycles) 轮")
                        .font(.subheadline.weight(.medium))
                        .monospacedDigit()
                }
                .disabled(engine.isRunning)
            }
        }
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: - 按钮

    private var startButton: some View {
        Button {
            if engine.isRunning {
                engine.stop()
            } else {
                engine.start(reserveBytes: Int64(reserveMB) * 1_048_576, cycles: cycles)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: engine.isRunning ? "stop.fill" : "bolt.fill")
                Text(engine.isRunning ? "停止" : "开始清洗")
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(engine.isRunning ? Color.red : Color.accentColor)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 进度

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("第 \(engine.currentCycle)/\(engine.plannedCycles) 轮 · \(engine.phase.rawValue)")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(String(format: "%.0f MB/s", engine.speedMBps))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            ProgressView(value: progressValue)
                .tint(phaseColor)

            HStack {
                Text("已写 \(fmt(engine.writtenThisCycle))")
                Spacer()
                Text("目标 \(fmt(engine.targetThisCycle))")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var progressValue: Double {
        guard engine.targetThisCycle > 0 else { return 0 }
        return min(1, Double(engine.writtenThisCycle) / Double(engine.targetThisCycle))
    }

    // MARK: - 日志

    private var logCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showDetailLog.toggle() }
            } label: {
                HStack {
                    Text("运行日志")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: showDetailLog ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)

            if showDetailLog {
                if engine.logs.isEmpty {
                    Text("还没有记录")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(engine.logs) { line in
                                    Text(line.text)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(color(for: line.level))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .id(line.id)
                                }
                            }
                            .padding(10)
                        }
                        .frame(height: 170)
                        .background(Color(.systemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .onChange(of: engine.logs.count) { _ in
                            if let last = engine.logs.last {
                                withAnimation(.linear(duration: 0.15)) {
                                    proxy.scrollTo(last.id, anchor: .bottom)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func color(for level: StorageEngine.LogLine.Level) -> Color {
        switch level {
        case .info: return .primary
        case .good: return .green
        case .warn: return .orange
        }
    }

    // MARK: - 说明

    private var noteCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("怎么用", systemImage: "info.circle")
                .font(.subheadline.weight(.semibold))
            Text("1. 保持 App 在前台，别锁屏，运行期间手机可能发烫、变卡。")
            Text("2. 全程需要几分钟到十几分钟，取决于剩余空间大小。")
            Text("3. iOS 沙盒限制：App 只能写自己的目录，删除后能还回来的就是自己写的那部分；真正被“洗掉”的额外空间，是系统在此期间回收的缓存。")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
