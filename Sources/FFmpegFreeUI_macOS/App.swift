import AppKit
import SwiftUI
import TranscodeCore

@main
struct FFmpegFreeUIApp: App {
    @State private var model = Workspace()

    var body: some Scene {
        Window("FFmpegFreeUI", id: "workspace") {
            WorkspaceView(model: model)
                .frame(minWidth: 980, minHeight: 620)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1240, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("添加文件…") { model.chooseInputs() }
                    .keyboardShortcut("o")
                Button("添加到编码队列") { model.enqueue() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.inputs.isEmpty)
            }
            CommandMenu("编码") {
                Button("开始队列") { model.start() }.keyboardShortcut("r")
                Button("暂停") { model.queue.pause() }
                Button("恢复") { model.queue.resume() }
                Button("停止当前任务") { model.queue.stop() }
            }
        }
        Settings {
            SettingsView(model: model)
                .frame(width: 630)
                .padding(24)
        }
    }
}

enum Page: String, CaseIterable, Identifiable {
    case home = "起始页面", queue = "编码队列", files = "准备文件", parameters = "参数面板"
    case probe = "ffprobe 媒体信息", player = "ffplay 调试播放器", tools = "集成工具"
    case settings = "软件设置"

    var id: Self { self }
    var icon: String {
        switch self {
        case .home: "house"
        case .queue: "list.bullet.rectangle"
        case .files: "folder"
        case .parameters: "slider.horizontal.3"
        case .probe: "info.circle"
        case .player: "play.rectangle"
        case .tools: "wrench.and.screwdriver"
        case .settings: "gearshape"
        }
    }

    static let groups: [[Page]] = [[.home, .queue], [.files, .parameters], [.probe, .player, .tools], [.settings]]
}

@MainActor
@Observable
final class Workspace {
    var page = Page.home
    var inputs: [URL] = []
    var selectedInputs: Set<URL> = []
    var preset = Preset()
    var outputFolder: URL?
    let queue = Queue()

    var ffmpeg = UserDefaults.standard.string(forKey: "ffmpeg") ?? "" {
        didSet { UserDefaults.standard.set(ffmpeg, forKey: "ffmpeg") }
    }
    var ffprobe = UserDefaults.standard.string(forKey: "ffprobe") ?? "" {
        didSet { UserDefaults.standard.set(ffprobe, forKey: "ffprobe") }
    }
    var ffplay = UserDefaults.standard.string(forKey: "ffplay") ?? "" {
        didSet { UserDefaults.standard.set(ffplay, forKey: "ffplay") }
    }

    static func open(files: Bool = true, folders: Bool = false, multiple: Bool = false) -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = files
        panel.canChooseDirectories = folders
        panel.allowsMultipleSelection = multiple
        panel.canCreateDirectories = folders
        return panel.runModal() == .OK ? panel.urls : []
    }

    func chooseInputs() {
        addInputs(Self.open(files: true, folders: true, multiple: true))
    }

    func addInputs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        var known = Set(inputs)
        let manager = FileManager.default
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values?.isDirectory == true,
               let files = manager.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                let collected = files.compactMap { $0 as? URL }.filter {
                    (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                inputs += collected.filter { known.insert($0.standardizedFileURL).inserted }.map(\.standardizedFileURL)
            } else if values?.isRegularFile == true, known.insert(url.standardizedFileURL).inserted {
                inputs.append(url.standardizedFileURL)
            }
        }
        page = .files
    }

    func enqueue() {
        guard !inputs.isEmpty else { return }
        do {
            try queue.enqueue(inputs, preset: preset, folder: outputFolder)
            page = .queue
        } catch {
            queue.error = error.localizedDescription
        }
    }

    func start() { queue.start(ffmpeg: ffmpeg, ffprobe: ffprobe) }

    func importPreset() {
        guard let url = Self.open().first else { return }
        do {
            preset = try JSONDecoder().decode(Preset.self, from: Data(contentsOf: url))
        } catch {
            queue.error = "无法导入 macOS 预设。\(error.localizedDescription)"
        }
    }

    func exportPreset() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "编码预设.3fui-macos.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(preset).write(to: url, options: .atomic)
        } catch {
            queue.error = error.localizedDescription
        }
    }
}

struct WorkspaceView: View {
    @Bindable var model: Workspace
    @State private var search = ""

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            Group {
                switch model.page {
                case .home: home
                case .queue: QueueView(model: model)
                case .files: FilesView(model: model)
                case .parameters: ParametersView(model: model)
                case .probe: MediaToolView(model: model, play: false)
                case .player: MediaToolView(model: model, play: true)
                case .tools: ToolsView(model: model)
                case .settings: SettingsView(model: model).padding(24)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                LinearGradient(colors: [Color(red: 0.08, green: 0.10, blue: 0.14), Color(nsColor: .windowBackgroundColor)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .alert("FFmpegFreeUI", isPresented: Binding(get: { model.queue.error != nil }, set: { if !$0 { model.queue.error = nil } })) {
            Button("好", role: .cancel) { model.queue.error = nil }
        } message: {
            Text(model.queue.error ?? "")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up.fill").foregroundStyle(.blue)
                Text("FFmpegFreeUI").font(.headline)
            }
            .padding(.horizontal, 8)
            TextField("搜索选项标题", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 4)
                .accessibilityLabel("搜索选项标题")
            ForEach(Array(Page.groups.enumerated()), id: \.offset) { _, group in
                let visible = group.filter { search.isEmpty || $0.rawValue.localizedCaseInsensitiveContains(search) }
                if !visible.isEmpty {
                    VStack(spacing: 3) {
                        ForEach(visible) { page in
                            Button { model.page = page } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: page.icon).frame(width: 18)
                                    Text(page.rawValue).lineLimit(1)
                                    Spacer(minLength: 0)
                                    if page == .queue, model.queue.isProcessing {
                                        Circle().fill(.green).frame(width: 6, height: 6)
                                    }
                                }
                                .font(.system(size: 12, weight: model.page == page ? .semibold : .regular))
                                .padding(.horizontal, 9)
                                .frame(height: 30)
                                .contentShape(Rectangle())
                                .background(model.page == page ? Color.accentColor.opacity(0.23) : .clear, in: RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            Spacer()
            Label("macOS", systemImage: "apple.logo").font(.caption).foregroundStyle(.secondary).padding(8)
        }
        .padding(12)
        .frame(width: 190)
        .background(.ultraThinMaterial)
    }

    private var home: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("起始页面").font(.largeTitle.bold())
            Text("批量转码、压制和媒体检查").font(.title3).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("添加文件…", systemImage: "plus") { model.chooseInputs() }
                    .buttonStyle(.borderedProminent)
                Button("打开参数面板", systemImage: "slider.horizontal.3") { model.page = .parameters }
                Button("查看编码队列", systemImage: "list.bullet.rectangle") { model.page = .queue }
            }
            Divider()
            let executable = try? Toolchain.executable("ffmpeg", configured: model.ffmpeg)
            Label(executable?.path ?? "请在软件设置中配置 FFmpeg", systemImage: executable == nil ? "exclamationmark.circle" : "checkmark.circle")
                .foregroundStyle(executable == nil ? Color.orange : Color.secondary)
            Spacer()
        }
        .padding(28)
        .dropDestination(for: URL.self) { urls, _ in model.addInputs(urls); return !urls.isEmpty }
    }
}

struct FilesView: View {
    @Bindable var model: Workspace

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("准备文件").font(.title.bold())
            HStack {
                Button("添加文件…", systemImage: "plus") { model.chooseInputs() }
                Button("移除", systemImage: "minus") {
                    model.inputs.removeAll { model.selectedInputs.contains($0) }
                    model.selectedInputs.removeAll()
                }.disabled(model.selectedInputs.isEmpty)
                Spacer()
                Text("\(model.inputs.count) 个文件").foregroundStyle(.secondary)
            }
            Table(model.inputs.map(InputRow.init), selection: $model.selectedInputs) {
                TableColumn("文件名") { Text($0.url.lastPathComponent) }.width(min: 170, ideal: 245)
                TableColumn("所在目录") { Text($0.url.deletingLastPathComponent().path).foregroundStyle(.secondary) }
            }
            .overlay {
                if model.inputs.isEmpty {
                    ContentUnavailableView("拖入媒体文件或文件夹", systemImage: "tray.and.arrow.down")
                        .allowsHitTesting(false)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in model.addInputs(urls); return !urls.isEmpty }
            HStack {
                Button("选择输出目录…", systemImage: "folder") {
                    if let folder = Workspace.open(files: false, folders: true).first { model.outputFolder = folder }
                }
                Text(model.outputFolder?.path ?? "源文件所在目录").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if model.outputFolder != nil { Button("恢复默认") { model.outputFolder = nil } }
                Spacer()
                Button("参数面板") { model.page = .parameters }
                Button("添加到编码队列") { model.enqueue() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.inputs.isEmpty)
            }
        }
        .padding(22)
    }

    private struct InputRow: Identifiable {
        let url: URL
        var id: URL { url }
    }
}

struct QueueView: View {
    @Bindable var model: Workspace
    @State private var inspected: EncodeJob?
    var activeState: JobState? { model.queue.jobs.first(where: { $0.id == model.queue.runningID })?.state }

    var body: some View {
        @Bindable var queue = model.queue
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("编码队列").font(.title.bold())
                Spacer()
                Text("总数 \(queue.jobs.count)   运行 \(queue.runningID == nil ? 0 : 1)   错误 \(queue.jobs.filter { $0.state == .failed }.count)")
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack {
                Button("开始", systemImage: "play.fill") { model.start() }
                    .buttonStyle(.borderedProminent)
                    .disabled(queue.isProcessing || !queue.jobs.contains { $0.state == .waiting })
                Button("暂停", systemImage: "pause") { queue.pause() }.disabled(activeState != .running)
                Button("恢复", systemImage: "forward") { queue.resume() }.disabled(activeState != .paused)
                Button("停止", systemImage: "stop") { queue.stop() }.disabled(activeState == nil || activeState == .stopping)
                Divider().frame(height: 18)
                Button("移除") { queue.removeSelected() }.disabled(queue.selected.isEmpty)
                Button("重置") { queue.resetSelected() }.disabled(queue.selected.isEmpty)
                Button("定位") {
                    NSWorkspace.shared.activateFileViewerSelecting(queue.jobs.filter { queue.selected.contains($0.id) && $0.state == .completed }.map(\.output))
                }.disabled(!queue.jobs.contains { queue.selected.contains($0.id) && $0.state == .completed })
                Spacer()
                Button("查看参数和日志") { inspected = queue.jobs.first { queue.selected.contains($0.id) } }.disabled(queue.selected.isEmpty)
            }
            Table(queue.jobs, selection: $queue.selected) {
                TableColumn("任务名称") { Text($0.name).help($0.output.path) }.width(min: 145, ideal: 205)
                TableColumn("状态") { job in
                    Text(job.state.rawValue).foregroundStyle(job.state == .failed ? Color.red : job.state == .completed ? Color.green : Color.primary)
                }.width(64)
                TableColumn("进度") { job in
                    if let fraction = job.fraction {
                        ProgressView(value: fraction).help(fraction.formatted(.percent.precision(.fractionLength(1))))
                    } else if job.state == .running {
                        ProgressView().controlSize(.small)
                    } else { Text("—") }
                }.width(68)
                TableColumn("效率", value: \.speed).width(58)
                TableColumn("输出大小 · 预估") { job in
                    Text([job.size, job.estimatedSize].compactMap { $0 }.map {
                        ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
                    }.joined(separator: " / ")).monospacedDigit()
                }.width(min: 94, ideal: 125)
                TableColumn("比特率", value: \.bitrate).width(min: 70, ideal: 90)
                TableColumn("剩余 · 已用") { job in
                    Text([job.eta, job.elapsed].map { value in
                        guard let value, value.isFinite, value < Double(Int.max) else { return "—" }
                        let seconds = Int(value)
                        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
                    }.joined(separator: " / ")).monospacedDigit()
                }.width(min: 87, ideal: 115)
            }
            .overlay {
                if queue.jobs.isEmpty {
                    ContentUnavailableView("编码队列为空", systemImage: "list.bullet.rectangle",
                                           description: Text("在准备文件页面添加媒体并设置参数。"))
                        .allowsHitTesting(false)
                }
            }
        }
        .padding(22)
        .sheet(item: $inspected) { job in
            VStack(alignment: .leading, spacing: 12) {
                Text(job.name).font(.title2.bold())
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(queue.command(for: job, configured: model.ffmpeg))
                        Divider()
                        Text(job.log.isEmpty ? "暂无日志" : job.log)
                    }.font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button("关闭") { inspected = nil }.keyboardShortcut(.cancelAction)
            }.padding(24).frame(width: 800, height: 500)
        }
    }
}
