// Keychain Cam — live view, photos, video and time-lapse from the HX330X keychain
// camera (USB 349c:3301). Build with ./build.sh.
// Everything is saved to ~/Desktop/Keychain Camera/Webcam/.

import AppKit
import AVFoundation
import CoreImage

let cameraTag = "VendorID_13468"   // 0x349c
let photosDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Desktop/Keychain Camera/Webcam")
let logURL: URL = {
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Keychain Cam")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("app.log")
}()

func log(_ s: String) {
    let line = "\(Date()) \(s)\n"
    if let h = try? FileHandle(forWritingTo: logURL) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
    } else {
        try? line.write(to: logURL, atomically: true, encoding: .utf8)
    }
}

/// Next free file name in the output folder, e.g. 2026-11-12_130455.jpg
func nextURL(ext: String, suffix: String = "") -> URL {
    try? FileManager.default.createDirectory(at: photosDir, withIntermediateDirectories: true)
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HHmmss"
    let base = f.string(from: Date()) + suffix
    var url = photosDir.appendingPathComponent("\(base).\(ext)")
    var n = 2
    while FileManager.default.fileExists(atPath: url.path) {
        url = photosDir.appendingPathComponent("\(base)-\(n).\(ext)"); n += 1
    }
    return url
}

enum MicChoice: String, CaseIterable {
    case camera = "Camera mic", mac = "Mac mic", none = "No sound"
}

// MARK: - Camera

final class Camera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
                    AVCaptureAudioDataOutputSampleBufferDelegate, AVCaptureFileOutputRecordingDelegate {
    let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let movie = AVCaptureMovieFileOutput()
    private let frames = DispatchQueue(label: "frames")
    private let audioQueue = DispatchQueue(label: "audio")
    private let sessionQueue = DispatchQueue(label: "session")
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var current: AVCaptureDevice?
    var micAllowed = false
    var micChoice: MicChoice = MicChoice(rawValue: UserDefaults.standard.string(forKey: "mic") ?? "") ?? .camera {
        didSet { UserDefaults.standard.set(micChoice.rawValue, forKey: "mic") }
    }
    private(set) var micName: String?
    /// nil = live; otherwise a message to show instead of the picture
    var onStatus: ((String?) -> Void)?
    var onRecordingFinished: ((URL, Error?) -> Void)?
    /// Live sound level 0…1, called on the main thread about 15 times a second
    var onLevel: ((Double) -> Void)?
    /// Called once (main thread) when the mic has sent nothing but digital zeros for a few seconds.
    /// The keychain camera's mic does this: half a second of sound, then pure silence.
    var onMicSilent: (() -> Void)?

    override init() {
        super.init()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: frames)
        audioOutput.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
        ]
        audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(devicesChanged), name: AVCaptureDevice.wasConnectedNotification, object: nil)
        nc.addObserver(self, selector: #selector(devicesChanged), name: AVCaptureDevice.wasDisconnectedNotification, object: nil)
    }

    @objc private func devicesChanged(_ n: Notification) {
        log("device change: \(n.name.rawValue)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.connect() }
    }

    private func findCamera() -> AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified)
            .devices.first { $0.modelID.contains(cameraTag) }
    }

    private func isKeychainCamera(_ d: AVCaptureDevice) -> Bool {
        let id = d.modelID.lowercased(); return id.contains("349c") || id.contains("13468")
    }

    private func pickMic(for video: AVCaptureDevice) -> AVCaptureDevice? {
        let mics = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
        log("mics: " + mics.map { "\($0.localizedName) [\($0.modelID)]" }.joined(separator: ", "))
        switch micChoice {
        case .none: return nil
        case .camera:
            let name = video.localizedName.trimmingCharacters(in: .whitespaces)
            return mics.first(where: isKeychainCamera)
                ?? mics.first { $0.localizedName.trimmingCharacters(in: .whitespaces) == name }
        case .mac:
            // The Mac's own mic: not the keychain camera, not an iPhone via Continuity
            return mics.first { !isKeychainCamera($0) && !$0.modelID.contains("iPhone") && $0.deviceType == .microphone }
                ?? mics.first { !isKeychainCamera($0) }
        }
    }

    func connect(force: Bool = false) {
        let dev = findCamera()
        if !force, let dev, dev.uniqueID == current?.uniqueID, session.isRunning { return }
        current = dev
        lock.lock(); latest = nil; lock.unlock()

        guard let dev else {
            log("camera not found")
            sessionQueue.async { if self.session.isRunning { self.session.stopRunning() } }
            onStatus?("Plug in the keychain camera\nand choose  PC CAMERA  on it")
            return
        }
        log("connecting to \(dev.localizedName) \(dev.modelID)")
        onStatus?("Connecting…")
        let mic = micAllowed ? pickMic(for: dev) : nil
        sessionQueue.async {
            let s = self.session
            s.beginConfiguration()
            s.inputs.forEach { s.removeInput($0) }
            for o in [self.output, self.audioOutput, self.movie] as [AVCaptureOutput]
            where !s.outputs.contains(where: { $0 === o }) && s.canAddOutput(o) { s.addOutput(o) }
            do {
                let input = try AVCaptureDeviceInput(device: dev)
                if s.canAddInput(input) { s.addInput(input) }
                // Use the largest format the camera offers (1920x1080)
                let area: (AVCaptureDevice.Format) -> Int32 = {
                    let d = CMVideoFormatDescriptionGetDimensions($0.formatDescription); return d.width * d.height
                }
                if let best = dev.formats.max(by: { area($0) < area($1) }) {
                    try dev.lockForConfiguration(); dev.activeFormat = best; dev.unlockForConfiguration()
                }
            } catch {
                log("input error: \(error)")
            }
            self.micName = nil
            if let mic, let ai = try? AVCaptureDeviceInput(device: mic), s.canAddInput(ai) {
                s.addInput(ai); self.micName = mic.localizedName.trimmingCharacters(in: .whitespaces)
                log("using mic: \(self.micName!)")
            } else {
                log("no mic in use (choice: \(self.micChoice.rawValue), allowed: \(self.micAllowed))")
                DispatchQueue.main.async { self.onLevel?(0) }
            }
            s.commitConfiguration()
            if let c = self.movie.connection(with: .video) {
                self.movie.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.h264], for: c)
            }
            if !s.isRunning { s.startRunning() }
            self.forceFastestFrameRate(dev)
            log("session running: \(s.isRunning)")
        }
    }

    /// The camera offers each size at 30fps or 5fps; adding audio/movie outputs can make
    /// AVFoundation settle on 5fps. Pin it to the fastest rate the active format has.
    private func forceFastestFrameRate(_ dev: AVCaptureDevice) {
        guard let fastest = dev.activeFormat.videoSupportedFrameRateRanges.max(by: { $0.maxFrameRate < $1.maxFrameRate })
        else { return }
        do {
            try dev.lockForConfiguration()
            dev.activeVideoMinFrameDuration = fastest.minFrameDuration
            dev.activeVideoMaxFrameDuration = fastest.minFrameDuration
            dev.unlockForConfiguration()
            let d = CMVideoFormatDescriptionGetDimensions(dev.activeFormat.formatDescription)
            log("format \(d.width)x\(d.height), frame rate pinned to \(Int(fastest.maxFrameRate))fps")
        } catch {
            log("couldn't set frame rate: \(error)")
        }
        fpsCount = 0; fpsStart = Date(); fpsReports = 0
        audioReports = 0; audioWindowStart = Date(); audioWindowPeak = 0
        silentSince = nil; silentReported = false
    }

    // Diagnostics logged for the first few seconds after connecting
    private var fpsCount = 0, fpsStart = Date(), fpsReports = 0
    private var audioReports = 0, audioWindowStart = Date(), audioWindowPeak: Float = 0
    private var lastLevelSent = Date.distantPast
    private var silentSince: Date?, silentReported = false

    func captureOutput(_ o: AVCaptureOutput, didOutput sb: CMSampleBuffer, from c: AVCaptureConnection) {
        if o === audioOutput { handleAudio(sb); return }
        if fpsReports < 3 {
            fpsCount += 1
            let dt = Date().timeIntervalSince(fpsStart)
            if dt >= 2 {
                log(String(format: "measured %.1f fps", Double(fpsCount) / dt))
                fpsCount = 0; fpsStart = Date(); fpsReports += 1
            }
        }
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        lock.lock(); let first = latest == nil; latest = pb; lock.unlock()
        if first { DispatchQueue.main.async { self.onStatus?(nil) } }
    }

    private func handleAudio(_ sb: CMSampleBuffer) {
        var abl = AudioBufferList()
        var block: CMBlockBuffer?
        let st = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: nil, bufferListOut: &abl,
            bufferListSize: MemoryLayout<AudioBufferList>.size, blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &block)
        guard st == noErr, let data = abl.mBuffers.mData else { return }
        let n = Int(abl.mBuffers.mDataByteSize) / MemoryLayout<Float>.size
        let samples = data.bindMemory(to: Float.self, capacity: n)
        var peak: Float = 0
        for i in 0..<n { peak = max(peak, abs(samples[i])) }

        if audioReports < 3 {
            audioWindowPeak = max(audioWindowPeak, peak)
            if Date().timeIntervalSince(audioWindowStart) >= 2 {
                log(String(format: "mic peak %.3f%% (%@)", audioWindowPeak * 100, micName ?? "-"))
                audioWindowPeak = 0; audioWindowStart = Date(); audioReports += 1
            }
        }
        // A real mic always picks up a little hiss; exact zeros mean the mic has stopped sending sound.
        if peak == 0 {
            if silentSince == nil { silentSince = Date() }
            if !silentReported, let t = silentSince, Date().timeIntervalSince(t) >= 3 {
                silentReported = true
                log("mic \(micName ?? "-") is sending pure silence")
                DispatchQueue.main.async { self.onMicSilent?() }
            }
        } else {
            if silentReported { log("mic \(micName ?? "-") has sound again") }
            silentSince = nil; silentReported = false
        }
        if Date().timeIntervalSince(lastLevelSent) > 1.0 / 15 {
            lastLevelSent = Date()
            let db = 20 * log10(max(Double(peak), 1e-5))           // −100…0 dB
            let level = min(1, max(0, (db + 60) / 60))              // show −60…0 dB
            DispatchQueue.main.async { self.onLevel?(level) }
        }
    }

    /// The newest frame from the camera.
    func latestFrame() -> CVPixelBuffer? { lock.lock(); defer { lock.unlock() }; return latest }

    /// Saves the newest frame as a JPEG and returns its URL.
    func snapshot() -> URL? {
        guard let pb = latestFrame() else { return nil }
        let image = CIImage(cvPixelBuffer: pb)
        guard let data = CIContext().jpegRepresentation(
            of: image, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.92])
        else { return nil }
        let url = nextURL(ext: "jpg")
        do { try data.write(to: url); log("saved \(url.lastPathComponent)"); return url }
        catch { log("save failed: \(error)"); return nil }
    }

    // MARK: Recording

    var isRecording: Bool { movie.isRecording }

    func startRecording() -> URL? {
        guard session.isRunning, movie.connection(with: .video) != nil, !movie.isRecording else { return nil }
        let url = nextURL(ext: "mov")
        movie.startRecording(to: url, recordingDelegate: self)
        log("recording to \(url.lastPathComponent) (mic: \(micName ?? "none"))")
        return url
    }

    func stopRecording() { movie.stopRecording() }

    func fileOutput(_ o: AVCaptureFileOutput, didFinishRecordingTo url: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        var err = error
        if let e = error as NSError?, (e.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool) == true { err = nil }
        log("recording finished \(url.lastPathComponent) error: \(err.map { "\($0)" } ?? "none")")
        DispatchQueue.main.async { self.onRecordingFinished?(url, err) }
    }
}

// MARK: - Time-lapse

/// Writes frames grabbed every few seconds into an H.264 MP4 that plays back at 30fps.
final class TimelapseWriter {
    let url: URL
    private(set) var frames: Int64 = 0
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    static let playbackFPS: Int32 = 30

    init(url: URL) { self.url = url }

    func append(_ pb: CVPixelBuffer) {
        if writer == nil { start(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb)) }
        guard let input, let adaptor, input.isReadyForMoreMediaData else { return }
        if adaptor.append(pb, withPresentationTime: CMTime(value: frames, timescale: Self.playbackFPS)) {
            frames += 1
        } else {
            log("time-lapse append failed: \(String(describing: writer?.error))")
        }
    }

    private func start(width: Int, height: Int) {
        do {
            let w = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let i = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width, AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 12_000_000],
            ])
            i.expectsMediaDataInRealTime = false
            let a = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: i, sourcePixelBufferAttributes: nil)
            w.add(i)
            w.startWriting()
            w.startSession(atSourceTime: .zero)
            writer = w; input = i; adaptor = a
            log("time-lapse started \(url.lastPathComponent) \(width)x\(height)")
        } catch {
            log("time-lapse writer error: \(error)")
        }
    }

    /// Finishes the file; calls back with the URL, or nil if nothing was captured.
    func finish(_ done: @escaping (URL?) -> Void) {
        guard let writer, let input, frames > 0 else {
            writer?.cancelWriting(); try? FileManager.default.removeItem(at: url)
            done(nil); return
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: frames, timescale: Self.playbackFPS))
        writer.finishWriting { [url] in
            log("time-lapse finished: \(writer.status == .completed ? "ok" : "\(String(describing: writer.error))")")
            DispatchQueue.main.async { done(writer.status == .completed ? url : nil) }
        }
    }
}

// MARK: - Sound boost

/// Makes quiet recordings (the keychain camera's mic is very weak) comfortably loud after
/// recording: a gentle high-pass to cut rumble, gain set from the speech level (the loudest
/// fifth of 50 ms windows) towards −18 dBFS, capped at +36 dB, then a soft limiter so peaks
/// never clip. Video is copied untouched. Recordings that are already loud are left alone.
enum AudioBoost {
    static let targetLevel: Float = 0.126      // −18 dBFS
    static let maxGain: Float = 63.1           // +36 dB
    static let minUsefulGain: Float = 1.41     // below +3 dB, don't bother

    struct Shaper {
        let gain: Float, alpha: Float, gateThreshold: Float
        let envCoef: Float, openCoef: Float, closeCoef: Float
        var prevIn: [Float], prevOut: [Float], envelope: Float = 0, gate: Float = 1
        init(gain: Float, gateThreshold: Float, sampleRate: Double, channels: Int) {
            let sr = Float(sampleRate)
            let rc = 1 / (2 * Float.pi * 90), dt = 1 / sr
            self.gain = gain; alpha = rc / (rc + dt)
            self.gateThreshold = gateThreshold
            envCoef = exp(-1 / (sr * 0.020))      // level = |signal| averaged over ~20 ms
            openCoef = exp(-1 / (sr * 0.003))     // gate opens in ~3 ms (keeps word starts)
            closeCoef = exp(-1 / (sr * 0.150))    // and closes over ~150 ms (no chatter)
            prevIn = .init(repeating: 0, count: channels); prevOut = prevIn
        }
        mutating func process(_ x: UnsafeMutablePointer<Float>, count: Int, channels: Int) {
            for i in 0..<count {
                let c = i % channels
                let y = alpha * (prevOut[c] + x[i] - prevIn[c])     // high-pass ~90 Hz (rumble, handling noise)
                prevIn[c] = x[i]; prevOut[c] = y
                // Noise gate: when the level sits near the hiss, turn it down (up to −18 dB)
                envelope = envCoef * envelope + (1 - envCoef) * abs(y)
                let r = envelope / gateThreshold
                let target: Float = r >= 1 ? 1 : max(0.125, r * r)
                gate = target > gate ? openCoef * gate + (1 - openCoef) * target
                                     : closeCoef * gate + (1 - closeCoef) * target
                var z = y * gain * gate
                let m = abs(z)
                if m > 0.45 { z = (z < 0 ? -1 : 1) * (0.45 + 0.35 * tanh((m - 0.45) / 0.35)) }   // soft limit, ceiling −2 dB (AAC overshoots a little)
                x[i] = z
            }
        }
    }

    static let pcmSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
    ]

    /// The sample buffer's float samples (copied, so non-contiguous buffers are fine).
    private static func floats(_ sb: CMSampleBuffer) -> [Float]? {
        guard let block = CMSampleBufferGetDataBuffer(sb) else { return nil }
        let count = CMBlockBufferGetDataLength(block) / 4
        var x = [Float](repeating: 0, count: count)
        guard x.withUnsafeMutableBytes({
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * 4, destination: $0.baseAddress!)
        }) == noErr else { return nil }
        return x
    }

    enum Outcome { case boosted(Float), loudEnough, silent }

    /// Boosts the movie's sound in place and says what it did.
    static func process(_ url: URL) throws -> Outcome {
        let asset = AVURLAsset(url: url)
        guard let audio = asset.tracks(withMediaType: .audio).first else { return .silent }
        let video = asset.tracks(withMediaType: .video).first

        // Pass 1: measure the speech level
        let r1 = try AVAssetReader(asset: asset)
        let o1 = AVAssetReaderTrackOutput(track: audio, outputSettings: pcmSettings)
        r1.add(o1)
        r1.startReading()
        var sampleRate = 0.0, channels = 1
        var levels: [Float] = [], sum: Float = 0, n = 0, window = 1
        while let sb = o1.copyNextSampleBuffer() {
            if sampleRate == 0, let fd = CMSampleBufferGetFormatDescription(sb),
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee {
                sampleRate = asbd.mSampleRate; channels = max(1, Int(asbd.mChannelsPerFrame))
                window = max(1, Int(sampleRate / 20)) * channels
            }
            guard let x = floats(sb) else { continue }
            for i in 0..<x.count {
                sum += x[i] * x[i]; n += 1
                if n == window { levels.append((sum / Float(n)).squareRoot()); sum = 0; n = 0 }
            }
        }
        guard sampleRate > 0, !levels.isEmpty else { return .silent }
        // Ignore stretches of pure digital silence (the camera mic sometimes sends zeros)
        let audible = levels.filter { $0 > 1e-6 }.sorted(by: >)
        guard !audible.isEmpty else { return .silent }
        let loud = audible.prefix(max(1, audible.count / 5))
        let speech = loud.reduce(0, +) / Float(loud.count)
        let gain = min(maxGain, targetLevel / speech)
        guard gain >= minUsefulGain else { return .loudEnough }
        // Hiss = the quietest tenth of windows. levels are RMS; the gate follows average |signal|
        // (≈ 0.8 × RMS), so 2× the hiss RMS sits safely above hiss and well below speech.
        let quiet = audible.suffix(max(1, audible.count / 10))
        let noiseFloor = quiet.reduce(0, +) / Float(quiet.count)
        let gateThreshold = min(noiseFloor * 2, speech * 0.2)

        // Pass 2: copy video, rewrite audio with the boost
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".boost-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: tmp, fileType: .mov)
        let reader = try AVAssetReader(asset: asset)
        var vOut: AVAssetReaderTrackOutput?, vIn: AVAssetWriterInput?
        if let video {
            let o = AVAssetReaderTrackOutput(track: video, outputSettings: nil)
            let i = AVAssetWriterInput(mediaType: .video, outputSettings: nil,
                                       sourceFormatHint: (video.formatDescriptions.first as! CMFormatDescription))
            i.transform = video.preferredTransform
            i.expectsMediaDataInRealTime = false
            reader.add(o); writer.add(i); vOut = o; vIn = i
        }
        let aOut = AVAssetReaderTrackOutput(track: audio, outputSettings: pcmSettings)
        let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels,
        ])
        aIn.expectsMediaDataInRealTime = false
        reader.add(aOut); writer.add(aIn)
        guard reader.startReading(), writer.startWriting() else {
            throw writer.error ?? reader.error ?? CocoaError(.fileWriteUnknown)
        }
        writer.startSession(atSourceTime: .zero)

        let group = DispatchGroup()
        if let vOut, let vIn {
            group.enter()
            vIn.requestMediaDataWhenReady(on: DispatchQueue(label: "boost.video")) {
                while vIn.isReadyForMoreMediaData {
                    guard let sb = vOut.copyNextSampleBuffer() else { vIn.markAsFinished(); group.leave(); return }
                    vIn.append(sb)
                }
            }
        }
        var shaper = Shaper(gain: gain, gateThreshold: gateThreshold, sampleRate: sampleRate, channels: channels)
        group.enter()
        aIn.requestMediaDataWhenReady(on: DispatchQueue(label: "boost.audio")) {
            while aIn.isReadyForMoreMediaData {
                guard let sb = aOut.copyNextSampleBuffer() else { aIn.markAsFinished(); group.leave(); return }
                guard var x = floats(sb), let fd = CMSampleBufferGetFormatDescription(sb) else { continue }
                // Shape the samples, then re-wrap them with the original format and timing
                x.withUnsafeMutableBufferPointer { shaper.process($0.baseAddress!, count: $0.count, channels: channels) }
                let bytes = x.count * 4
                var block: CMBlockBuffer?
                CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes,
                                                   blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                   dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                   blockBufferOut: &block)
                guard let block else { continue }
                x.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                                                       offsetIntoDestination: 0, dataLength: bytes) }
                var out: CMSampleBuffer?
                CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                    allocator: nil, dataBuffer: block, formatDescription: fd,
                    sampleCount: CMSampleBufferGetNumSamples(sb),
                    presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sb),
                    packetDescriptions: nil, sampleBufferOut: &out)
                if let out { aIn.append(out) }
            }
        }
        group.wait()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed, reader.status == .completed else {
            try? FileManager.default.removeItem(at: tmp)
            throw writer.error ?? reader.error ?? CocoaError(.fileWriteUnknown)
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        return .boosted(20 * log10(gain))
    }
}

// MARK: - UI

final class PreviewView: NSView {
    let previewLayer: AVCaptureVideoPreviewLayer
    init(session: AVCaptureSession) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        previewLayer.videoGravity = .resizeAspect
        layer?.addSublayer(previewLayer)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); previewLayer.frame = bounds }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let camera = Camera()
    var window: NSWindow!
    let message = NSTextField(labelWithString: "")
    let saved = NSTextField(labelWithString: "")
    let badge = NSTextField(labelWithString: "")
    let flash = NSView()
    let meter = NSLevelIndicator()
    let micPopup = NSPopUpButton()
    let intervalPopup = NSPopUpButton()
    let boostCheck = NSButton(checkboxWithTitle: "Boost quiet sound", target: nil, action: nil)
    var boosting = false
    var shutterButton: NSButton!
    var recordButton: NSButton!
    var timelapseButton: NSButton!
    var badgeTimer: Timer?
    var recStart = Date()
    var isLive = false
    var lastSaved: URL?
    // Time-lapse
    var timelapse: TimelapseWriter?
    var timelapseTimer: Timer?
    let intervals: [(String, TimeInterval)] = [("1 sec", 1), ("2 sec", 2), ("5 sec", 5), ("10 sec", 10), ("30 sec", 30), ("1 min", 60)]
    let shutterSound = NSSound(contentsOfFile:
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Shutter.aif",
        byReference: true) ?? NSSound(named: "Tink")

    func applicationDidFinishLaunching(_ n: Notification) {
        buildMenu()
        buildWindow()
        camera.onStatus = { [weak self] msg in
            guard let self else { return }
            self.isLive = msg == nil
            self.message.stringValue = msg ?? ""
            self.message.isHidden = msg == nil
            self.updateButtons()
        }
        camera.onRecordingFinished = { [weak self] url, error in self?.recordingFinished(url, error) }
        camera.onLevel = { [weak self] level in self?.meter.doubleValue = level * 10 }
        camera.onMicSilent = { [weak self] in self?.micWentSilent() }
        camera.onStatus?("Starting…")
        AVCaptureDevice.requestAccess(for: .video) { ok in
            DispatchQueue.main.async {
                log("camera access: \(ok)")
                guard ok else {
                    self.camera.onStatus?("Camera access is off.\nTurn on Keychain Cam in System Settings → Privacy & Security → Camera.")
                    return
                }
                AVCaptureDevice.requestAccess(for: .audio) { micOK in
                    DispatchQueue.main.async {
                        log("mic access: \(micOK)")
                        self.camera.micAllowed = micOK
                        self.camera.connect()
                    }
                }
            }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Finish writing a recording or time-lapse before quitting so the file isn't lost
        if camera.isRecording {
            camera.onRecordingFinished = { _, _ in NSApp.reply(toApplicationShouldTerminate: true) }
            camera.stopRecording()
            return .terminateLater
        }
        if let tl = timelapse {
            timelapseTimer?.invalidate()
            tl.finish { _ in NSApp.reply(toApplicationShouldTerminate: true) }
            return .terminateLater
        }
        return .terminateNow
    }

    private func button(_ title: String, _ symbol: String?, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        if let symbol {
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            b.imagePosition = .imageLeading
        }
        b.bezelStyle = .rounded
        b.controlSize = .large
        return b
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Keychain Cam"
        window.minSize = NSSize(width: 880, height: 460)
        window.center()

        let root = NSView()
        let preview = PreviewView(session: camera.session)

        message.font = .systemFont(ofSize: 20, weight: .medium)
        message.textColor = .white
        message.alignment = .center
        message.maximumNumberOfLines = 3

        flash.wantsLayer = true
        flash.layer?.backgroundColor = NSColor.white.cgColor
        flash.alphaValue = 0

        badge.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        badge.textColor = .white
        badge.drawsBackground = true
        badge.backgroundColor = NSColor.systemRed.withAlphaComponent(0.85)
        badge.isBordered = false
        badge.isHidden = true

        // Row 1: sound + time-lapse settings
        let soundLabel = NSTextField(labelWithString: "Sound:")
        micPopup.addItems(withTitles: MicChoice.allCases.map(\.rawValue))
        micPopup.selectItem(withTitle: camera.micChoice.rawValue)
        micPopup.target = self; micPopup.action = #selector(micChanged)
        meter.levelIndicatorStyle = .continuousCapacity
        meter.minValue = 0; meter.maxValue = 10
        meter.warningValue = 8; meter.criticalValue = 9.5
        meter.widthAnchor.constraint(equalToConstant: 140).isActive = true
        meter.toolTip = "Live sound level"

        let tlLabel = NSTextField(labelWithString: "Time-lapse: a frame every")
        intervalPopup.addItems(withTitles: intervals.map(\.0))
        intervalPopup.selectItem(at: UserDefaults.standard.object(forKey: "interval") as? Int ?? 2)
        intervalPopup.target = self; intervalPopup.action = #selector(intervalChanged)
        timelapseButton = button("  Start Time-lapse  ", "timer", #selector(toggleTimelapse))
        timelapseButton.keyEquivalent = "t"
        timelapseButton.toolTip = "Start or stop a time-lapse (T)"

        boostCheck.state = UserDefaults.standard.object(forKey: "boost") as? Bool ?? true ? .on : .off
        boostCheck.target = self; boostCheck.action = #selector(boostChanged)
        boostCheck.toolTip = "After recording, raise quiet sound (like the keychain camera's weak mic) to a normal level"

        let row1 = NSStackView(views: [soundLabel, micPopup, meter, boostCheck, NSView(), tlLabel, intervalPopup, timelapseButton])

        // Row 2: status + main actions
        shutterButton = button("  Take Photo  ", "camera.fill", #selector(takePhoto))
        shutterButton.keyEquivalent = " "
        shutterButton.toolTip = "Take a photo (Space)"
        recordButton = button("  Record  ", "record.circle", #selector(toggleRecording))
        recordButton.contentTintColor = .systemRed
        recordButton.keyEquivalent = "r"
        recordButton.toolTip = "Start or stop recording video (R)"
        let folderButton = button("Show Photos", nil, #selector(showPhotos))

        saved.textColor = .secondaryLabelColor
        saved.lineBreakMode = .byTruncatingMiddle
        saved.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row2 = NSStackView(views: [saved, NSView(), folderButton, recordButton, shutterButton])

        for r in [row1, row2] { r.orientation = .horizontal; r.spacing = 10 }
        let bar = NSStackView(views: [row1, row2])
        bar.orientation = .vertical
        bar.alignment = .leading
        bar.distribution = .fill
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 12, right: 16)
        for r in [row1, row2] {
            r.translatesAutoresizingMaskIntoConstraints = false
            r.widthAnchor.constraint(equalTo: bar.widthAnchor, constant: -32).isActive = true
        }

        for v in [preview, message, flash, badge, bar] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: root.topAnchor),
            preview.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            preview.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            message.centerXAnchor.constraint(equalTo: preview.centerXAnchor),
            message.centerYAnchor.constraint(equalTo: preview.centerYAnchor),
            message.widthAnchor.constraint(lessThanOrEqualTo: preview.widthAnchor, constant: -40),
            flash.topAnchor.constraint(equalTo: preview.topAnchor),
            flash.bottomAnchor.constraint(equalTo: preview.bottomAnchor),
            flash.leadingAnchor.constraint(equalTo: preview.leadingAnchor),
            flash.trailingAnchor.constraint(equalTo: preview.trailingAnchor),
            badge.topAnchor.constraint(equalTo: preview.topAnchor, constant: 14),
            badge.leadingAnchor.constraint(equalTo: preview.leadingAnchor, constant: 14),
        ])
        window.contentView = root
        window.makeKeyAndOrderFront(nil)
    }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Keychain Cam", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let fileItem = NSMenuItem(); main.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Take Photo", action: #selector(takePhoto), keyEquivalent: "p")
        fileMenu.addItem(withTitle: "Start/Stop Recording", action: #selector(toggleRecording), keyEquivalent: "r")
        fileMenu.addItem(withTitle: "Start/Stop Time-lapse", action: #selector(toggleTimelapse), keyEquivalent: "t")
        fileMenu.addItem(withTitle: "Show Photos", action: #selector(showPhotos), keyEquivalent: "o")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        NSApp.mainMenu = main
    }

    private func updateButtons() {
        let busy = camera.isRecording || timelapse != nil
        shutterButton.isEnabled = isLive
        recordButton.isEnabled = isLive && timelapse == nil && !boosting
        timelapseButton.isEnabled = (isLive && !camera.isRecording) || timelapse != nil
        micPopup.isEnabled = !busy
        intervalPopup.isEnabled = timelapse == nil
    }

    // MARK: Badge (REC / TIME-LAPSE indicator)

    private func showBadge() {
        badge.isHidden = false
        updateBadge()
        badgeTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.updateBadge() }
    }

    private func hideBadge() {
        badgeTimer?.invalidate(); badgeTimer = nil
        badge.isHidden = true
    }

    private func updateBadge() {
        let t = Int(Date().timeIntervalSince(recStart))
        let clock = String(format: "%02d:%02d", t / 60, t % 60)
        if let tl = timelapse {
            let secs = Double(tl.frames) / Double(TimelapseWriter.playbackFPS)
            badge.stringValue = String(format: "  ⏱ TIME-LAPSE  %@  ·  %lld frames → %.1fs of video  ", clock, tl.frames, secs)
        } else {
            badge.stringValue = "  ● REC  \(clock)\(camera.micName == nil ? "  (no sound)" : "")  "
        }
    }

    // MARK: Actions

    @objc func micChanged() {
        guard let choice = MicChoice(rawValue: micPopup.titleOfSelectedItem ?? "") else { return }
        camera.micChoice = choice
        camera.connect(force: true)
    }

    /// The mic is sending pure silence (the keychain camera's mic does this now and then).
    private func micWentSilent() {
        if camera.isRecording {
            saved.stringValue = "⚠︎ The mic went silent – this video may have no sound. Stop, and set Sound to Mac mic."
            NSSound.beep()
        } else if camera.micChoice == .camera, timelapse == nil {
            camera.micChoice = .mac
            micPopup.selectItem(withTitle: MicChoice.mac.rawValue)
            camera.connect(force: true)
            saved.stringValue = "The camera's mic went silent, so Sound is now Mac mic. To try it again, replug the camera and pick Camera mic."
        } else if timelapse == nil {
            saved.stringValue = "⚠︎ The mic isn't sending any sound. Try another one in the Sound menu."
        }
    }

    @objc func boostChanged() {
        UserDefaults.standard.set(boostCheck.state == .on, forKey: "boost")
    }

    @objc func intervalChanged() {
        UserDefaults.standard.set(intervalPopup.indexOfSelectedItem, forKey: "interval")
    }

    @objc func takePhoto() {
        guard let url = camera.snapshot() else { NSSound.beep(); return }
        lastSaved = url
        shutterSound?.stop(); shutterSound?.play()
        flashScreen(0.85)
        saved.stringValue = "Saved \(url.lastPathComponent)"
    }

    private func flashScreen(_ alpha: CGFloat) {
        flash.alphaValue = alpha
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.35
            flash.animator().alphaValue = 0
        }
    }

    @objc func toggleRecording() {
        if camera.isRecording {
            recordButton.isEnabled = false          // re-enabled once the file is written
            camera.stopRecording()
            return
        }
        guard timelapse == nil, camera.startRecording() != nil else { NSSound.beep(); return }
        recStart = Date()
        recordButton.title = "  Stop  "
        recordButton.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: nil)
        badge.backgroundColor = NSColor.systemRed.withAlphaComponent(0.85)
        showBadge()
        updateButtons()
    }

    private func recordingFinished(_ url: URL, _ error: Error?) {
        hideBadge()
        recordButton.title = "  Record  "
        recordButton.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: nil)
        updateButtons()
        let t = Int(Date().timeIntervalSince(recStart))
        if FileManager.default.fileExists(atPath: url.path) {
            lastSaved = url
            let summary = "Saved \(url.lastPathComponent) (\(t / 60):\(String(format: "%02d", t % 60)))"
                + (error == nil ? "" : " – stopped early")
            saved.stringValue = summary
            guard boostCheck.state == .on, camera.micName != nil else { return }
            // Raise the sound level in the background; keep recording disabled until it's done
            boosting = true
            updateButtons()
            saved.stringValue = summary + " – boosting sound…"
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try AudioBoost.process(url) }
                DispatchQueue.main.async {
                    self.boosting = false
                    self.updateButtons()
                    switch result {
                    case .success(.boosted(let db)):
                        log(String(format: "boosted %@ by %.1f dB", url.lastPathComponent, db))
                        self.saved.stringValue = summary + String(format: " – sound +%.0f dB", db)
                    case .success(.loudEnough):
                        log("boost: \(url.lastPathComponent) already loud enough")
                        self.saved.stringValue = summary
                    case .success(.silent):
                        log("boost: \(url.lastPathComponent) has no sound at all")
                        self.saved.stringValue = summary + " – ⚠︎ no sound was recorded"
                    case .failure(let e):
                        log("boost failed: \(e)")
                        self.saved.stringValue = summary + " – couldn't boost sound"
                    }
                }
            }
        } else {
            saved.stringValue = "Recording failed: \(error?.localizedDescription ?? "unknown error")"
            NSSound.beep()
        }
    }

    @objc func toggleTimelapse() {
        if let tl = timelapse {
            timelapseTimer?.invalidate(); timelapseTimer = nil
            timelapseButton.isEnabled = false
            saved.stringValue = "Finishing time-lapse…"
            tl.finish { [weak self] url in
                guard let self else { return }
                self.timelapse = nil
                self.hideBadge()
                self.timelapseButton.title = "  Start Time-lapse  "
                self.timelapseButton.image = NSImage(systemSymbolName: "timer", accessibilityDescription: nil)
                self.updateButtons()
                if let url {
                    self.lastSaved = url
                    self.saved.stringValue = "Saved \(url.lastPathComponent) (\(tl.frames) frames)"
                } else {
                    self.saved.stringValue = "Time-lapse had no frames – nothing saved"
                }
            }
            return
        }
        guard isLive, !camera.isRecording else { NSSound.beep(); return }
        let interval = intervals[max(0, intervalPopup.indexOfSelectedItem)].1
        let tl = TimelapseWriter(url: nextURL(ext: "mp4", suffix: "_timelapse"))
        timelapse = tl
        recStart = Date()
        captureTimelapseFrame()
        timelapseTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.captureTimelapseFrame()
        }
        timelapseButton.title = "  Stop Time-lapse  "
        timelapseButton.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: nil)
        badge.backgroundColor = NSColor.systemIndigo.withAlphaComponent(0.85)
        showBadge()
        updateButtons()
        log("time-lapse every \(interval)s")
    }

    private func captureTimelapseFrame() {
        guard let tl = timelapse, let pb = camera.latestFrame() else { return }
        tl.append(pb)
        flashScreen(0.25)
        updateBadge()
    }

    @objc func showPhotos() {
        try? FileManager.default.createDirectory(at: photosDir, withIntermediateDirectories: true)
        if let lastSaved { NSWorkspace.shared.activateFileViewerSelecting([lastSaved]) }
        else { NSWorkspace.shared.open(photosDir) }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
