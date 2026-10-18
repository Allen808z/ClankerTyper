import AppKit

/// Soft start and stop sounds for recording, generated in code: two short notes rising to
/// start, falling to stop.
@MainActor
final class SoundCues {
    private lazy var startSound = Self.sound(notes: [880, 1318.5])
    private lazy var stopSound = Self.sound(notes: [1318.5, 880])
    /// How long the start sound plays, so muting can wait until it has finished.
    static let startDuration: TimeInterval = 0.16

    func playStart() {
        guard AppSettings.playSounds else { return }
        startSound?.stop()
        startSound?.play()
    }

    func playStop() {
        guard AppSettings.playSounds else { return }
        stopSound?.stop()
        stopSound?.play()
    }

    private static func sound(notes: [Double]) -> NSSound? {
        let sound = NSSound(data: wav(notes: notes))
        sound?.volume = 0.35
        return sound
    }

    /// A 16-bit mono WAV of the notes, each 70 ms with a soft attack and decay.
    nonisolated static func wav(notes: [Double], sampleRate: Int = 44_100, noteLength: Double = 0.07) -> Data {
        let perNote = Int(Double(sampleRate) * noteLength)
        var samples: [Int16] = []
        samples.reserveCapacity(perNote * notes.count)
        for frequency in notes {
            for i in 0..<perNote {
                let t = Double(i) / Double(sampleRate)
                let progress = Double(i) / Double(perNote)
                let attack = min(1, progress * 12)
                let decay = pow(1 - progress, 2)
                let value = sin(2 * .pi * frequency * t) * attack * decay * 0.6
                samples.append(Int16(value * Double(Int16.max)))
            }
        }

        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let byteCount = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + byteCount))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))                       // fmt chunk size
        append(UInt16(1))                        // PCM
        append(UInt16(1))                        // mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))           // byte rate
        append(UInt16(2))                        // block align
        append(UInt16(16))                       // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(byteCount))
        for sample in samples { append(sample) }
        return data
    }
}
