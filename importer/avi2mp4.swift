// avi2mp4 — converts the keychain camera's AVI files (motion-JPEG video with PCM or
// IMA-ADPCM audio) into an H.264/AAC .mp4 that plays in Photos, QuickTime and on phones.
// No dependencies: parses the AVI (RIFF) container itself and encodes with AVFoundation.
//
// Quiet audio (the camera's mic is weak) is raised to a normal level with a gentle noise
// gate, the same way Keychain Cam.app does it; pass --no-boost to keep it as recorded.
//
// Usage: avi2mp4 [--no-boost] <in.avi> <out.mp4>

import Foundation
import AVFoundation
import CoreGraphics
import ImageIO

func fail(_ m: String) -> Never {
    FileHandle.standardError.write("avi2mp4: \(m)\n".data(using: .utf8)!)
    exit(1)
}

let boostEnabled = !CommandLine.arguments.contains("--no-boost")
let args = CommandLine.arguments.filter { !$0.hasPrefix("--") }
guard args.count == 3 else { fail("usage: avi2mp4 [--no-boost] <in.avi> <out.mp4>") }
let inURL = URL(fileURLWithPath: args[1])
let outURL = URL(fileURLWithPath: args[2])
guard let fileData = try? Data(contentsOf: inURL, options: .alwaysMapped) as NSData else { fail("can't read \(args[1])") }
let base = fileData.bytes.assumingMemoryBound(to: UInt8.self)
let fileLength = fileData.length

// MARK: - RIFF / AVI parsing

func u16(_ o: Int) -> Int { Int(base[o]) | Int(base[o + 1]) << 8 }
func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
func fourCC(_ o: Int) -> String { String(bytes: (0..<4).map { base[o + $0] }, encoding: .ascii) ?? "????" }

struct Stream { var type = "", handler = "", scale = 1, rate = 1, fmt = 0, fmtSize = 0 }
var streams: [Stream] = []
var videoChunks: [(offset: Int, size: Int)] = []
var audioChunks: [(offset: Int, size: Int)] = []

func walk(_ start: Int, _ end: Int, inMovi: Bool) {
    var o = start
    while o + 8 <= end {
        let id = fourCC(o), size = u32(o + 4), body = o + 8
        if body + size > fileLength { break }          // truncated file (camera switched off) — keep what we have
        switch id {
        case "RIFF", "LIST":
            let type = fourCC(body)
            if type == "strl" { streams.append(Stream()) }
            walk(body + 4, body + size, inMovi: inMovi || type == "movi")
        case "strh" where !streams.isEmpty:
            streams[streams.count - 1].type = fourCC(body)
            streams[streams.count - 1].handler = fourCC(body + 4)
            streams[streams.count - 1].scale = max(1, u32(body + 20))
            streams[streams.count - 1].rate = max(1, u32(body + 24))
        case "strf" where !streams.isEmpty:
            streams[streams.count - 1].fmt = body
            streams[streams.count - 1].fmtSize = size
        default:
            if inMovi, let n = Int(id.prefix(2)), n < streams.count {
                let kind = id.suffix(2)
                if streams[n].type == "vids", kind == "dc" || kind == "db" { videoChunks.append((body, size)) }
                else if streams[n].type == "auds", kind == "wb" { audioChunks.append((body, size)) }
            }
        }
        o = body + size + (size & 1)                   // chunks are padded to even sizes
    }
}

guard fileLength > 12, fourCC(0) == "RIFF", fourCC(8) == "AVI " else { fail("not an AVI file") }
walk(0, fileLength, inMovi: false)
guard let video = streams.first(where: { $0.type == "vids" }), video.fmt > 0 else { fail("no video stream") }
guard !videoChunks.isEmpty else { fail("no video frames") }

let width = u32(video.fmt + 4)
let height = abs(Int(Int32(truncatingIfNeeded: u32(video.fmt + 8))))
let codec = fourCC(video.fmt + 16)
let fps = Double(video.rate) / Double(video.scale)

// MARK: - Audio decoding (to 16-bit PCM)

var pcm: [Int16] = []
var sampleRate = 0, channels = 0
var audioDescription = "none"

let imaStep: [Int] = [7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60, 66,
    73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544,
    598, 658, 724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327,
    3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899, 15289, 16818,
    18500, 20350, 22385, 24623, 27086, 29794, 32767]
let imaIndex: [Int] = [-1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8]

func decodeIMA(_ bytes: [UInt8], blockAlign: Int, channels ch: Int, samplesPerBlock: Int) -> [Int16] {
    var out: [Int16] = []
    out.reserveCapacity(bytes.count * 2)
    var b = 0
    while b + 4 * ch <= bytes.count {
        let blockEnd = min(b + blockAlign, bytes.count)
        var pred = [Int](repeating: 0, count: ch), idx = [Int](repeating: 0, count: ch)
        var perChannel = [[Int16]](repeating: [], count: ch)
        for c in 0..<ch {
            let h = b + 4 * c
            pred[c] = Int(Int16(bitPattern: UInt16(bytes[h]) | UInt16(bytes[h + 1]) << 8))
            idx[c] = min(88, Int(bytes[h + 2]))
            perChannel[c].append(Int16(pred[c]))
        }
        var p = b + 4 * ch
        // Data comes in groups of 4 bytes (8 samples) per channel
        while p + 4 * ch <= blockEnd && perChannel[0].count < samplesPerBlock {
            for c in 0..<ch {
                for k in 0..<4 {
                    let byte = Int(bytes[p + 4 * c + k])
                    for nib in [byte & 0x0F, byte >> 4] {
                        let step = imaStep[idx[c]]
                        var diff = step >> 3
                        if nib & 4 != 0 { diff += step }
                        if nib & 2 != 0 { diff += step >> 1 }
                        if nib & 1 != 0 { diff += step >> 2 }
                        pred[c] = max(-32768, min(32767, nib & 8 != 0 ? pred[c] - diff : pred[c] + diff))
                        idx[c] = max(0, min(88, idx[c] + imaIndex[nib]))
                        perChannel[c].append(Int16(pred[c]))
                    }
                }
            }
            p += 4 * ch
        }
        let n = min(samplesPerBlock, perChannel.map(\.count).min() ?? 0)
        for i in 0..<n { for c in 0..<ch { out.append(perChannel[c][i]) } }
        b += blockAlign
    }
    return out
}

if let audio = streams.first(where: { $0.type == "auds" }), audio.fmt > 0, !audioChunks.isEmpty {
    let tag = u16(audio.fmt)
    channels = max(1, u16(audio.fmt + 2))
    sampleRate = u32(audio.fmt + 4)
    let blockAlign = u16(audio.fmt + 12)
    let bits = u16(audio.fmt + 14)
    var raw: [UInt8] = []
    raw.reserveCapacity(audioChunks.reduce(0) { $0 + $1.size })
    for c in audioChunks { raw.append(contentsOf: UnsafeBufferPointer(start: base + c.offset, count: c.size)) }

    switch (tag, bits) {
    case (1, 16):
        pcm = raw.withUnsafeBytes { Array($0.bindMemory(to: Int16.self).prefix(raw.count / 2)) }
        audioDescription = "PCM 16-bit"
    case (1, 8):
        pcm = raw.map { Int16((Int($0) - 128) << 8) }
        audioDescription = "PCM 8-bit"
    case (0x11, _):
        let spb = audio.fmtSize >= 20 ? u16(audio.fmt + 18) : (blockAlign - 4 * channels) * 8 / (4 * channels) + 1
        pcm = decodeIMA(raw, blockAlign: blockAlign, channels: channels, samplesPerBlock: spb)
        audioDescription = "IMA ADPCM"
    default:
        audioDescription = "unsupported (format 0x\(String(tag, radix: 16)), \(bits)-bit) – skipped"
    }
    if pcm.isEmpty || sampleRate <= 0 { sampleRate = 0 }
}

// MARK: - Sound boost (same as Keychain Cam.app's AudioBoost)

/// Raises quiet speech towards −18 dBFS (max +36 dB) with a ~90 Hz high-pass, a gentle noise
/// gate a little above the hiss, and a soft limiter. Returns the gain in dB, or nil if unchanged.
func boostPCM(_ pcm: inout [Int16], sampleRate: Int, channels: Int) -> Float? {
    let sr = Float(sampleRate)
    var x = pcm.map { Float($0) / 32768 }
    var levels: [Float] = [], sum: Float = 0, n = 0
    let window = max(1, sampleRate / 20) * channels
    for v in x { sum += v * v; n += 1; if n == window { levels.append((sum / Float(n)).squareRoot()); sum = 0; n = 0 } }
    let audible = levels.filter { $0 > 1e-6 }.sorted(by: >)
    guard !audible.isEmpty else { return nil }
    let loud = audible.prefix(max(1, audible.count / 5))
    let speech = loud.reduce(0, +) / Float(loud.count)
    let gain = min(63.1, 0.126 / speech)
    guard gain >= 1.41 else { return nil }
    let quiet = audible.suffix(max(1, audible.count / 10))
    let threshold = min(quiet.reduce(0, +) / Float(quiet.count) * 2, speech * 0.2)

    let rc = 1 / (2 * Float.pi * 90), alpha = rc / (rc + 1 / sr)
    let envCoef = exp(-1 / (sr * 0.020)), openCoef = exp(-1 / (sr * 0.003)), closeCoef = exp(-1 / (sr * 0.150))
    var prevIn = [Float](repeating: 0, count: channels), prevOut = prevIn
    var envelope: Float = 0, gate: Float = 1
    for i in 0..<x.count {
        let c = i % channels
        let y = alpha * (prevOut[c] + x[i] - prevIn[c])
        prevIn[c] = x[i]; prevOut[c] = y
        envelope = envCoef * envelope + (1 - envCoef) * abs(y)
        let r = envelope / threshold
        let target: Float = r >= 1 ? 1 : max(0.125, r * r)
        gate = target > gate ? openCoef * gate + (1 - openCoef) * target : closeCoef * gate + (1 - closeCoef) * target
        var z = y * gain * gate
        let m = abs(z)
        if m > 0.45 { z = (z < 0 ? -1 : 1) * (0.45 + 0.35 * tanh((m - 0.45) / 0.35)) }
        x[i] = z
    }
    pcm = x.map { Int16(max(-32768, min(32767, $0 * 32767))) }
    return 20 * log10(gain)
}

var boostNote = ""
if boostEnabled, sampleRate > 0, !pcm.isEmpty, let db = boostPCM(&pcm, sampleRate: sampleRate, channels: channels) {
    boostNote = String(format: ", boosted +%.0f dB", db)
}

// MARK: - Encoding

try? FileManager.default.removeItem(at: outURL)
let writer: AVAssetWriter
do { writer = try AVAssetWriter(outputURL: outURL, fileType: .mp4) } catch { fail("can't create \(args[2]): \(error)") }

let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: width,
    AVVideoHeightKey: height,
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(2_000_000, width * height * 4)],
])
videoIn.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoIn, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: width,
    kCVPixelBufferHeightKey as String: height,
])
writer.add(videoIn)

var audioIn: AVAssetWriterInput?
if sampleRate > 0 {
    let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: channels,
    ])
    a.expectsMediaDataInRealTime = false
    if writer.canAdd(a) { writer.add(a); audioIn = a } else { audioDescription += " (AAC can't take \(sampleRate) Hz – skipped)" }
}

guard writer.startWriting() else { fail("writer failed to start: \(String(describing: writer.error))") }
writer.startSession(atSourceTime: .zero)

let group = DispatchGroup()
var badFrames = 0, writtenFrames = 0
let rgb = CGColorSpace(name: CGColorSpace.sRGB)!

func pixelBuffer(forJPEGAt offset: Int, size: Int) -> CVPixelBuffer? {
    let jpeg = Data(bytes: base + offset, count: size) as CFData
    guard let src = CGImageSourceCreateWithData(jpeg, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil),
          let pool = adaptor.pixelBufferPool else { return nil }
    var pb: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
    guard let pb else { return nil }
    CVPixelBufferLockBaseAddress(pb, [])
    defer { CVPixelBufferUnlockBaseAddress(pb, []) }
    guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: width, height: height,
                              bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: rgb,
                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return nil }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return pb
}

group.enter()
var frameIndex = 0
videoIn.requestMediaDataWhenReady(on: DispatchQueue(label: "video")) {
    while videoIn.isReadyForMoreMediaData {
        guard frameIndex < videoChunks.count else { videoIn.markAsFinished(); group.leave(); return }
        let chunk = videoChunks[frameIndex]
        let pts = CMTime(value: Int64(frameIndex) * Int64(video.scale), timescale: CMTimeScale(video.rate))
        frameIndex += 1
        if chunk.size == 0 { continue }                // dropped frame: previous one stays on screen
        if let pb = pixelBuffer(forJPEGAt: chunk.offset, size: chunk.size), adaptor.append(pb, withPresentationTime: pts) {
            writtenFrames += 1
        } else {
            badFrames += 1
        }
    }
}

if let audioIn {
    var asbd = AudioStreamBasicDescription(
        mSampleRate: Float64(sampleRate), mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
        mBytesPerPacket: UInt32(2 * channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(2 * channels),
        mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 16, mReserved: 0)
    var format: CMAudioFormatDescription?
    CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                   magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
    let totalFrames = pcm.count / channels
    var position = 0
    group.enter()
    audioIn.requestMediaDataWhenReady(on: DispatchQueue(label: "audio")) {
        while audioIn.isReadyForMoreMediaData {
            guard position < totalFrames, let format else { audioIn.markAsFinished(); group.leave(); return }
            let n = min(4096, totalFrames - position)
            let byteCount = n * channels * 2
            var block: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: byteCount,
                                               blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                               dataLength: byteCount, flags: kCMBlockBufferAssureMemoryNowFlag,
                                               blockBufferOut: &block)
            pcm.withUnsafeBytes { raw in
                _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress! + position * channels * 2, blockBuffer: block!,
                                                  offsetIntoDestination: 0, dataLength: byteCount)
            }
            var sample: CMSampleBuffer?
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: nil, dataBuffer: block!, formatDescription: format, sampleCount: n,
                presentationTimeStamp: CMTime(value: Int64(position), timescale: CMTimeScale(sampleRate)),
                packetDescriptions: nil, sampleBufferOut: &sample)
            if let sample { audioIn.append(sample) }
            position += n
        }
    }
}

group.wait()
let videoDuration = CMTime(value: Int64(videoChunks.count) * Int64(video.scale), timescale: CMTimeScale(video.rate))
let audioDuration = sampleRate > 0 ? CMTime(value: Int64(pcm.count / max(channels, 1)), timescale: CMTimeScale(sampleRate)) : .zero
writer.endSession(atSourceTime: CMTimeMaximum(videoDuration, audioDuration))
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()

guard writer.status == .completed, writtenFrames > 0 else {
    try? FileManager.default.removeItem(at: outURL)
    fail("conversion failed (\(codec) video, \(writtenFrames) frames ok, \(badFrames) unreadable): \(String(describing: writer.error))")
}
print(String(format: "avi2mp4: %@ → %@  %dx%d %@ @ %.2f fps, %d frames (%d unreadable), %.1fs, audio: %@%@",
             inURL.lastPathComponent, outURL.lastPathComponent, width, height, codec, fps, writtenFrames, badFrames,
             videoDuration.seconds, audioDescription,
             sampleRate > 0 ? " \(sampleRate) Hz \(channels) ch\(boostNote)" : ""))
