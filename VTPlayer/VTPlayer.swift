import SwiftUI
import AVFoundation
import VideoToolbox
import CoreMedia
import CoreVideo
import QuartzCore
import Combine
import UniformTypeIdentifiers

enum Mode: String, CaseIterable, Identifiable {
    case original = "Original", fg = "FG ×2", sr = "SR", both = "FG + SR"
    var id: String { rawValue }
    var fg: Bool { self == .fg || self == .both }
    var sr: Bool { self == .sr || self == .both }
}
struct LabError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
// Allocate from the exact configuration attributes, including IOSurface compatibility.
func makeBuffer(_ attrs: [String: any Sendable]) throws -> CVPixelBuffer {
    var pool: CVPixelBufferPool?
    let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool)
    guard status == kCVReturnSuccess, let pool else { throw LabError("Pool creation: \(status)") }
    var b: CVPixelBuffer?
    let result = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &b)
    guard result == kCVReturnSuccess, let b else { throw LabError("Pool allocation: \(result)") }
    return b
}
final class Effect {
    let processor = VTFrameProcessor()
    let attrs: [String: any Sendable]
    let inputAttrs: [String: any Sendable]
    init(_ configuration: any VTFrameProcessorConfiguration, input: [String: any Sendable], output: [String: any Sendable]) throws {
        attrs = output; inputAttrs = input
        try processor.startSession(configuration: configuration)
    }
    deinit { processor.endSession() }
    func run(_ params: any VTFrameProcessorParameters) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            processor.process(parameters: params, completionHandler: { _, error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            })
        }
    }
    func frame(_ b: CVPixelBuffer, _ t: CMTime) throws -> VTFrameProcessorFrame {
        guard let f = VTFrameProcessorFrame(buffer: b, presentationTimeStamp: t) else { throw LabError("Invalid processor frame") }
        return f
    }
    func interpolate(_ a: CVPixelBuffer, _ at: CMTime, _ b: CVPixelBuffer, _ bt: CMTime) async throws -> (CVPixelBuffer, CMTime) {
        let t = CMTimeAdd(at, CMTimeMultiplyByFloat64(CMTimeSubtract(bt, at), multiplier: 0.5))
        let out = try makeBuffer(attrs)
        guard let p = VTLowLatencyFrameInterpolationParameters(sourceFrame: try frame(b, bt), previousFrame: try frame(a, at), interpolationPhase: [0.5], destinationFrames: [try frame(out, t)]) else { throw LabError("FG parameters rejected") }
        try await run(p)
        return (out, t)
    }
    func upscale(_ b: CVPixelBuffer, _ t: CMTime) async throws -> CVPixelBuffer {
        let out = try makeBuffer(attrs)
        let p = VTLowLatencySuperResolutionScalerParameters(sourceFrame: try frame(b,t), destinationFrame: try frame(out,t))
        try await run(p)
        return out
    }
}

final class Surface: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var videoLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
}
struct VideoSurface: UIViewRepresentable {
    let surface: Surface
    func makeUIView(context: Context) -> Surface { surface }
    func updateUIView(_ uiView: Surface, context: Context) {}
}

@MainActor final class Lab: ObservableObject {
    @Published var mode = Mode.original
    @Published var status = "Select a sample or local file."
    @Published var stats = ""
    @Published var running = false
    @Published var file: URL?
    let surface = Surface()
    private var job: Task<Void,Never>?
    var capabilities: String {
        let fg = VTLowLatencyFrameInterpolationConfiguration.isSupported
        let sr = VTLowLatencySuperResolutionScalerConfiguration.isSupported
        let sizes = [(640,360),(854,480),(1280,720)].map { w,h in
            let factors = sr ? VTLowLatencySuperResolutionScalerConfiguration.supportedScaleFactors(frameWidth:w,frameHeight:h) : []
            return "\(h)p SR: \(factors.isEmpty ? "none" : factors.map { String($0) }.joined(separator: ", "))"
        }
        return (["FG: \(fg ? "supported" : "unsupported") · SR: \(sr ? "supported" : "unsupported")"] + sizes).joined(separator:"\n")
    }
    func choose(_ height: Int) {
        file = Bundle.main.url(forResource:"test-\(height)p",withExtension:"mp4")
        status = file == nil ? "Sample missing" : "Selected \(height)p / 24fps"
    }
    func stop() { job?.cancel(); status = "Stopping…" }
    func start() {
        guard let file, !running else { return }
        let selected = mode
        running = true; stats = ""; status = "Starting \(selected.rawValue)…"
        surface.videoLayer.flushAndRemoveImage()
        surface.videoLayer.videoGravity = .resizeAspect
        job = Task {
            do { try await play(file, selected); status = "Finished" }
            catch is CancellationError { status = "Stopped" }
            catch { status = "Error: \(error.localizedDescription)" }
            running = false; job = nil
        }
    }
    private func play(_ url: URL, _ mode: Mode) async throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType:.video).first else { throw LabError("No video track") }
        let size = try await track.load(.naturalSize)
        let w = Int(abs(size.width)), h = Int(abs(size.height))
        let fps = try await track.load(.nominalFrameRate)
        guard w > 0, h > 0, w <= 1280, h <= 720 else { throw LabError("Lab input limited to landscape 1280×720") }
        var fg: Effect?, sr: Effect?
        var scale: Float = 1
        if mode.fg {
            guard VTLowLatencyFrameInterpolationConfiguration.isSupported,
                  let c = VTLowLatencyFrameInterpolationConfiguration(frameWidth:w,frameHeight:h,numberOfInterpolatedFrames:1) else { throw LabError("FG unsupported at \(w)×\(h)") }
            fg = try Effect(c,input:c.sourcePixelBufferAttributes,output:c.destinationPixelBufferAttributes)
        }
        if mode.sr {
            guard VTLowLatencySuperResolutionScalerConfiguration.isSupported else { throw LabError("SR unsupported on device") }
            let factors = VTLowLatencySuperResolutionScalerConfiguration.supportedScaleFactors(frameWidth:w,frameHeight:h)
            guard let factor = factors.filter({ $0 > 1 && Float(w)*$0 <= 1920 && Float(h)*$0 <= 1080 }).max() else { throw LabError("No supported SR scale within 1080p") }
            scale = factor
            let c = VTLowLatencySuperResolutionScalerConfiguration(frameWidth:w,frameHeight:h,scaleFactor:factor)
            sr = try Effect(c,input:c.sourcePixelBufferAttributes,output:c.destinationPixelBufferAttributes)
        }
        let reader = try AVAssetReader(asset:asset)
        let attrs = fg?.inputAttrs ?? sr?.inputAttrs
        let requested = attrs?[kCVPixelBufferPixelFormatTypeKey as String]
        let format: OSType
        if let n = requested as? NSNumber { format = n.uint32Value }
        else if let a = requested as? [NSNumber], let n = a.first { format = n.uint32Value }
        else { format = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange }
        let output = AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:format,kCVPixelBufferIOSurfacePropertiesKey as String:[:] as [String:Any]])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw LabError("Reader output rejected") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? LabError("Reader start failed") }
        defer { reader.cancelReading() }
        status = "\(w)×\(h) @ \(fps) → \(Int(Float(w)*scale))×\(Int(Float(h)*scale)) · \(mode.rawValue)"
        var prev: (CVPixelBuffer,CMTime)?
        var origin: CMTime?
        var start = CACurrentMediaTime()
        var total = 0, shown = 0, late = 0, generated = 0
        var work: Double = 0
        var lastStats = start
        func emit(_ b: CVPixelBuffer,_ t: CMTime) async throws {
            try Task.checkCancellation()
            let begin = CACurrentMediaTime()
            let result: CVPixelBuffer
            if let sr { result = try await sr.upscale(b,t) } else { result = b }
            work += CACurrentMediaTime()-begin
            if origin == nil { origin = t; start = CACurrentMediaTime() }
            let due = start + CMTimeSubtract(t,origin!).seconds
            let delay = due - CACurrentMediaTime()
            if delay > 0 && delay.isFinite { try await Task.sleep(for:.seconds(delay)) }
            if CACurrentMediaTime()-due > 0.10 { late += 1 }
            if surface.videoLayer.isReadyForMoreMediaData {
                var desc: CMVideoFormatDescription?
                guard CMVideoFormatDescriptionCreateForImageBuffer(allocator:kCFAllocatorDefault,imageBuffer:result,formatDescriptionOut:&desc)==noErr, let desc else { throw LabError("Format description failed") }
                var timing = CMSampleTimingInfo(duration:.invalid,presentationTimeStamp:t,decodeTimeStamp:.invalid)
                var sample: CMSampleBuffer?
                guard CMSampleBufferCreateReadyWithImageBuffer(allocator:kCFAllocatorDefault,imageBuffer:result,formatDescription:desc,sampleTiming:&timing,sampleBufferOut:&sample)==noErr, let sample else { throw LabError("Sample creation failed") }
                if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample,createIfNecessary:true), CFArrayGetCount(attachments)>0 {
                    let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments,0),to:CFMutableDictionary.self)
                    CFDictionarySetValue(dict,Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
                }
                surface.videoLayer.enqueue(sample); shown += 1
            }
            total += 1
            let now = CACurrentMediaTime()
            if now-lastStats >= 0.5 {
                stats = String(format:"Submitted %.1f fps · FG %d · late %d · dropped %d\nProcessing %.1f ms/frame · Thermal %d",Double(shown)/max(0.01,now-start),generated,late,total-shown,1000*work/Double(max(1,total)),ProcessInfo.processInfo.thermalState.rawValue)
                lastStats = now
            }
        }
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let b = CMSampleBufferGetImageBuffer(sample) else { continue }
            let t = CMSampleBufferGetPresentationTimeStamp(sample)
            if let fg, let (a,at) = prev {
                let begin = CACurrentMediaTime()
                let (mid,mt) = try await fg.interpolate(a,at,b,t)
                work += CACurrentMediaTime()-begin
                generated += 1
                try await emit(mid,mt)
            }
            try await emit(b,t)
            prev = (b,t)
        }
        if reader.status == .failed { throw reader.error ?? LabError("Decode failed") }
        stats += "\nTotal submitted: \(shown) / \(total) · interpolated: \(generated)"
    }
}

@main struct VTPlayerApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}
struct ContentView: View {
    @StateObject private var lab = Lab()
    @State private var importer = false
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:14) {
                Text("VTPlayer Lab").font(.largeTitle.bold())
                VideoSurface(surface:lab.surface).aspectRatio(16/9,contentMode:.fit).background(.black)
                Picker("Mode",selection:$lab.mode) { ForEach(Mode.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).disabled(lab.running)
                HStack { ForEach([360,480,720],id:\.self) { h in Button("\(h)p") { lab.choose(h) }.buttonStyle(.bordered) }; Button("File") { importer=true }.buttonStyle(.bordered) }.disabled(lab.running)
                HStack { Button("Play") { lab.start() }.buttonStyle(.borderedProminent).disabled(lab.running || lab.file == nil); Button("Stop") { lab.stop() }.buttonStyle(.bordered).disabled(!lab.running) }
                Text(lab.file?.lastPathComponent ?? "No file").font(.caption)
                Text(lab.status).font(.headline).textSelection(.enabled)
                Text(lab.stats).font(.system(.caption,design:.monospaced)).textSelection(.enabled)
                Divider()
                Text("Device capabilities").font(.headline)
                Text(lab.capabilities).font(.system(.caption,design:.monospaced)).textSelection(.enabled)
                Text("Experimental silent SDR playback · input ≤720p · SR output ≤1080p · submitted FPS is not display FPS.").font(.caption).foregroundStyle(.secondary)
            }.padding()
        }.fileImporter(isPresented:$importer,allowedContentTypes:[.movie],allowsMultipleSelection:false) { result in
            switch result {
            case .success(let urls): lab.file=urls.first; lab.status="File selected"
            case .failure(let e): lab.status=e.localizedDescription
            }
        }.onDisappear { if lab.running { lab.stop() } }
    }
}
