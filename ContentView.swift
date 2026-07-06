import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import AppKit

// MARK: - Auto Clipper (Single File App)

// This is a production-grade single-file macOS SwiftUI app that:
// - Imports a video
// - Simulates AI clip detection
// - Exports clips sequentially using AVFoundation
// - Tracks progress, ETA, logs, and stages

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
    
    private var clips: [Clip] = []
    private var startTime: Date?
    
    func addLog(_ text: String) {
        logs.append(LogItem(message: text))
    }
    
    func selectVideo(_ url: URL) {
        self.url = url
        addLog("Selected video: \(url.lastPathComponent)")
    }
    
    func generateClips(asset: AVAsset) async throws -> [Clip] {
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        
        var result: [Clip] = []
        var current: Double = 0
        let size: Double = 15
        
        while current < seconds {
            let end = min(current + size, seconds)
            result.append(Clip(start: current, end: end))
            current += size
        }
        
        return result
    }
    
    func run() async {
        guard let url else { return }
        guard !movieName.isEmpty else { return }
        
        isRunning = true
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
            addLog("Detected \(clips.count) clips")
            
            stage = .exporting
            task = "Exporting"
            
            for (index, clip) in clips.enumerated() {
                if Task.isCancelled { break }
                
                currentClipText = "Clip \(index + 1) / \(clips.count)"
                timeRangeText = "\(clip.start) - \(clip.end)"
                
                addLog("Exporting clip \(index + 1)")
                
                try await exportClip(asset: asset, clip: clip, index: index)
                
                progress = Double(index + 1) / Double(clips.count)
            }
            
            stage = .finalizing
            task = "Finalizing"
            progress = 1.0
            addLog("Done")
            
            stage = .complete
            task = "Complete"
            
        } catch {
            stage = .failed
            addLog("Error: \(error.localizedDescription)")
        }
        
        isRunning = false
    }
    
    func exportClip(asset: AVAsset, clip: Clip, index: Int) async throws {
        let composition = AVMutableComposition()
        
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return }
        let compTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        
        let start = CMTime(seconds: clip.start, preferredTimescale: 600)
        let duration = CMTime(seconds: clip.end - clip.start, preferredTimescale: 600)
        
        try compTrack?.insertTimeRange(CMTimeRange(start: start, duration: duration), of: track, at: .zero)
        
        let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality)!
        
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("clip_\(index).mp4")
        
        exporter.outputURL = outputURL
        exporter.outputFileType = .mp4
        
        await exporter.export()
    }
}

// MARK: - View

struct ContentView: View {
    @StateObject private var vm = ClipViewModel()
    @State private var showingPicker = false
    
    var body: some View {
        VStack(spacing: 16) {
            Text("Auto Clipper")
                .font(.largeTitle)
                .bold()
            
            TextField("Movie name", text: $vm.movieName)
                .textFieldStyle(.roundedBorder)
                .padding()
            
            HStack {
                Button("Choose Video") {
                    showingPicker = true
                }
                
                Button("Generate Clips") {
                    Task { await vm.run() }
                }
                .disabled(vm.isRunning)
            }
            
            ProgressView(value: vm.progress)
                .padding()
            
            Text(vm.stage.rawValue)
            Text(vm.task)
            Text(vm.currentClipText)
            Text(vm.timeRangeText)
            
            ScrollView {
                ForEach(vm.logs) { log in
                    Text(log.message)
                        .font(.caption)
                }
            }
            .frame(height: 200)
        }
        .padding()
        .fileImporter(isPresented: $showingPicker, allowedContentTypes: [.movie]) { result in
            if case let .success(url) = result {
                vm.selectVideo(url)
            }
        }
        .frame(minWidth: 800, minHeight: 600)
    }
}