#!/usr/bin/env swift

import Foundation
import CoreAudio

private enum CLIError: Error, CustomStringConvertible {
    case usage(String)
    case coreAudio(OSStatus, String)
    case noBlackHoleDevice
    case deviceNotFound(String)

    var description: String {
        switch self {
        case .usage(let msg):
            return msg
        case .coreAudio(let status, let context):
            return "\(context) (OSStatus: \(status))"
        case .noBlackHoleDevice:
            return "No BlackHole device found. Use `list` to inspect detected devices."
        case .deviceNotFound(let uid):
            return "No device found for UID: \(uid)"
        }
    }
}

private struct DeviceInfo {
    let id: AudioDeviceID
    let name: String
    let uid: String
}

private let lockStateFilePath = "/tmp/blackhole_sample_rate_lock_state"
private let defaultPropertyElement: AudioObjectPropertyElement = {
    if #available(macOS 12.0, *) {
        return kAudioObjectPropertyElementMain
    } else {
        return kAudioObjectPropertyElementMaster
    }
}()

private func fourCC(_ text: String) -> UInt32 {
    let bytes = Array(text.utf8)
    precondition(bytes.count == 4, "fourCC must be exactly 4 characters")
    return bytes.reduce(0) { ($0 << 8) | UInt32($1) }
}

private func propertyAddress(
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    element: AudioObjectPropertyElement = defaultPropertyElement
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: scope,
        mElement: element
    )
}

private func getAllDeviceIDs() throws -> [AudioDeviceID] {
    var address = propertyAddress(selector: kAudioHardwarePropertyDevices)
    var dataSize: UInt32 = 0

    var status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize)
    guard status == noErr else {
        throw CLIError.coreAudio(status, "Failed reading device list size")
    }

    let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
    if count == 0 {
        return []
    }
    var deviceIDs = Array(repeating: AudioDeviceID(0), count: count)
    status = deviceIDs.withUnsafeMutableBufferPointer { buffer in
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            buffer.baseAddress!
        )
    }
    guard status == noErr else {
        throw CLIError.coreAudio(status, "Failed reading device list")
    }

    return deviceIDs
}

private func readLockStateFile() -> (enabled: Bool, rate: Float64)? {
    guard let content = try? String(contentsOfFile: lockStateFilePath, encoding: .utf8) else {
        return nil
    }

    let parts = content.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
    guard parts.count >= 2, let enabledInt = Int(parts[0]), let rate = Double(parts[1]) else {
        return nil
    }
    return (enabledInt != 0, rate)
}

private func writeLockStateFile(enabled: Bool, rate: Float64) throws {
    let content = "\(enabled ? 1 : 0) \(String(format: "%.6f", rate))\n"
    try content.write(toFile: lockStateFilePath, atomically: true, encoding: .utf8)
}

private func getCFStringProperty(deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) throws -> String {
    var address = propertyAddress(selector: selector)
    var dataSize = UInt32(MemoryLayout<CFString?>.size)
    var value: CFString?
    let status = withUnsafeMutablePointer(to: &value) {
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, $0)
    }
    guard status == noErr else {
        throw CLIError.coreAudio(status, "Failed reading string property \(selector) for device \(deviceID)")
    }
    return (value as String?) ?? ""
}

private func getFloat64Property(deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) throws -> Float64 {
    var address = propertyAddress(selector: selector)
    var dataSize = UInt32(MemoryLayout<Float64>.size)
    var value: Float64 = 0
    let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &value)
    guard status == noErr else {
        throw CLIError.coreAudio(status, "Failed reading Float64 property \(selector) for device \(deviceID)")
    }
    return value
}

private func getBlackHoleDevices() throws -> [DeviceInfo] {
    try getAllDeviceIDs().compactMap { id in
        let name = try getCFStringProperty(deviceID: id, selector: kAudioObjectPropertyName)
        let uid = try getCFStringProperty(deviceID: id, selector: kAudioDevicePropertyDeviceUID)
        let haystack = "\(name) \(uid)".lowercased()
        guard haystack.contains("blackhole") else {
            return nil
        }
        return DeviceInfo(id: id, name: name, uid: uid)
    }
}

private func resolveDevice(deviceUID: String?) throws -> DeviceInfo {
    let devices = try getBlackHoleDevices()

    if let requestedUID = deviceUID {
        guard let exact = devices.first(where: { $0.uid == requestedUID }) else {
            throw CLIError.deviceNotFound(requestedUID)
        }
        return exact
    }

    guard let first = devices.first else {
        throw CLIError.noBlackHoleDevice
    }
    return first
}

private func printUsage() {
    print("""
Usage:
  blackholectl list
  blackholectl lock on [--device-uid <uid>]
  blackholectl lock off [--device-uid <uid>]
  blackholectl lock status [--device-uid <uid>]

Notes:
  - Without --device-uid the first detected BlackHole device is used.
  - 'lock on' locks the current nominal sample rate.
""")
}

private func parseArgs() throws -> (command: String, lockAction: String?, deviceUID: String?) {
    let args = Array(CommandLine.arguments.dropFirst())
    guard !args.isEmpty else {
        throw CLIError.usage("Missing command")
    }

    if args[0] == "-h" || args[0] == "--help" || args[0] == "help" {
        printUsage()
        exit(0)
    }

    let command = args[0]
    var lockAction: String?
    var deviceUID: String?

    var index = 1
    if command == "lock" {
        guard args.count > 1 else {
            throw CLIError.usage("Missing lock action: expected on/off/status")
        }
        lockAction = args[1]
        index = 2
    }

    while index < args.count {
        switch args[index] {
        case "--device-uid":
            guard index + 1 < args.count else {
                throw CLIError.usage("Missing value for --device-uid")
            }
            deviceUID = args[index + 1]
            index += 2
        default:
            throw CLIError.usage("Unknown argument: \(args[index])")
        }
    }

    return (command, lockAction, deviceUID)
}

private func run() throws {
    let parsed = try parseArgs()

    switch parsed.command {
    case "list":
        let devices = try getBlackHoleDevices()
        if devices.isEmpty {
            throw CLIError.noBlackHoleDevice
        }
        for device in devices {
            print("\(device.name)\t\(device.uid)")
        }

    case "lock":
        guard let action = parsed.lockAction else {
            throw CLIError.usage("Missing lock action")
        }
        let device = try resolveDevice(deviceUID: parsed.deviceUID)

        switch action {
        case "on":
            let currentRate = try getFloat64Property(deviceID: device.id, selector: kAudioDevicePropertyNominalSampleRate)
            try writeLockStateFile(enabled: true, rate: currentRate)
            print("Lock enabled for \(device.name) [\(device.uid)] at \(Int(currentRate)) Hz")

        case "off":
            try writeLockStateFile(enabled: false, rate: 0.0)
            print("Lock disabled for \(device.name) [\(device.uid)]")

        case "status":
            let state = readLockStateFile()
            let enabled = state?.enabled ?? false
            let currentRate = try getFloat64Property(deviceID: device.id, selector: kAudioDevicePropertyNominalSampleRate)
            let lockedRate = state?.rate ?? 0.0
            print("Device: \(device.name) [\(device.uid)]")
            print("Lock: \(enabled ? "ON" : "OFF")")
            print("Current Rate: \(Int(currentRate)) Hz")
            if enabled {
                print("Locked Rate: \(Int(lockedRate)) Hz")
            }

        default:
            throw CLIError.usage("Unknown lock action: \(action)")
        }

    default:
        throw CLIError.usage("Unknown command: \(parsed.command)")
    }
}

do {
    try run()
} catch let error as CLIError {
    fputs("Error: \(error.description)\n", stderr)
    printUsage()
    exit(2)
} catch {
    fputs("Error: \(error)\n", stderr)
    exit(1)
}
