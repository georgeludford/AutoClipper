import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import AppKit

// MARK: - Auto Clipper (Production Final v5)
// Updates:
// - Clips now ~90 seconds each
// - Export now goes to Movies/AutoClipper folder (not temp)
// - Auto directory creation
// - Sequential export unchanged
// - KVO progress tracking preserved

// MARK: - Stage

enum Stage: String {
    case idle = "Idle"
    case loading = "Loading"
    case analyzing = "Analyzing"
    case exporting = "Exporting"
    case finalizing = "Finalizing"
    case complete = "Complete"
    case failed = "Failed"
}

// MARK: - Models

struct Clip: Identifiable {
    let id = UUID()
    let start: Double
    let end: Double
}

struct LogItem: Identifiable {
    let id = UUID()
    let message: String
    let date = Date()
}

// MARK: - ViewModel

@MainActor
final class ClipViewModel: ObservableObject {

    @Published var url: URL?
    @Published var movieName: String = ""

    @Published var isRunning = false
    @Published var progress: Double = 0

    @Published var stage: Stage = .idle
    @Published var task: String = "Idle"

    @Published var currentClipText: String = "-"
    @Published var timeRangeText: String = "-"

    @Published var elapsed: String = "00:00"
    @Published var remaining: String = "--:--"

    @Published var logs: [LogItem] = []

    private var clips: [Clip] = []
    private var startTime: Date?

    private var cancelRequested = false
    private var observation: NSKeyValueObservation?

    // MARK: Logging

    func log(_ text: String) {
        logs.append(LogItem(message: text))
    }

    // MARK: Select

    func select(_ url: URL) {
        self.url = url
        log("Selected: \(url.lastPathComponent)")
    }

    // MARK: Clip Detection (~90s segments)

    func detectClips(asset: AVAsset) async throws -> [Clip] {
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)

        var result: [Clip] = []
        var t: Double = 0

        let base = 90.0
        let variance = 15.0

        while t < seconds {
            let segment = base + Double.random(in: -variance...variance)
            let safeSegment = max(60, min(segment, 120))
            let end = min(t + safeSegment, seconds)
            result.append(Clip(start: t, end: end))
            t = end
        }

        return result
    }

    // MARK: Export Folder

    func exportFolder() throws -> URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
        let folder = movies.appendingPathComponent("AutoClipper")

        if !FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        return folder
    }

    // MARK: Run

    func run() async {
        guard let url else { return }
        guard !movieName.isEmpty else { return }

        reset()

        isRunning = true
        cancelRequested = false
        startTime = Date()

        stage = .loading
        task = "Loading"

        do {
            let asset = AVURLAsset(url: url)
            try await asset.load(.duration)

            stage = .analyzing
            task = "Detecting clips"

            clips = try await detectClips(asset: asset)
            log("Clips detected: \(clips.count)")

            let outputFolder = try exportFolder()

            stage = .exporting

            for (i, clip) in clips.enumerated() {
                if cancelRequested { break }

                currentClipText = "\(i+1)/\(clips.count)"
                timeRangeText = "\(Int(clip.start))s - \(Int(clip.end))s"

                try await export(asset: asset, clip: clip, index: i, folder: outputFolder)

                progress = Double(i+1) / Double(clips.count)
                updateTime()
            }

            stage = .finalizing
            progress = 1

            stage = .complete
            task = "Done"

        } catch {
            stage = .failed
            log("Error: \(error.localizedDescription)")
        }

        isRunning = false
    }

    // MARK: Export

    func export(asset: AVAsset, clip: Clip, index: Int, folder: URL) async throws {

        let composition = AVMutableComposition()

        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return }

        let compTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)

        let start = CMTime(seconds: clip.start, preferredTimescale: 600)
        let duration = CMTime(seconds: clip.end - clip.start, preferredTimescale: 600)

        try compTrack?.insertTimeRange(
            CMTimeRange(start: start, duration: duration),
            of: track,
            at: .zero
        )

        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            return
        }

        let out = folder.appendingPathComponent("clip_\(index+1).mp4")

        exporter.outputURL = out
        exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = true

        log("Exporting clip \(index+1)")

        observation = exporter.observe(\AVAssetExportSession.progress, options: [.new]) { [weak self] exporter, _ in
            Task { @MainActor in
                guard let self else { return }

                let base = Double(index) / Double(max(self.clips.count, 1))
                let incremental = Double(exporter.progress) / Double(max(self.clips.count, 1))
                self.progress = base + incremental
                self.updateTime()
            }
        }

        await withCheckedContinuation { cont in
            exporter.exportAsynchronously {
                self.observation?.invalidate()
                self.observation = nil
                cont.resume()
            }
        }
    }

    // MARK: Cancel

    func cancel() {
        cancelRequested = true
        log("Cancel requested")
    }

    // MARK: Time

    func updateTime() {
        guard let startTime else { return }

        let elapsedSec = Date().timeIntervalSince(startTime)
        elapsed = format(elapsedSec)

        if progress > 0 {
            let total = elapsedSec / progress
            let remain = max(total - elapsedSec, 0)
            remaining = format(remain)
        }
    }

    func format(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%02d:%02d", m, s)
    }

    func reset() {
        progress = 0
        logs.removeAll()
        clips.removeAll()
        elapsed = "00:00"
        remaining = "--:--"
    }
}

// MARK: - UI

struct ContentView: View {

    @StateObject var vm = ClipViewModel()
    @State private var picker = false

    var body: some View {
        VStack(spacing: 12) {

            Text("Auto Clipper")
                .font(.largeTitle)
                .bold()

            TextField("Movie name", text: $vm.movieName)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)

            HStack {
                Button("Select Video") { picker = true }
                Button("Run") { Task { await vm.run() } }
                Button("Cancel") { vm.cancel() }
            }

            ProgressView(value: vm.progress)

            Text(vm.stage.rawValue)
            Text(vm.task)
            Text("Clip: \(vm.currentClipText)")
            Text(vm.timeRangeText)

            Text("Elapsed: \(vm.elapsed)")
            Text("Remaining: \(vm.remaining)")

            ScrollView {
                ForEach(vm.logs) { l in
                    Text(l.message)
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(height: 220)

        }
        .padding()
        .fileImporter(isPresented: $picker, allowedContentTypes: [.movie]) { res in
            if case let .success(url) = res {
                vm.select(url)
            }
        }
        .frame(minWidth: 950, minHeight: 700)
    }
}
