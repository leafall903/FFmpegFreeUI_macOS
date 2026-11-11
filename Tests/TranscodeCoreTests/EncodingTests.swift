import Foundation
import Testing
import TranscodeCore
@testable import FFmpegFreeUI_macOS

@Test func customParametersPreserveArguments() throws {
    let args = ["-metadata", "title=标题 '带空格'", "-vf", "scale=1920:-2", ""]
    #expect(try CommandLineSyntax.split(CommandLineSyntax.display(args)) == args)
    #expect(throws: EncodingError.self) { try CommandLineSyntax.split("-metadata 'unfinished") }
}

@Test func remuxSkipsTranscodingOptions() throws {
    var preset = Preset.template("MKV 无损重封装")
    preset.scale = "1280:-2"
    let args = try preset.arguments(input: URL(fileURLWithPath: "/tmp/测试 视频.mkv"))
    #expect(args == ["-i", "/tmp/测试 视频.mkv", "-map", "0", "-c:v", "copy", "-c:a", "copy", "-c:s", "copy"])
}

@Test func hardwareAndAudioPresetsUseCompatibleOptions() throws {
    let url = URL(fileURLWithPath: "/tmp/源文件.mov")
    let hardware = try Preset.template("H.265 VideoToolbox").arguments(input: url)
    #expect(hardware.contains("hevc_videotoolbox"))
    #expect(hardware.contains("hvc1"))
    #expect(!hardware.contains("-crf"))
    #expect(!hardware.contains("-preset"))

    let audio = Preset.template("提取音频 M4A")
    #expect(try audio.arguments(input: url).contains("-vn"))
    #expect(try audio.outputName(for: url) == "源文件_3FUI.m4a")
}

@Test @MainActor func transcodeConcatAndProtectExistingOutput() async throws {
    guard let ffmpeg = try? Toolchain.executable("ffmpeg"), let ffprobe = try? Toolchain.executable("ffprobe") else { return }
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }

    let input = directory.appending(path: "测试 ' 一.mp4")
    let second = directory.appending(path: "测试二.mp4")
    _ = try await Toolchain.capture(ffmpeg, [
        "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=160x90:rate=24",
        "-f", "lavfi", "-i", "sine=frequency=440", "-t", "1", "-c:v", "mpeg4", "-c:a", "aac", input.path
    ])
    try FileManager.default.copyItem(at: input, to: second)
    let storage = directory.appending(path: "queue.json")
    let queue = Queue(storage: storage)
    var preset = Preset()
    preset.video = "mpeg4"
    preset.qualityOption = "q"
    preset.quality = "3"
    preset.speed = ""
    try queue.enqueue([input, second], preset: preset, folder: directory)
    try queue.enqueueTool([input, second], mode: "合并", folder: directory)
    try queue.enqueueTool([input, second], mode: "混流", folder: directory)
    let occupied = queue.jobs[1].output
    let marker = Data("preserve".utf8)
    try marker.write(to: occupied)
    queue.start(ffmpeg: ffmpeg.path, ffprobe: ffprobe.path)
    for _ in 0..<300 where queue.isProcessing { try await Task.sleep(for: .milliseconds(50)) }
    #expect(!queue.isProcessing)
    #expect(queue.jobs.map(\.state) == [.completed, .failed, .completed, .completed], "\(queue.jobs.map(\.log))")
    #expect(try Data(contentsOf: occupied) == marker)
    #expect(Queue(storage: storage).jobs.map(\.state) == queue.jobs.map(\.state))
    let probe = try await Toolchain.capture(ffprobe, ["-v", "error", "-show_entries", "stream=codec_name", "-of", "csv=p=0", queue.jobs[0].output.path])
    #expect(probe.contains("mpeg4"))
    #expect(probe.contains("aac"))
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy { !$0.hasPrefix(".3fui-") })
}

@Test func subtitleFilterHandlesFFmpegEscaping() async throws {
    guard let ffmpeg = try? Toolchain.executable("ffmpeg") else { return }
    let filters = try await Toolchain.capture(ffmpeg, ["-hide_banner", "-filters"])
    guard filters.contains(" subtitles ") else { return }
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: "字幕 [A]' : ,;.srt")
    try "1\n00:00:00,000 --> 00:00:01,000\n3FUI\n".write(to: file, atomically: true, encoding: .utf8)
    _ = try await Toolchain.capture(ffmpeg, [
        "-v", "error", "-f", "lavfi", "-i", "color=size=160x90",
        "-vf", Preset.subtitleFilter(for: file), "-frames:v", "1", "-f", "null", "-"
    ])
}

@Test @MainActor func pauseResumeAndStopPreservePendingJobs() async throws {
    guard let ffmpeg = try? Toolchain.executable("ffmpeg"), let ffprobe = try? Toolchain.executable("ffprobe") else { return }
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }

    let input = directory.appending(path: "input.mp4")
    _ = try await Toolchain.capture(ffmpeg, [
        "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=160x90:rate=24",
        "-t", "8", "-c:v", "mpeg4", input.path
    ])
    let queue = Queue(storage: directory.appending(path: "queue.json"))
    var preset = Preset.template("MKV 无损重封装")
    preset.inputOptions = "-re"
    try queue.enqueue([input, input], preset: preset, folder: directory)
    queue.start(ffmpeg: ffmpeg.path, ffprobe: ffprobe.path)
    for _ in 0..<80 {
        queue.pause()
        if queue.jobs[0].state == .paused { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(queue.jobs[0].state == .paused)
    queue.resume()
    #expect(queue.jobs[0].state == .running)
    queue.stop()
    for _ in 0..<100 where queue.isProcessing { try await Task.sleep(for: .milliseconds(50)) }
    #expect(queue.jobs.map(\.state) == [.cancelled, .waiting])
    #expect(!queue.isProcessing)
    #expect(!FileManager.default.fileExists(atPath: queue.jobs[0].output.path))
}
