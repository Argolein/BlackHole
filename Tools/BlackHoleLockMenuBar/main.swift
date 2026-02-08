import AppKit
import CoreAudio
import Foundation

private let lockStateFilePath = "/tmp/blackhole_sample_rate_lock_state"
private let preferredDeviceUID = ProcessInfo.processInfo.environment["BLACKHOLE_DEVICE_UID"]

private let defaultPropertyElement: AudioObjectPropertyElement = {
    if #available(macOS 12.0, *) {
        return kAudioObjectPropertyElementMain
    } else {
        return kAudioObjectPropertyElementMaster
    }
}()

private struct LockState {
    let enabled: Bool
    let rate: Float64
}

private struct DeviceInfo {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

private func propertyAddress(
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    element: AudioObjectPropertyElement = defaultPropertyElement
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

private func getAllDeviceIDs() throws -> [AudioDeviceID] {
    var address = propertyAddress(selector: kAudioHardwarePropertyDevices)
    var dataSize: UInt32 = 0

    var status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize)
    guard status == noErr else {
        throw NSError(domain: "CoreAudio", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Failed to read device list size"]) 
    }

    let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
    if count == 0 { return [] }

    var ids = Array(repeating: AudioDeviceID(0), count: count)
    status = ids.withUnsafeMutableBufferPointer { buffer in
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, buffer.baseAddress!)
    }
    guard status == noErr else {
        throw NSError(domain: "CoreAudio", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Failed to read device list"]) 
    }

    return ids
}

private func getCFStringProperty(deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String {
    var address = propertyAddress(selector: selector)
    var dataSize = UInt32(MemoryLayout<CFString?>.size)
    var value: CFString?

    let status = withUnsafeMutablePointer(to: &value) {
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, $0)
    }
    guard status == noErr else { return "" }
    return (value as String?) ?? ""
}

private func getSampleRate(deviceID: AudioDeviceID) -> Float64? {
    var address = propertyAddress(selector: kAudioDevicePropertyNominalSampleRate)
    var dataSize = UInt32(MemoryLayout<Float64>.size)
    var value: Float64 = 0

    let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &value)
    guard status == noErr else { return nil }
    return value
}

private func findBlackHoleDevice(preferredUID: String?) -> DeviceInfo? {
    guard let ids = try? getAllDeviceIDs() else { return nil }

    let devices: [DeviceInfo] = ids.compactMap { id in
        let name = getCFStringProperty(deviceID: id, selector: kAudioObjectPropertyName)
        let uid = getCFStringProperty(deviceID: id, selector: kAudioDevicePropertyDeviceUID)
        let haystack = "\(name) \(uid)".lowercased()
        guard haystack.contains("blackhole") else { return nil }
        return DeviceInfo(id: id, uid: uid, name: name)
    }

    if let preferredUID, let match = devices.first(where: { $0.uid == preferredUID }) {
        return match
    }

    return devices.first
}

private func readLockState() -> LockState {
    guard let content = try? String(contentsOfFile: lockStateFilePath, encoding: .utf8) else {
        return LockState(enabled: false, rate: 0)
    }

    let parts = content.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
    guard parts.count >= 2, let enabledInt = Int(parts[0]), let rate = Double(parts[1]) else {
        return LockState(enabled: false, rate: 0)
    }

    return LockState(enabled: enabledInt != 0, rate: rate)
}

private func writeLockState(_ state: LockState) {
    let text = "\(state.enabled ? 1 : 0) \(String(format: "%.6f", state.rate))\n"
    try? text.write(toFile: lockStateFilePath, atomically: true, encoding: .utf8)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let infoItem = NSMenuItem(title: "Loading...", action: nil, keyEquivalent: "")
    private let lockItem = NSMenuItem(title: "Lock Sample Rate", action: #selector(toggleLock), keyEquivalent: "")
    private let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refresh), keyEquivalent: "r")
    private let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
    private var timer: Timer?
    private lazy var statusBarIcon: NSImage? = {
        guard let iconPath = Bundle.main.path(forResource: "BlackHole", ofType: "icns"),
              let image = NSImage(contentsOfFile: iconPath) else {
            return nil
        }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = false
        return image
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.menu = menu

        lockItem.target = self
        refreshItem.target = self
        quitItem.target = self

        infoItem.isEnabled = false
        menu.addItem(infoItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(lockItem)
        menu.addItem(refreshItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(quitItem)

        refreshUI()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshUI()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
    }

    @objc private func refresh() {
        refreshUI()
    }

    @objc private func toggleLock() {
        guard let device = findBlackHoleDevice(preferredUID: preferredDeviceUID),
              let currentRate = getSampleRate(deviceID: device.id) else {
            NSSound.beep()
            return
        }

        let currentState = readLockState()
        if currentState.enabled {
            writeLockState(LockState(enabled: false, rate: 0))
        } else {
            writeLockState(LockState(enabled: true, rate: currentRate))
        }

        refreshUI()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func refreshUI() {
        let state = readLockState()
        guard let device = findBlackHoleDevice(preferredUID: preferredDeviceUID),
              let sampleRate = getSampleRate(deviceID: device.id) else {
            infoItem.title = "BlackHole device not found"
            lockItem.state = .off
            statusItem.button?.title = "BH"
            statusItem.button?.image = nil
            return
        }

        infoItem.title = "\(device.name): \(Int(sampleRate)) Hz"
        lockItem.state = state.enabled ? .on : .off

        if let button = statusItem.button {
            button.image = statusBarIcon
            button.title = statusBarIcon == nil ? "BH" : ""
        }

        if state.enabled {
            lockItem.title = "Unlock Sample Rate (\(Int(state.rate)) Hz)"
        } else {
            lockItem.title = "Lock Sample Rate"
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
