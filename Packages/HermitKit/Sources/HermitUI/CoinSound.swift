import Foundation
import AVFoundation

/// The small "cling" when money lands: two bright bell notes (G6 then C7, 70 ms apart), each a few soft overtones
/// with a fast decay. Made in code as a WAV in memory, so there's no sound file to ship. On iPhone it plays as
/// ambient audio: the silent switch mutes it and it never stops music that's playing.
@MainActor
enum CoinSound {
    private static var player: AVAudioPlayer?
    private static let wav: Data = make()

    static func play() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        player = try? AVAudioPlayer(data: wav)
        player?.volume = 0.55
        player?.play()
    }

    private static func make() -> Data {
        let rate = 44_100.0, length = 0.75
        let n = Int(rate * length)
        var samples = [Float](repeating: 0, count: n)
        // (start seconds, base frequency)
        for (start, f) in [(0.0, 1567.98), (0.07, 2093.0)] {
            let s0 = Int(start * rate)
            for i in s0..<n {
                let t = Double(i - s0) / rate
                let attack = min(1, t / 0.002)
                // Overtones a bell-like metal has (not whole multiples), each dying away faster than the last.
                var v = 0.0
                for (ratio, amp, decay) in [(1.0, 1.0, 7.0), (2.76, 0.45, 11.0), (5.40, 0.22, 16.0), (8.93, 0.10, 22.0)] {
                    v += amp * sin(2 * .pi * f * ratio * t) * exp(-decay * t)
                }
                samples[i] += Float(v * attack * 0.26)
            }
        }
        // 16-bit mono PCM WAV.
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let bytes = UInt32(n * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate) * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        for s in samples { u16(UInt16(bitPattern: Int16(max(-1, min(1, s)) * 32_000))) }
        return d
    }
}
