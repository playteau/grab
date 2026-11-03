import SwiftUI
import AppKit

// MARK: - Tool discovery

enum Tools {
    static let searchDirs = [
        "/opt/homebrew/bin",   // Apple Silicon Homebrew
        "/usr/local/bin",      // Intel Homebrew
        "/opt/local/bin",      // MacPorts
        "/usr/bin",
    ]

    static func find(_ name: String) -> String? {
        let fm = FileManager.default
        for dir in searchDirs {
            let path = "\(dir)/\(name)"
            if fm.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }
}

// MARK: - Download options

enum Mode: String, CaseIterable, Identifiable {
    case video = "Video (MP4)"
    case audio = "Audio (MP3)"
    var id: String { rawValue }
}

enum Quality: String, CaseIterable, Identifiable {
    case best = "Best"
    case p1080 = "1080p"
    case p720 = "720p"
    case p480 = "480p"
    var id: String { rawValue }

    var height: Int? {
        switch self {
        case .best: return nil
        case .p1080: return 1080
        case .p720: return 720
        case .p480: return 480
        }
    }
}

// MARK: - Line buffering

/// Accumulates raw pipe data and returns complete lines. Only touched from the pipe's handler queue.
final class LineBuffer: @unchecked Sendable {
    private var data = Data()

    func append(_ chunk: Data) -> [String] {
        data.append(chunk)
        var lines: [String] = []
        while let nl = data.firstIndex(of: 0x0A) {
            let lineData = data.subdata(in: data.startIndex..<nl)
            data.removeSubrange(data.startIndex...nl)
            if let s = String(data: lineData, encoding: .utf8) { lines.append(s) }
        }
        return lines
    }
}

// MARK: - Downloader

@MainActor
final class Downloader: ObservableObject {
    @Published var url = ""
    @Published var mode: Mode = .video
    @Published var quality: Quality = .best
    @Published var destination: URL = FileManager.default
        .urls(for: .downloadsDirectory, in: .userDomainMask).first!
    @Published var progress: Double = 0
    @Published var status = "Ready"
    @Published var log = ""
    @Published var isRunning = false
    @Published var finishedFile: URL?

    private var process: Process?
    private var cancelled = false

    var ytdlpPath: String? { Tools.find("yt-dlp") }
    var ffmpegPath: String? { Tools.find("ffmpeg") }

    var missingToolsMessage: String? {
        var missing: [String] = []
        if ytdlpPath == nil { missing.append("yt-dlp") }
        if ffmpegPath == nil { missing.append("ffmpeg") }
        if missing.isEmpty { return nil }
        return "Missing: \(missing.joined(separator: ", ")). Install with:  brew install \(missing.joined(separator: " "))"
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = destination
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let picked = panel.url {
            destination = picked
        }
    }

    func pasteFromClipboard() {
        if let s = NSPasteboard.general.string(forType: .string) {
            url = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func revealInFinder() {
        if let f = finishedFile {
            NSWorkspace.shared.activateFileViewerSelecting([f])
        } else {
            NSWorkspace.shared.open(destination)
        }
    }

    func cancel() {
        cancelled = true
        process?.terminate()
    }

    func start() {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let link = URL(string: trimmed),
              let scheme = link.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            status = "Enter a valid http(s) URL"
            return
        }
        guard let ytdlp = ytdlpPath, let ffmpeg = ffmpegPath else {
            status = missingToolsMessage ?? "Tools not found"
            return
        }

        progress = 0
        log = ""
        finishedFile = nil
        cancelled = false
        isRunning = true
        status = "Starting…"

        var args: [String] = [
            "--newline",
            "--no-quiet",          // --print implies --quiet, which would hide progress
            "--progress",
            "--no-playlist",
            "--ffmpeg-location", (ffmpeg as NSString).deletingLastPathComponent,
            "-P", destination.path,
            "-o", "%(title).150B [%(id)s].%(ext)s",
            "--print", "after_move:GRAB_FILE:%(filepath)s",
        ]

        switch mode {
        case .video:
            let h = quality.height.map { "[height<=\($0)]" } ?? ""
            args += [
                "-f", "bv*\(h)+ba/b\(h)",
                "--merge-output-format", "mp4",
            ]
        case .audio:
            args += [
                "-x",
                "--audio-format", "mp3",
                "--audio-quality", "0",
            ]
        }
        args.append(trimmed)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: ytdlp)
        p.arguments = args

        // GUI apps get a minimal PATH; make sure ffmpeg/ffprobe/python are findable.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (Tools.searchDirs + [env["PATH"] ?? ""]).joined(separator: ":")
        p.environment = env

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe

        let buffer = LineBuffer()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            // yt-dlp --newline emits one line per progress update.
            for line in buffer.append(chunk) {
                Task { @MainActor in self?.handle(line: line) }
            }
        }

        p.terminationHandler = { [weak self] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in
                guard let self else { return }
                self.isRunning = false
                self.process = nil
                if self.cancelled {
                    self.status = "Cancelled"
                } else if proc.terminationStatus == 0 {
                    self.progress = 1
                    self.status = "Done"
                } else {
                    self.status = "Failed (exit \(proc.terminationStatus)) – see log"
                }
            }
        }

        do {
            try p.run()
            process = p
        } catch {
            isRunning = false
            status = "Could not launch yt-dlp: \(error.localizedDescription)"
        }
    }

    private func handle(line: String) {
        if line.hasPrefix("GRAB_FILE:") {
            let path = String(line.dropFirst("GRAB_FILE:".count))
            finishedFile = URL(fileURLWithPath: path)
            return
        }

        log += line + "\n"

        if line.hasPrefix("[download]"),
           let pct = Self.percent(in: line) {
            progress = pct / 100
            status = "Downloading… \(String(format: "%.1f", pct))%"
        } else if line.hasPrefix("[Merger]") || line.hasPrefix("[ExtractAudio]")
                    || line.hasPrefix("[VideoConvertor]") || line.hasPrefix("[FFmpeg") {
            status = "Processing with FFmpeg…"
        } else if line.hasPrefix("[info]") || line.hasPrefix("[youtube]") || line.hasPrefix("[generic]") {
            status = "Fetching info…"
        }
    }

    private static func percent(in line: String) -> Double? {
        guard let r = line.range(of: #"(\d+(?:\.\d+)?)%"#, options: .regularExpression) else { return nil }
        return Double(line[r].dropLast())
    }
}

// MARK: - UI

struct ContentView: View {
    @StateObject private var dl = Downloader()
    @State private var showLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let warning = dl.missingToolsMessage {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }

            HStack {
                TextField("Paste a URL…", text: $dl.url)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if !dl.isRunning { dl.start() } }
                Button("Paste") { dl.pasteFromClipboard() }
            }

            HStack(spacing: 12) {
                Picker("", selection: $dl.mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)

                if dl.mode == .video {
                    Picker("Quality", selection: $dl.quality) {
                        ForEach(Quality.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .frame(width: 140)
                }
                Spacer()
            }
            .disabled(dl.isRunning)

            HStack {
                Image(systemName: "folder")
                Text(dl.destination.path(percentEncoded: false))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Change…") { dl.chooseFolder() }
                    .disabled(dl.isRunning)
            }

            ProgressView(value: dl.progress)
            Text(dl.status)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            HStack {
                if dl.isRunning {
                    Button("Cancel", role: .cancel) { dl.cancel() }
                } else {
                    Button("Download") { dl.start() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(dl.url.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Button("Show in Finder") { dl.revealInFinder() }
                Spacer()
                Toggle("Log", isOn: $showLog).toggleStyle(.button)
            }

            if showLog {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(dl.log.isEmpty ? "No output yet." : dl.log)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .id("bottom")
                    }
                    .frame(height: 160)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .onChange(of: dl.log) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
        }
        .padding(18)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}

@main
struct GrabApp: App {
    var body: some Scene {
        WindowGroup("Grab") {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}
