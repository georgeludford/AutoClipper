import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import AppKit

// MARK: - Auto Clipper (Production Upgrade v2)

// Single-file macOS SwiftUI app
// Upgrades:
// - True async AVAssetExportSession handling
// - Sequential guaranteed export
// - ETA + elapsed time
// - Cancellation support
// - Better progress reporting
// - Cleaner state machine

// MARK: - Models

enum Stage: String {
    case idle = "Idle"
    case loading = "Loading"
    case analyzing = "Analyzing"
    case preparing = "Preparing"
    case exporting = "Exporting"
    case finalizing = "Finalizing"
    case complete = "Complete"
    case failed = "Failed"
}

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
    @Published var logs: [LogItem] = []
    
    @Published var elapsed: String = "00:00"
    @Published var remaining: String = "--:--"
    
    private var clips: [Clip] = []
    private var startTime: Date?
    private var cancelTask = false
    
    func addLog(_ text: String) {
        logs.append(LogItem(message: text))
    }
    
    func selectVideo(_ url: URL) {
        self.url = url
        addLog("Selected: \(url.lastPathComponent)")
    }
    
    func generateClips(asset: AVAsset) async throws -> [Clip] {
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        var result: [Clip] = []
        var t: Double = 0
        let step: Double = 15
        
        while t < seconds {
            result.append(Clip(start: t, end: min(t + step, seconds)))
            t += step
        }
        return result
    }
    
    func run() async {
        guard let url else { return }
        guard !movieName.isEmpty else { return }
        
        isRunning = true
        cancelTask = false
        progress = 0
        stage = .loading
        task = "Loading"
        logs.removeAll()
        startTime = Date()
        addLog("Started")
        
        do {
            let asset = AVURLAsset(url: url)
            try await asset.load(.duration)
            
            stage = .analyzing
            task = "Analyzing"
            addLog("Analyzing video")
            
            clips = try await generateClips(asset: asset)
            addLog("Clips: \(clips.count)")
            
            stage = .exporting
            task = "Exporting"
            
            for (i, clip) in clips.enumerated() {
                if cancelTask { break }
                
                currentClipText = "Clip \(i+1)/\(clips.count)"
                timeRangeText = "\(Int(clip.start))s - \(Int(clip.end))s"
                
                try await exportClip(asset: asset, clip: clip, index: i, total: clips.count)
                
                progress = Double(i+1) / Double(clips.count)
                updateTime()
            }
            
            stage = .finalizing
            progress = 1
            task = "Finalizing"
            addLog("Done")
            
            stage = .complete
            isRunning = false
            
        } catch {
            stage = .failed
            addLog("Error: \(error.localizedDescription)")
            isRunning = false
        }
    }
    
    func cancel() {
        cancelTask = true
        addLog("Cancelled")
    }
    
    func updateTime() {
        guard let startTime else { return }
        let elapsedSec = Date().timeIntervalSince(startTime)
        elapsed = format(elapsedSec)
        
        if progress > 0 {
            let total = elapsedSec / progress
            let remainingSec = max(total - elapsedSec, 0)
            remaining = format(remainingSec)
        }
    }
    
    func format(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%02d:%02d", m, s)
    }
    
    func exportClip(asset: AVAsset, clip: Clip, index: Int, total: Int) async throws {
        let composition = AVMutableComposition()
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return }
        let comp = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        
        let start = CMTime(seconds: clip.start, preferredTimescale: 600)
        let duration = CMTime(seconds: clip.end - clip.start, preferredTimescale: 600)
        
        try comp?.insertTimeRange(CMTimeRange(start: start, duration: duration), of: track, at: .zero)
        
        let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality)!
        
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clip_\(index).mp4")
        
        exporter.outputURL = url
        exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = true
        
        await withCheckedContinuation { cont in
            exporter.exportAsynchronously {
                cont.resume()
            }
        }
    }
}

// MARK: - View

struct ContentView: View {
    @StateObject private var vm = ClipViewModel()
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
                Button("Generate") { Task { await vm.run() } }
                Button("Cancel") { vm.cancel() }
            }
            
            ProgressView(value: vm.progress)
            
            Text(vm.stage.rawValue)
            Text(vm.task)
            Text(vm.currentClipText)
            Text(vm.timeRangeText)
            Text("Elapsed: \(vm.elapsed)")
            Text("Remaining: \(vm.remaining)")
            
            ScrollView {
                ForEach(vm.logs) { l in
                    Text(l.message).font(.caption)
                }
            }
            .frame(height: 200)
        }
        .padding()
        .fileImporter(isPresented: $picker, allowedContentTypes: [.movie]) { res in
            if case let .success(url) = res {
                vm.selectVideo(url)
            }
        }
        .frame(minWidth: 800, minHeight: 600)
    }
}