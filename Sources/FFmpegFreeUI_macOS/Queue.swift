import AppKit
import Darwin
import Foundation
import Observation
import TranscodeCore

enum JobState: String, Codable {
    case waiting = "等待", running = "编码中", paused = "已暂停", stopping = "正在停止"
    case completed = "已完成", failed = "失败", cancelled = "已停止"

    var active: Bool { [.running, .paused, .stopping].contains(self) }
}

enum JobRecipe: Codable {
    case encode(URL, Preset)
    case mux([URL])
    case concat([URL])

    var input: URL {
        switch self {
        case .encode(let url, _): url
        case .mux(let urls), .concat(let urls): urls[0]
        }
    }

    func arguments(manifest: URL? = nil) throws -> [String] {
        switch self {
        case .encode(let url, let preset):
            try preset.arguments(input: url)
        case .mux(let urls):
            urls.flatMap { ["-i", $0.path] } + urls.indices.flatMap { ["-map", String($0)] } + ["-c", "copy"]
        case .concat:
            ["-f", "concat", "-safe", "0", "-i", manifest?.path ?? "合并列表.ffconcat", "-map", "0", "-c", "copy"]
        }
    }
}

struct EncodeJob: Identifiable, Codable {
    var id = UUID()
    var recipe: JobRecipe
    var output: URL
    var state = JobState.waiting
    var fraction: Double?
    var speed = "—"
    var bitrate = "—"
    var size: Int64?
    var estimatedSize: Int64?
    var elapsed = 0.0
    var eta: Double?
    var log = ""
    var command = ""

    var name: String { output.lastPathComponent }
}

@MainActor
@Observable
final class Queue {
    var jobs: [EncodeJob] = []
    var selected: Set<UUID> = []
    var error: String?
    var runningID: UUID?
    var isProcessing = false

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var pausedAt: Date?
    @ObservationIgnored private var pausedDuration = 0.0
    @ObservationIgnored private let storage: URL

    init(storage: URL = URL.applicationSupportDirectory.appending(path: "FFmpegFreeUI_macOS/queue.json")) {
        self.storage = storage
        if let data = try? Data(contentsOf: storage), let saved = try? JSONDecoder().decode([EncodeJob].self, from: data) {
            jobs = saved.map { job in
                var recovered = job
                if recovered.state.active {
                    recovered.state = .cancelled
                    recovered.log += "\n应用在任务结束前退出。可重置后重新执行。"
                }
                return recovered
            }
        }
    }

    func enqueue(_ inputs: [URL], preset: Preset, folder: URL?) throws {
        let plan = try inputs.map { input in
            _ = try preset.arguments(input: input)
            return (input, try preset.outputName(for: input))
        }
        for (input, name) in plan {
            let output = availableOutput(folder ?? input.deletingLastPathComponent(), name: name)
            jobs.append(EncodeJob(recipe: .encode(input, preset), output: output))
        }
        save()
    }

    func enqueueTool(_ inputs: [URL], mode: String, folder: URL?) throws {
        guard inputs.count >= 2 else { throw EncodingError.invalid("请添加至少两个文件。") }
        if mode == "合并", inputs.contains(where: { $0.path.contains("\n") || $0.path.contains("\r") }) {
            throw EncodingError.invalid("合并列表中的文件路径不能包含换行符。")
        }
        let recipe: JobRecipe = mode == "混流" ? .mux(inputs) : .concat(inputs)
        let name = inputs[0].deletingPathExtension().lastPathComponent + "_" + mode + ".mkv"
        jobs.append(EncodeJob(recipe: recipe, output: availableOutput(folder ?? inputs[0].deletingLastPathComponent(), name: name)))
        save()
    }

    private func availableOutput(_ directory: URL, name: String, excluding: UUID? = nil) -> URL {
        let base = directory.appendingPathComponent(name, isDirectory: false)
        var candidate = base
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) ||
            jobs.contains(where: { $0.id != excluding && $0.output.path == candidate.path }) {
            candidate = directory.appendingPathComponent(base.deletingPathExtension().lastPathComponent + "_\(number)." + base.pathExtension)
            number += 1
        }
        return candidate
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: storage.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(jobs).write(to: storage, options: .atomic)
        } catch {
            self.error = "保存编码队列失败。\(error.localizedDescription)"
        }
    }

    private func update(_ id: UUID, _ change: (inout EncodeJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
    }

    func start(ffmpeg: String, ffprobe: String) {
        guard !isProcessing, jobs.contains(where: { $0.state == .waiting }) else { return }
        do {
            let executable = try Toolchain.executable("ffmpeg", configured: ffmpeg)
            let probe = try? Toolchain.executable("ffprobe", configured: ffprobe)
            isProcessing = true
            Task {
                defer { isProcessing = false }
                while let job = jobs.first(where: { $0.state == .waiting }) {
                    if await run(job, executable: executable, probe: probe) { break }
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func pause() {
        guard let process, process.isRunning, let id = runningID,
              jobs.first(where: { $0.id == id })?.state == .running,
              kill(process.processIdentifier, SIGSTOP) == 0 else { return }
        pausedAt = Date()
        update(id) { $0.state = .paused }
        save()
    }

    func resume() {
        guard let process, process.isRunning, let id = runningID,
              jobs.first(where: { $0.id == id })?.state == .paused,
              kill(process.processIdentifier, SIGCONT) == 0 else { return }
        if let pausedAt { pausedDuration += Date().timeIntervalSince(pausedAt) }
        pausedAt = nil
        update(id) { $0.state = .running }
        save()
    }

    func stop() {
        guard let id = runningID, jobs.first(where: { $0.id == id })?.state != .stopping else { return }
        if let process, process.isRunning {
            _ = kill(process.processIdentifier, SIGTERM)
            _ = kill(process.processIdentifier, SIGCONT)
            Task {
                try? await Task.sleep(for: .seconds(3))
                if self.process === process, process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            }
        }
        update(id) { $0.state = .stopping }
        save()
    }

    func removeSelected() {
        jobs.removeAll { selected.contains($0.id) && !$0.state.active }
        selected.formIntersection(jobs.map(\.id))
        save()
    }

    func resetSelected() {
        for job in jobs where selected.contains(job.id) && !job.state.active && job.state != .waiting {
            let target = availableOutput(job.output.deletingLastPathComponent(), name: job.name, excluding: job.id)
            update(job.id) { $0 = EncodeJob(id: job.id, recipe: job.recipe, output: target) }
        }
        save()
    }

    func command(for job: EncodeJob, configured: String) -> String {
        if !job.command.isEmpty { return job.command }
        let executable = (try? Toolchain.executable("ffmpeg", configured: configured).path) ?? "ffmpeg"
        return CommandLineSyntax.display([executable, "-n"] + ((try? job.recipe.arguments()) ?? []) + [job.output.path])
    }

    private func run(_ job: EncodeJob, executable: URL, probe: URL?) async -> Bool {
        let id = job.id
        runningID = id
        update(id) { $0.state = .running }
        save()
        defer {
            runningID = nil
            process = nil
            pausedAt = nil
            pausedDuration = 0
            save()
        }
        let directory = job.output.deletingLastPathComponent().appending(path: ".3fui-\(UUID())", directoryHint: .isDirectory)
        let temporary = directory.appendingPathComponent(job.name)
        var createdDirectory = false
        defer {
            if createdDirectory { try? FileManager.default.removeItem(at: directory) }
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            createdDirectory = true
            var manifest: URL?
            if case .concat(let urls) = job.recipe {
                let url = directory.appending(path: "inputs.ffconcat")
                let list = ["ffconcat version 1.0"] + urls.map { "file " + CommandLineSyntax.quote($0.path) }
                try (list.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
                manifest = url
            }
            let recipeArguments = try job.recipe.arguments(manifest: manifest)
            update(id) { $0.command = CommandLineSyntax.display([executable.path, "-n"] + recipeArguments + [job.output.path]) }
            let duration = await duration(for: job.recipe, probe: probe)
            guard jobs.first(where: { $0.id == id })?.state != .stopping else {
                update(id) { $0.state = .cancelled }
                return true
            }

            let process = Process()
            let progressPipe = Pipe()
            let logFile = directory.appending(path: "ffmpeg.log")
            guard FileManager.default.createFile(atPath: logFile.path, contents: nil) else {
                throw EncodingError.invalid("无法创建任务日志。")
            }
            let logHandle = try FileHandle(forWritingTo: logFile)
            defer { try? logHandle.close() }
            process.executableURL = executable
            process.arguments = ["-hide_banner", "-nostdin", "-nostats", "-n", "-progress", "pipe:1"] + recipeArguments + [temporary.path]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = progressPipe
            process.standardError = logHandle
            let started = Date()
            try process.run()
            self.process = process

            let status = await Task.detached { [weak self] in
                var buffer = Data()
                var values: [String: String] = [:]
                let reader = progressPipe.fileHandleForReading
                while let data = try? reader.read(upToCount: 4096), !data.isEmpty {
                    buffer.append(data)
                    while let newline = buffer.firstIndex(of: 10) {
                        let line = String(decoding: buffer[..<newline], as: UTF8.self)
                        buffer.removeSubrange(...newline)
                        let pair = line.split(separator: "=", maxSplits: 1)
                        guard pair.count == 2 else { continue }
                        values[String(pair[0])] = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
                        if pair[0] == "progress" {
                            await self?.record(ProgressUpdate(values), id: id, duration: duration, started: started)
                            values.removeAll(keepingCapacity: true)
                        }
                    }
                }
                process.waitUntilExit()
                return process.terminationStatus
            }.value

            let log = (try? FileHandle(forReadingFrom: logFile)).map { handle in
                defer { try? handle.close() }
                if let length = try? handle.seekToEnd() { try? handle.seek(toOffset: length > 262_144 ? length - 262_144 : 0) }
                return String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
            } ?? ""
            update(id) {
                $0.log = log
                $0.elapsed = max(0, (pausedAt ?? Date()).timeIntervalSince(started) - pausedDuration)
            }
            if jobs.first(where: { $0.id == id })?.state == .stopping {
                update(id) { $0.state = .cancelled }
                return true
            }
            guard status == 0 else { throw EncodingError.invalid("FFmpeg 退出代码 \(status)。") }

            // Rename atomically while rejecting a destination created after enqueueing.
            guard renamex_np(temporary.path, job.output.path, UInt32(RENAME_EXCL)) == 0 else {
                let reason = String(cString: strerror(errno))
                throw EncodingError.invalid("无法保存输出文件。\(reason)")
            }
            let size = try? job.output.resourceValues(forKeys: [.fileSizeKey]).fileSize
            update(id) {
                $0.state = .completed
                $0.fraction = 1
                $0.size = size.map(Int64.init) ?? $0.size
                $0.estimatedSize = nil
                $0.eta = nil
            }
        } catch {
            update(id) {
                $0.state = .failed
                $0.log += "\n" + error.localizedDescription
            }
        }
        return false
    }

    private func duration(for recipe: JobRecipe, probe: URL?) async -> Double? {
        guard let probe else { return nil }
        func readDuration(_ url: URL) async -> Double? {
            guard let value = try? await Toolchain.capture(probe, [
                "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", url.path
            ]) else { return nil }
            return CommandLineSyntax.seconds(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        switch recipe {
        case .encode(let input, let preset):
            let full = await readDuration(input)
            let remaining = full.map { max(0, $0 - (CommandLineSyntax.seconds(preset.start) ?? 0)) }
            guard let cap = CommandLineSyntax.seconds(preset.duration) else { return remaining }
            return min(cap, remaining ?? cap)
        case .concat(let urls), .mux(let urls):
            var times: [Double] = []
            for url in urls {
                guard let time = await readDuration(url) else { return nil }
                times.append(time)
            }
            if case .concat = recipe { return times.reduce(0, +) }
            return times.max()
        }
    }

    private func record(_ report: ProgressUpdate, id: UUID, duration: Double?, started: Date) {
        let elapsed = max(0, (pausedAt ?? Date()).timeIntervalSince(started) - pausedDuration)
        update(id) { job in
            job.speed = report.speed ?? job.speed
            job.bitrate = report.bitrate ?? job.bitrate
            if let bytes = report.bytes, bytes >= 0 { job.size = bytes }
            job.elapsed = elapsed
            if let duration, duration > 0, let seconds = report.seconds, seconds.isFinite, seconds > 0 {
                let fraction = min(0.999, seconds / duration)
                job.fraction = fraction
                job.eta = elapsed * (1 - fraction) / fraction
                if let bytes = job.size, let estimate = Int64(exactly: (Double(bytes) / fraction).rounded()) {
                    job.estimatedSize = estimate
                }
            }
        }
    }
}
