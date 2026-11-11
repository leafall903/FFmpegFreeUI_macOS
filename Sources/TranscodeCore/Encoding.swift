import Foundation

public enum EncodingError: LocalizedError {
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        }
    }
}

public struct Preset: Codable, Equatable, Sendable {
    public var container = "mp4"
    public var suffix = "_3FUI"
    public var fastStart = true
    public var hardwareDecode = false
    public var video = "libx264"
    public var speed = "medium"
    public var qualityOption = "crf"
    public var quality = "23"
    public var videoBitrate = ""
    public var pixelFormat = "yuv420p"
    public var colorSpace = ""
    public var colorPrimaries = ""
    public var transfer = ""
    public var colorRange = ""
    public var audio = "aac"
    public var audioBitrate = "192k"
    public var channels = ""
    public var sampleRate = ""
    public var scale = ""
    public var crop = ""
    public var frameRate = ""
    public var start = ""
    public var duration = ""
    public var filters = ""
    public var audioFilters = ""
    public var streams = ""
    public var subtitles = "默认"
    public var metadata = true
    public var chapters = true
    public var inputOptions = ""
    public var outputOptions = ""

    public init() {}

    public static func template(_ name: String) -> Preset {
        var preset = Preset()
        switch name {
        case "H.265 软件压制":
            preset.video = "libx265"
            preset.quality = "26"
            preset.pixelFormat = "yuv420p10le"
        case "H.265 VideoToolbox", "H.264 VideoToolbox":
            preset.video = name.hasPrefix("H.265") ? "hevc_videotoolbox" : "h264_videotoolbox"
            preset.speed = ""
            preset.quality = ""
            preset.videoBitrate = "5M"
        case "AV1 软件压制":
            preset.container = "mkv"
            preset.video = "libsvtav1"
            preset.speed = "6"
            preset.quality = "34"
            preset.pixelFormat = "yuv420p10le"
            preset.audio = "libopus"
        case "MKV 无损重封装":
            preset.container = "mkv"
            preset.video = "copy"
            preset.audio = "copy"
            preset.streams = "0"
            preset.subtitles = "复制"
        case "提取音频 M4A":
            preset.container = "m4a"
            preset.video = "关闭"
        default: break
        }
        return preset
    }

    public static func subtitleFilter(for url: URL) -> String {
        func escape(_ value: String, special: String) -> String {
            value.reduce(into: "") { result, character in
                if special.contains(character) { result.append("\\") }
                result.append(character)
            }
        }
        let option = escape(url.path, special: "\\':")
        return "subtitles=filename=" + escape(option, special: "\\'[],;")
    }

    public func outputName(for input: URL) throws -> String {
        let ext = container.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !ext.isEmpty, ext.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }),
              !suffix.contains("/"), !suffix.contains("\0") else {
            throw EncodingError.invalid("封装扩展名或文件名后缀无效。")
        }
        return input.deletingPathExtension().lastPathComponent + suffix + "." + ext.lowercased()
    }

    public func arguments(input: URL) throws -> [String] {
        var args: [String] = []
        func add(_ flag: String, _ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { args += [flag, trimmed] }
        }
        if hardwareDecode { args += ["-hwaccel", "videotoolbox"] }
        add("-ss", start)
        args += try CommandLineSyntax.split(inputOptions)
        args += ["-i", input.path]
        add("-t", duration)
        for stream in streams.split(whereSeparator: { $0 == "," || $0.isWhitespace }) {
            add("-map", String(stream))
        }
        if video == "关闭" {
            args.append("-vn")
        } else {
            add("-c:v", video)
            if video != "copy" {
                if !video.hasSuffix("_videotoolbox") { add("-preset", speed) }
                if video == "libaom-av1", let index = args.lastIndex(of: "-preset") { args[index] = "-cpu-used" }
                if !quality.isEmpty, qualityOption != "crf" || !video.hasSuffix("_videotoolbox") {
                    guard !qualityOption.isEmpty, qualityOption.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }),
                          !qualityOption.hasPrefix("-") else {
                        throw EncodingError.invalid("质量参数名无效，例如 crf 或 q。")
                    }
                    add("-" + qualityOption, quality)
                }
                add("-b:v", videoBitrate)
                add("-pix_fmt", pixelFormat)
                add("-colorspace", colorSpace)
                add("-color_primaries", colorPrimaries)
                add("-color_trc", transfer)
                add("-color_range", colorRange)
                add("-r", frameRate)
                let chain = [crop.isEmpty ? "" : "crop=" + crop, scale.isEmpty ? "" : "scale=" + scale, filters]
                add("-vf", chain.filter { !$0.isEmpty }.joined(separator: ","))
                if container.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) == "mp4", video.hasPrefix("hevc") || video == "libx265" {
                    args += ["-tag:v", "hvc1"]
                }
            }
        }
        if audio == "关闭" {
            args.append("-an")
        } else {
            add("-c:a", audio)
            if audio != "copy" {
                add("-b:a", audioBitrate)
                add("-ac", channels)
                add("-ar", sampleRate)
                add("-af", audioFilters)
            }
        }
        switch subtitles {
        case "关闭": args.append("-sn")
        case "复制": args += ["-c:s", "copy"]
        case "转为 mov_text": args += ["-c:s", "mov_text"]
        default: break
        }
        if !metadata { args += ["-map_metadata", "-1"] }
        if !chapters { args += ["-map_chapters", "-1"] }
        if fastStart, ["mp4", "mov", "m4a"].contains(container.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))) {
            args += ["-movflags", "+faststart"]
        }
        args += try CommandLineSyntax.split(outputOptions)
        return args
    }
}

public enum CommandLineSyntax {
    public static func split(_ text: String) throws -> [String] {
        var result: [String] = []
        var token = ""
        var quote: Character?
        var escaping = false
        var started = false
        for character in text {
            if escaping {
                token.append(character)
                escaping = false
            } else if character == "\\", quote != "'" {
                escaping = true
                started = true
            } else if let open = quote {
                if open == character { quote = nil } else { token.append(character) }
            } else if character == "'" || character == "\"" {
                quote = character
                started = true
            } else if character.isWhitespace {
                if started { result.append(token) }
                token = ""
                started = false
            } else {
                token.append(character)
                started = true
            }
        }
        guard quote == nil, !escaping else {
            throw EncodingError.invalid("自定义参数中有未闭合的引号或转义符。")
        }
        if started { result.append(token) }
        return result
    }

    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func display(_ arguments: [String]) -> String {
        arguments.map { value in
            let simple = !value.isEmpty && value.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 47, 58, 61, 95].contains($0)
            }
            return simple ? value : quote(value)
        }.joined(separator: " ")
    }

    public static func seconds(_ timestamp: String) -> Double? {
        let parts = timestamp.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var seconds = 0.0
        for part in parts {
            guard let number = Double(part), number.isFinite, number >= 0 else { return nil }
            seconds = seconds * 60 + number
        }
        return seconds.isFinite ? seconds : nil
    }
}

public struct ProgressUpdate: Sendable {
    public var seconds: Double?
    public var speed: String?
    public var bytes: Int64?
    public var bitrate: String?
    public var frame: Int?

    public init(_ values: [String: String]) {
        seconds = values["out_time_us"].flatMap(Double.init).map { $0 / 1_000_000 }
        speed = values["speed"].flatMap { $0 == "N/A" ? nil : $0 }
        bytes = values["total_size"].flatMap(Int64.init)
        bitrate = values["bitrate"].flatMap { $0 == "N/A" ? nil : $0 }
        frame = values["frame"].flatMap(Int.init)
    }
}

public enum Toolchain {
    public static func executable(_ name: String, configured: String = "") throws -> URL {
        let manager = FileManager.default
        if !configured.isEmpty {
            let url = URL(fileURLWithPath: configured)
            guard manager.isExecutableFile(atPath: url.path), (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == false else {
                throw EncodingError.invalid("无法执行 \(url.path)。请在软件设置中重新选择。")
            }
            return url
        }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin"] + path.split(separator: ":").map(String.init) {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
            if manager.isExecutableFile(atPath: url.path) { return url }
        }
        throw EncodingError.invalid("找不到 \(name)。请安装 FFmpeg 或在软件设置中选择可执行文件。")
    }

    public static func capture(_ executable: URL, _ arguments: [String]) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
            guard process.terminationStatus == 0 else {
                throw EncodingError.invalid(text.isEmpty ? "退出代码 \(process.terminationStatus)" : text)
            }
            return text
        }.value
    }
}
