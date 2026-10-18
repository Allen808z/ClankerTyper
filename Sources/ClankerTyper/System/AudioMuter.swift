import CoreAudio
import Foundation

/// Mutes the Mac's sound output while dictating, so music or a video is not picked up, and puts
/// it back afterwards. If the output was already muted, it is left muted.
@MainActor
final class AudioMuter {
    private var mutedDevice: AudioDeviceID?

    func begin() {
        guard mutedDevice == nil, let device = Self.defaultOutputDevice(),
              let alreadyMuted = Self.isMuted(device), !alreadyMuted else { return }
        if Self.setMuted(true, device: device) {
            mutedDevice = device
            AppLog.write("muted sound output while dictating")
        }
    }

    func end() {
        guard let device = mutedDevice else { return }
        mutedDevice = nil
        if Self.setMuted(false, device: device) {
            AppLog.write("restored sound output")
        }
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr ? device : nil
    }

    private static var muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    /// nil when the device has no mute control (some HDMI and USB outputs).
    private static func isMuted(_ device: AudioDeviceID) -> Bool? {
        var address = muteAddress
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var muted = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) == noErr else { return nil }
        return muted != 0
    }

    private static func setMuted(_ muted: Bool, device: AudioDeviceID) -> Bool {
        var address = muteAddress
        var value = UInt32(muted ? 1 : 0)
        let size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectSetPropertyData(device, &address, 0, nil, size, &value) == noErr
    }
}
