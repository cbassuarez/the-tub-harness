//
//  HardwareInputController.swift
//  TheTubHarness
//
//  Reads mode (0-10), JOLT state, and pedestal telemetry from a Teensy
//  panel controller over USB serial. Sends commands downstream.
//
//  Inbound protocol:
//    M<mode>,J<0|1>\n                     panel state
//    P<addr>,B<0|1>,T<tof_mm>,H<pwm>\n   pedestal telemetry
//
//  Outbound protocol:
//    H<addr>,<pwm>\n                      set pedestal halo
//    N<addr>,<r>.<g>.<b>.<w>\n            set pedestal NeoPixel
//

import Foundation
import Combine
import IOKit
import IOKit.serial

struct PedestalTelemetry: Equatable {
    let address: Int
    var button: Bool = false
    var tofMm: Int = 0
    var haloPwm: Int = 0
    var online: Bool = false
    var lastUpdate: Date = .distantPast
}

final class HardwareInputController: ObservableObject {
    @Published private(set) var isConnected: Bool = false
    @Published private(set) var devicePath: String?
    @Published private(set) var lastMode: Int?
    @Published private(set) var lastJolt: Bool = false
    @Published private(set) var pedestals: [Int: PedestalTelemetry] = [:]  // keyed by address 1-3
    @Published private(set) var availableDevicePaths: [String] = []
    @Published private(set) var preferredDevicePath: String?

    /// Called on the serial queue when mode changes. Thread-safe — call setMode from here.
    var onModeChange: ((Int) -> Void)?
    /// Called on rising edge of JOLT (pressed). Thread-safe — call pulseJolt from here.
    var onJoltPressed: (() -> Void)?
    /// Called on every JOLT state change. Thread-safe — call setJoltHeld from here.
    var onJoltHeldChange: ((Bool) -> Void)?
    /// Called when pedestal telemetry arrives.
    var onPedestalUpdate: ((PedestalTelemetry) -> Void)?

    private let queue = DispatchQueue(label: "tub.hardware.serial", qos: .userInitiated)
    private let scanQueue = DispatchQueue(label: "tub.hardware.scan", qos: .utility)
    private let discoveryLock = NSLock()
    private var fd: Int32 = -1
    private var running = false
    private var scanTimer: DispatchSourceTimer?
    private var activePortPath: String?
    private var manualPreferredPath: String?
    private var activePortOpenedAtNs: UInt64 = 0
    private var didValidateProtocolOnActivePort: Bool = false
    private var failedProbeBackoffUntil: [String: Date] = [:]
    private var lastLoggedScanSignature: String?

    // State tracking for edge detection
    private var currentMode: Int = -1
    private var currentJolt: Bool = false

    // Write lock
    private let writeLock = NSLock()

    // MARK: - Lifecycle

    func start() {
        guard !running else { return }
        running = true
        startScanning()
    }

    func stop() {
        running = false
        scanTimer?.cancel()
        scanTimer = nil
        closePort()
    }

    deinit {
        stop()
    }

    // MARK: - Device scanning

    private static let probeTimeoutNs: UInt64 = 2_500_000_000
    private static let failedProbeRetrySeconds: TimeInterval = 8
    private static let forcedPathEnvVar = "TUB_HARDWARE_SERIAL_PATH"
    private static let locationHintEnvVar = "TUB_HARDWARE_USB_LOCATION_HINT"
    private static let serialHintEnvVar = "TUB_HARDWARE_SERIAL_HINT"
    private static let debugEnvVar = "TUB_HARDWARE_DEBUG"
    private static let lastGoodPathDefaultsKey = "HardwareInputController.lastGoodPortPath"
    private static let preferredPathDefaultsKey = "HardwareInputController.preferredPortPath"
    private static let deviceGlobs: [String] = [
        "/dev/cu.usbmodem*",
        "/dev/cu.usbserial*",
        "/dev/cu.SLAB_USBtoUART*",
        "/dev/cu.wchusbserial*",
        "/dev/tty.usbmodem*",
        "/dev/tty.usbserial*",
        "/dev/tty.SLAB_USBtoUART*",
        "/dev/tty.wchusbserial*"
    ]

    init() {
        let savedPreferredPath = UserDefaults.standard.string(forKey: Self.preferredPathDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = (savedPreferredPath?.isEmpty == false) ? savedPreferredPath : nil
        manualPreferredPath = normalized
        preferredDevicePath = normalized
    }

    func setPreferredDevicePath(_ path: String?) {
        let normalized = normalizedHint(path)
        scanQueue.async { [weak self] in
            guard let self else { return }
            self.manualPreferredPath = normalized
            if let normalized {
                UserDefaults.standard.set(normalized, forKey: Self.preferredPathDefaultsKey)
                self.clearProbeFailure(path: normalized)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.preferredPathDefaultsKey)
            }
            DispatchQueue.main.async {
                self.preferredDevicePath = normalized
            }
            if self.activePortPath != normalized {
                self.closePort()
            }
            self.scanForDevice()
        }
    }

    func refreshAvailableDevices() {
        scanQueue.async { [weak self] in
            guard let self else { return }
            let locationHint = self.normalizedHint(ProcessInfo.processInfo.environment[Self.locationHintEnvVar])
            let serialHint = self.normalizedHint(ProcessInfo.processInfo.environment[Self.serialHintEnvVar])
            let rememberedPath = self.normalizedHint(UserDefaults.standard.string(forKey: Self.lastGoodPathDefaultsKey))
            let candidates = self.candidateDevicePaths(
                locationHint: locationHint,
                locationHintValues: self.parsedLocationHintValues(locationHint),
                serialHint: serialHint,
                rememberedPath: rememberedPath
            )
            DispatchQueue.main.async {
                self.availableDevicePaths = candidates
            }
            if self.fd == -1 {
                self.scanForDevice()
            }
        }
    }

    func reconnectNow() {
        scanQueue.async { [weak self] in
            guard let self else { return }
            self.closePort()
            self.scanForDevice()
        }
    }

    private func startScanning() {
        let timer = DispatchSource.makeTimerSource(queue: scanQueue)
        timer.schedule(deadline: .now(), repeating: .seconds(2))
        timer.setEventHandler { [weak self] in
            self?.scanForDevice()
        }
        timer.resume()
        scanTimer = timer
    }

    private func scanForDevice() {
        guard running, fd == -1 else { return }

        let now = Date()
        let locationHint = normalizedHint(ProcessInfo.processInfo.environment[Self.locationHintEnvVar])
        let locationHintValues = parsedLocationHintValues(locationHint)
        let serialHint = normalizedHint(ProcessInfo.processInfo.environment[Self.serialHintEnvVar])
        let rememberedPath = normalizedHint(UserDefaults.standard.string(forKey: Self.lastGoodPathDefaultsKey))
        let preferredPath = normalizedHint(manualPreferredPath)
        if let forcedPath = ProcessInfo.processInfo.environment[Self.forcedPathEnvVar]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !forcedPath.isEmpty,
           FileManager.default.fileExists(atPath: forcedPath),
           !isBackingOff(path: forcedPath, now: now),
           openPort(forcedPath) {
            return
        }
        let candidates = candidateDevicePaths(
            locationHint: locationHint,
            locationHintValues: locationHintValues,
            serialHint: serialHint,
            rememberedPath: rememberedPath
        ).filter { !isBackingOff(path: $0, now: now) }
        DispatchQueue.main.async {
            self.availableDevicePaths = candidates
        }
        if let preferredPath,
           FileManager.default.fileExists(atPath: preferredPath),
           !isBackingOff(path: preferredPath, now: now),
           openPort(preferredPath) {
            return
        }
        logScanCandidatesIfNeeded(candidates: candidates, locationHint: locationHint, serialHint: serialHint)
        for path in candidates {
            if openPort(path) { return }
        }
    }

    private func candidateDevicePaths(
        locationHint: String?,
        locationHintValues: Set<UInt32>,
        serialHint: String?,
        rememberedPath: String?
    ) -> [String] {
        var metadataByPath: [String: SerialDeviceMetadata] = [:]
        for metadata in enumerateSerialDevicesViaIOKit() {
            metadataByPath[metadata.path] = metadata
        }
        var all = Set<String>(metadataByPath.keys)
        for pattern in Self.deviceGlobs {
            for path in enumerateDevicePaths(globPattern: pattern) {
                all.insert(path)
            }
        }

        let existingRememberedPath = rememberedPath.flatMap { path in
            FileManager.default.fileExists(atPath: path) ? path : nil
        }

        return all.sorted { lhs, rhs in
            let lhsScore = candidateScore(
                path: lhs,
                locationHint: locationHint,
                locationHintValues: locationHintValues,
                serialHint: serialHint,
                metadata: metadataByPath[lhs],
                rememberedPath: existingRememberedPath
            )
            let rhsScore = candidateScore(
                path: rhs,
                locationHint: locationHint,
                locationHintValues: locationHintValues,
                serialHint: serialHint,
                metadata: metadataByPath[rhs],
                rememberedPath: existingRememberedPath
            )
            if lhsScore != rhsScore { return lhsScore < rhsScore }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }

    private func candidateScore(
        path: String,
        locationHint: String?,
        locationHintValues: Set<UInt32>,
        serialHint: String?,
        metadata: SerialDeviceMetadata?,
        rememberedPath: String?
    ) -> Int {
        var score = Self.devicePathRank(path) * 100
        let lowered = path.lowercased()
        if let metadata, metadata.locationID != nil {
            score -= 120
        }
        if let rememberedPath, rememberedPath == path {
            score -= 5_000
        }
        if let locationHint, !locationHint.isEmpty, lowered.contains(locationHint.lowercased()) {
            score -= 3_000
        }
        if let locationID = metadata?.locationID, locationHintValues.contains(locationID) {
            score -= 4_000
        }
        if let serial = metadata?.serialNumber?.lowercased(),
           let serialHint,
           !serialHint.isEmpty,
           serial.contains(serialHint.lowercased()) {
            score -= 2_500
        }
        if let serialHint, !serialHint.isEmpty, lowered.contains(serialHint.lowercased()) {
            score -= 1_500
        }
        return score
    }

    private func normalizedHint(_ value: String?) -> String? {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalized.isEmpty ? nil : normalized
    }

    private func enumerateDevicePaths(globPattern: String) -> [String] {
        var gt = glob_t()
        defer { globfree(&gt) }
        let result = glob(globPattern, 0, nil, &gt)
        guard result == 0 else { return [] }
        var out: [String] = []
        out.reserveCapacity(Int(gt.gl_matchc))
        for i in 0..<Int(gt.gl_matchc) {
            guard let cStr = gt.gl_pathv[i] else { continue }
            out.append(String(cString: cStr))
        }
        return out
    }

    private struct SerialDeviceMetadata {
        let path: String
        let locationID: UInt32?
        let serialNumber: String?
    }

    private func parsedLocationHintValues(_ hint: String?) -> Set<UInt32> {
        guard var normalized = normalizedHint(hint)?.lowercased(), !normalized.isEmpty else {
            return []
        }
        normalized = normalized.replacingOccurrences(of: "_", with: "")
        normalized = normalized.replacingOccurrences(of: "-", with: "")
        if normalized.hasPrefix("0x") {
            let hex = String(normalized.dropFirst(2))
            if let value = UInt32(hex, radix: 16) {
                return [value]
            }
            return []
        }

        var values = Set<UInt32>()
        if let decimal = UInt32(normalized, radix: 10) {
            values.insert(decimal)
        }
        if let hex = UInt32(normalized, radix: 16) {
            values.insert(hex)
        }
        return values
    }

    private func enumerateSerialDevicesViaIOKit() -> [SerialDeviceMetadata] {
        guard let matching = IOServiceMatching(kIOSerialBSDServiceValue) as NSMutableDictionary? else { return [] }
        matching[kIOSerialBSDTypeKey] = kIOSerialBSDAllTypes

        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard result == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var out: [SerialDeviceMetadata] = []
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }

            guard let calloutAny = ioRegistryProperty(entry: service, key: kIOCalloutDeviceKey),
                  let callout = calloutAny as? String,
                  !callout.isEmpty else {
                continue
            }

            let locationAny = ioRegistryPropertyInParents(entry: service, keys: ["locationID", "LocationID", "location-id"])
            let locationID = decodeLocationID(locationAny)
            let serialAny = ioRegistryPropertyInParents(entry: service, keys: [
                "USB Serial Number",
                "kUSBSerialNumberString",
                "serial-number",
                "SerialNumber"
            ])
            let serialNumber = decodeString(serialAny)
            out.append(SerialDeviceMetadata(path: callout, locationID: locationID, serialNumber: serialNumber))
        }
        return out
    }

    private func ioRegistryProperty(entry: io_registry_entry_t, key: String) -> AnyObject? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private func ioRegistryPropertyInParents(entry: io_registry_entry_t, keys: [String]) -> AnyObject? {
        var current = entry
        var ownsCurrent = false
        defer {
            if ownsCurrent {
                IOObjectRelease(current)
            }
        }

        while true {
            for key in keys {
                if let value = ioRegistryProperty(entry: current, key: key) {
                    return value
                }
            }
            var parent: io_registry_entry_t = 0
            let result = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
            if result != KERN_SUCCESS || parent == 0 {
                return nil
            }
            if ownsCurrent {
                IOObjectRelease(current)
            }
            current = parent
            ownsCurrent = true
        }
    }

    private func decodeLocationID(_ value: AnyObject?) -> UInt32? {
        guard let value else { return nil }
        if let num = value as? NSNumber {
            return num.uint32Value
        }
        if let data = value as? Data {
            guard data.count >= MemoryLayout<UInt32>.size else { return nil }
            return data.withUnsafeBytes { rawBuf in
                rawBuf.load(as: UInt32.self)
            }
        }
        if let string = value as? String {
            let normalized = string.replacingOccurrences(of: "0x", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            if let hex = UInt32(normalized, radix: 16) {
                return hex
            }
            return UInt32(normalized, radix: 10)
        }
        return nil
    }

    private func decodeString(_ value: AnyObject?) -> String? {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let data = value as? Data,
           let decoded = String(data: data, encoding: .utf8) {
            let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private func isDebugEnabled() -> Bool {
        guard let raw = ProcessInfo.processInfo.environment[Self.debugEnvVar]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() else {
            return false
        }
        return raw == "1" || raw == "true" || raw == "yes" || raw == "on"
    }

    private func logScanCandidatesIfNeeded(
        candidates: [String],
        locationHint: String?,
        serialHint: String?
    ) {
        guard isDebugEnabled() else { return }
        let signature = candidates.joined(separator: "|")
        guard signature != lastLoggedScanSignature else { return }
        lastLoggedScanSignature = signature
        let locationHintText = locationHint ?? "<none>"
        let serialHintText = serialHint ?? "<none>"
        let preferred = manualPreferredPath ?? "<none>"
        print("[HardwareInput] scan candidates=\(candidates) preferred=\(preferred) locationHint=\(locationHintText) serialHint=\(serialHintText)")
    }

    private static func devicePathRank(_ path: String) -> Int {
        if path.contains("/cu.usbmodem") { return 0 }
        if path.contains("/cu.usbserial") { return 1 }
        if path.contains("/cu.SLAB_USBtoUART") { return 2 }
        if path.contains("/cu.wchusbserial") { return 3 }
        if path.contains("/tty.usbmodem") { return 4 }
        if path.contains("/tty.usbserial") { return 5 }
        if path.contains("/tty.SLAB_USBtoUART") { return 6 }
        if path.contains("/tty.wchusbserial") { return 7 }
        return 8
    }

    private func isBackingOff(path: String, now: Date) -> Bool {
        discoveryLock.lock()
        defer { discoveryLock.unlock() }
        guard let until = failedProbeBackoffUntil[path] else { return false }
        return until > now
    }

    private func markProbeFailure(path: String) {
        discoveryLock.lock()
        failedProbeBackoffUntil[path] = Date().addingTimeInterval(Self.failedProbeRetrySeconds)
        discoveryLock.unlock()
    }

    private func clearProbeFailure(path: String) {
        discoveryLock.lock()
        failedProbeBackoffUntil[path] = nil
        discoveryLock.unlock()
    }

    // MARK: - Serial port

    private func openPort(_ path: String) -> Bool {
        let fileFd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fileFd >= 0 else { return false }

        // Configure terminal
        var options = termios()
        tcgetattr(fileFd, &options)

        // Raw mode
        cfmakeraw(&options)

        // 115200 baud
        cfsetispeed(&options, speed_t(B115200))
        cfsetospeed(&options, speed_t(B115200))

        // 8N1, no flow control
        options.c_cflag |= UInt(CS8 | CLOCAL | CREAD)
        options.c_cflag &= ~UInt(PARENB | CSTOPB)

        // Blocking read with timeout: VMIN=0, VTIME=5 (0.5s)
        // This lets us check `running` periodically.
        withUnsafeMutablePointer(to: &options.c_cc) { ccPtr in
            let cc = ccPtr.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { $0 }
            cc[Int(VMIN)] = 0
            cc[Int(VTIME)] = 5
        }

        // Clear O_NONBLOCK after configuration
        var flags = fcntl(fileFd, F_GETFL, 0)
        flags &= ~O_NONBLOCK
        _ = fcntl(fileFd, F_SETFL, flags)

        tcsetattr(fileFd, TCSANOW, &options)

        // Flush any stale data
        tcflush(fileFd, TCIOFLUSH)

        self.fd = fileFd
        activePortPath = path
        activePortOpenedAtNs = DispatchTime.now().uptimeNanoseconds
        didValidateProtocolOnActivePort = false

        DispatchQueue.main.async {
            self.devicePath = path
            self.isConnected = false
        }
        if isDebugEnabled() {
            print("[HardwareInput] opened serial path \(path)")
        }

        // Start read loop
        queue.async { [weak self] in
            self?.readLoop()
        }

        return true
    }

    private func closePort() {
        if isDebugEnabled(), let existing = activePortPath {
            print("[HardwareInput] closing serial path \(existing)")
        }
        if fd >= 0 {
            close(fd)
            fd = -1
        }
        activePortPath = nil
        activePortOpenedAtNs = 0
        didValidateProtocolOnActivePort = false
        currentMode = -1
        currentJolt = false
        DispatchQueue.main.async {
            self.isConnected = false
            self.devicePath = nil
            self.lastMode = nil
            self.lastJolt = false
        }
    }

    // MARK: - Write (commands to Teensy)

    func sendCommand(_ command: String) {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard fd >= 0 else { return }
        let data = command + "\n"
        data.withCString { ptr in
            _ = Darwin.write(fd, ptr, strlen(ptr))
        }
    }

    /// Set pedestal halo brightness (0-255)
    func setHalo(address: Int, pwm: Int) {
        sendCommand("H\(address),\(max(0, min(255, pwm)))")
    }

    /// Set pedestal NeoPixel color (RGBW, each 0-255)
    func setNeoPixel(address: Int, r: Int, g: Int, b: Int, w: Int) {
        sendCommand("N\(address),\(r).\(g).\(b).\(w)")
    }

    // MARK: - Read loop

    private func readLoop() {
        var lineBuf = Data(capacity: 64)

        while running && fd >= 0 {
            var byte: UInt8 = 0
            let n = read(fd, &byte, 1)

            if n < 0 {
                let err = errno
                if err == EAGAIN || err == EINTR { continue }
                // Device disconnected or error
                break
            }

            if n == 0 {
                // VTIME timeout, no data — loop back and check `running`
                if !didValidateProtocolOnActivePort {
                    let nowNs = DispatchTime.now().uptimeNanoseconds
                    if nowNs &- activePortOpenedAtNs > Self.probeTimeoutNs {
                        if let path = activePortPath {
                            markProbeFailure(path: path)
                        }
                        break
                    }
                }
                continue
            }

            if byte == 0x0A { // newline
                if let line = String(data: lineBuf, encoding: .ascii) {
                    _ = parseLine(line)
                }
                lineBuf.removeAll(keepingCapacity: true)
            } else if byte != 0x0D { // skip CR
                lineBuf.append(byte)
                // Safety: don't let garbage accumulate
                if lineBuf.count > 64 {
                    lineBuf.removeAll(keepingCapacity: true)
                }
            }
        }

        // If we exit the loop, the port is gone
        queue.async { [weak self] in
            self?.closePort()
        }
    }

    // MARK: - Protocol parsing

    @discardableResult
    private func parseLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("M"), parsePanelLine(trimmed) {
            noteProtocolValidated()
            return true
        }
        if trimmed.hasPrefix("P"), parsePedestalLine(trimmed) {
            noteProtocolValidated()
            return true
        }
        return false
    }

    private func noteProtocolValidated() {
        guard !didValidateProtocolOnActivePort else { return }
        didValidateProtocolOnActivePort = true
        if let path = activePortPath {
            clearProbeFailure(path: path)
            UserDefaults.standard.set(path, forKey: Self.lastGoodPathDefaultsKey)
        }
        DispatchQueue.main.async {
            self.isConnected = true
        }
    }

    /// Parse "M<mode>,J<0|1>"
    private func parsePanelLine(_ line: String) -> Bool {
        let body = line.dropFirst() // drop "M"
        let parts = body.split(separator: ",", maxSplits: 1)
        guard parts.count == 2 else { return false }

        guard let mode = Int(parts[0]), (0...10).contains(mode) else { return false }

        let joltPart = parts[1]
        guard joltPart.hasPrefix("J") else { return false }
        let joltVal = joltPart.dropFirst()
        guard joltVal == "0" || joltVal == "1" else { return false }
        let jolt = (joltVal == "1")

        // Edge detection and callbacks
        if mode != currentMode {
            currentMode = mode
            onModeChange?(mode)
            DispatchQueue.main.async { self.lastMode = mode }
        }

        if jolt != currentJolt {
            let wasOff = !currentJolt
            currentJolt = jolt
            onJoltHeldChange?(jolt)
            if jolt && wasOff {
                onJoltPressed?()
            }
            DispatchQueue.main.async { self.lastJolt = jolt }
        }
        return true
    }

    /// Parse "P<addr>,B<0|1>,T<tof_mm>,H<pwm>"
    private func parsePedestalLine(_ line: String) -> Bool {
        let body = line.dropFirst() // drop "P"
        let parts = body.split(separator: ",")
        guard parts.count >= 4 else { return false }

        guard let addr = Int(parts[0]), (1...3).contains(addr) else { return false }

        // Parse B<0|1>
        guard parts[1].hasPrefix("B"), let btn = Int(parts[1].dropFirst()) else { return false }
        // Parse T<mm>
        guard parts[2].hasPrefix("T"), let tof = Int(parts[2].dropFirst()) else { return false }
        // Parse H<pwm>
        guard parts[3].hasPrefix("H"), let halo = Int(parts[3].dropFirst()) else { return false }

        let telemetry = PedestalTelemetry(
            address: addr,
            button: btn != 0,
            tofMm: tof,
            haloPwm: halo,
            online: true,
            lastUpdate: Date()
        )

        onPedestalUpdate?(telemetry)
        DispatchQueue.main.async {
            self.pedestals[addr] = telemetry
        }
        return true
    }
}
