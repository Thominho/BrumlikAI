import Foundation
import CoreAudio
import Darwin

/// Core Audio process objects (macOS 14.2+): which processes are using the microphone or playing audio right now.
enum CoreAudioProcesses {
    struct Info: Identifiable, Equatable {
        let objectID: AudioObjectID
        let pid: pid_t
        let bundleID: String
        let executable: String
        let isRunningInput: Bool
        let isRunningOutput: Bool

        var id: AudioObjectID { objectID }
        var displayName: String {
            if !executable.isEmpty { return executable }
            if !bundleID.isEmpty { return bundleID }
            return "pid \(pid)"
        }
        var isCallProcess: Bool { CoreAudioProcesses.isCallProcess(bundleID: bundleID, executable: executable) }
        /// Chrome or the WhatsApp app, where Google Meet and WhatsApp calls run.
        var isOnlineCallApp: Bool { OnlineCallApps.contains(bundleID: bundleID) }
        var isCurrentProcess: Bool { pid == ProcessInfo.processInfo.processIdentifier }
    }

    /// What an app — all its processes together — is doing with audio right now.
    struct AppAudio: Equatable {
        var input = false
        var output = false

        /// Capturing the microphone and playing sound at once: that's what a call looks like.
        /// The microphone alone may be a Meet waiting room, a voice message or dictation.
        var inCall: Bool { input && output }
    }

    /// The audio of the app whose processes' bundle IDs start with `bundlePrefix` (Chrome runs audio in helpers).
    static func audio(of processes: [Info], bundlePrefix: String) -> AppAudio {
        processes.filter { $0.bundleID.hasPrefix(bundlePrefix) }.reduce(into: AppAudio()) { result, process in
            result.input = result.input || process.isRunningInput
            result.output = result.output || process.isRunningOutput
        }
    }

    /// Processes that handle iPhone (Continuity) and FaceTime calls on the Mac.
    static let callBundleIDs: Set<String> = [
        "com.apple.FaceTime",
        "com.apple.avconferenced",
        "com.apple.mobilephone",
        "com.apple.Phone",
        "com.apple.TelephonyUtilities",
        "com.apple.telephonyutilities.callservicesd"
    ]
    static let callExecutables: Set<String> = ["FaceTime", "avconferenced", "callservicesd", "Phone", "MobilePhone"]

    static func isCallProcess(bundleID: String, executable: String) -> Bool {
        callBundleIDs.contains(bundleID) || callExecutables.contains(executable)
    }

    static func list() -> [Info] {
        processObjectIDs().compactMap { info(for: $0) }
    }

    /// Call processes other than BrumlikAI that are capturing the microphone right now.
    static func activeCallProcesses() -> [Info] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return processObjectIDs().compactMap { id -> Info? in
            let runningInput: UInt32 = CoreAudioUtils.read(id, kAudioProcessPropertyIsRunningInput, default: 0)
            guard runningInput != 0, let info = info(for: id), info.pid != ownPID, info.isCallProcess else { return nil }
            return info
        }
    }

    static func objectID(for pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var qualifier = pid
        var objectID = CoreAudioUtils.unknownObject
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            CoreAudioUtils.systemObject, &address,
            UInt32(MemoryLayout<pid_t>.size), &qualifier, &size, &objectID
        )
        guard status == noErr, objectID != CoreAudioUtils.unknownObject else { return nil }
        return objectID
    }

    private static func processObjectIDs() -> [AudioObjectID] {
        CoreAudioUtils.readObjectIDs(CoreAudioUtils.systemObject, kAudioHardwarePropertyProcessObjectList)
    }

    private static func info(for id: AudioObjectID) -> Info? {
        let pid: pid_t = CoreAudioUtils.read(id, kAudioProcessPropertyPID, default: -1)
        guard pid > 0 else { return nil }
        let input: UInt32 = CoreAudioUtils.read(id, kAudioProcessPropertyIsRunningInput, default: 0)
        let output: UInt32 = CoreAudioUtils.read(id, kAudioProcessPropertyIsRunningOutput, default: 0)
        return Info(
            objectID: id,
            pid: pid,
            bundleID: CoreAudioUtils.readString(id, kAudioProcessPropertyBundleID) ?? "",
            executable: executableName(pid: pid) ?? "",
            isRunningInput: input != 0,
            isRunningOutput: output != 0
        )
    }

    private static func executableName(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer)).lastPathComponent
    }
}

enum CoreAudioUtils {
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)
    static let unknownObject = AudioObjectID(kAudioObjectUnknown)

    static func read<T>(
        _ objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        default defaultValue: T
    ) -> T {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var value = defaultValue
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer)
        }
        return status == noErr ? value : defaultValue
    }

    static func readString(
        _ objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func readObjectIDs(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    static func hasStreams(_ deviceID: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr && size > 0
    }

    static func deviceUID(_ deviceID: AudioObjectID) -> String? {
        readString(deviceID, kAudioDevicePropertyDeviceUID)
    }

    static func defaultInputDeviceName() -> String? {
        let device: AudioObjectID = read(systemObject, kAudioHardwarePropertyDefaultInputDevice, default: unknownObject)
        guard device != unknownObject else { return nil }
        return readString(device, kAudioObjectPropertyName)
    }

    /// The device that clocks the private tap device. An output-only device is preferred so that no
    /// headset microphone gets opened (which would also drop AirPods to call quality).
    static func clockDeviceUID() -> String? {
        let defaultOutput: AudioObjectID = read(systemObject, kAudioHardwarePropertyDefaultOutputDevice, default: unknownObject)
        if defaultOutput != unknownObject, !hasStreams(defaultOutput, scope: kAudioObjectPropertyScopeInput),
           let uid = deviceUID(defaultOutput) {
            return uid
        }
        for device in readObjectIDs(systemObject, kAudioHardwarePropertyDevices)
        where hasStreams(device, scope: kAudioObjectPropertyScopeOutput) && !hasStreams(device, scope: kAudioObjectPropertyScopeInput) {
            if let uid = deviceUID(device) { return uid }
        }
        return defaultOutput == unknownObject ? nil : deviceUID(defaultOutput)
    }
}
