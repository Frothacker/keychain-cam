import AVFoundation
// Usage: audiocheck <movie>  — lists tracks and measures audio loudness
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let asset = AVURLAsset(url: url)
let sem = DispatchSemaphore(value: 0)
Task {
    let dur = try await asset.load(.duration)
    print(String(format: "duration %.1fs", dur.seconds))
    for t in try await asset.load(.tracks) {
        let fmts = try await t.load(.formatDescriptions)
        let sub = fmts.first.map { CMFormatDescriptionGetMediaSubType($0) } ?? 0
        let cc = String(bytes: [24,16,8,0].map { UInt8((sub >> $0) & 255) }, encoding: .ascii) ?? "?"
        print("track \(t.mediaType.rawValue) codec \(cc)")
    }
    if let a = try await asset.loadTracks(withMediaType: .audio).first {
        let r = try AVAssetReader(asset: asset)
        let o = AVAssetReaderTrackOutput(track: a, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
        r.add(o); r.startReading()
        var peak: Int32 = 0; var sumSq = 0.0; var n = 0
        while let sb = o.copyNextSampleBuffer(), let bb = CMSampleBufferGetDataBuffer(sb) {
            var len = 0; var p: UnsafeMutablePointer<CChar>?
            CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &p)
            p?.withMemoryRebound(to: Int16.self, capacity: len / 2) { s in
                for i in 0..<(len / 2) { let v = Int32(s[i]); peak = max(peak, abs(v)); sumSq += Double(v * v); n += 1 }
            }
        }
        let rms = n > 0 ? sqrt(sumSq / Double(n)) : 0
        print(String(format: "audio peak %.1f%%  rms %.2f%%  (%d samples)", Double(peak) / 327.67, rms / 327.67, n))
    } else { print("NO AUDIO TRACK") }
    sem.signal()
}
sem.wait()
