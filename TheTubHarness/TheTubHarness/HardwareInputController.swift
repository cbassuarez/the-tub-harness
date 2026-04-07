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
    private var fd: Int32 = -1
    private var running = false
    private var scanTimer: DispatchSourceTimer?

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

    private static let deviceGlob = "/dev/cu.usbmodem*"

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

        var gt = glob_t()
        defer { globfree(&gt) }
        let result = glob(Self.deviceGlob, 0, nil, &gt)
        guard result == 0 else { return }

        for i in 0..<Int(gt.gl_matchc) {
            guard let cStr = gt.gl_pathv[i] else { continue }
            let path = String(cString: cStr)
            if openPort(path) {
                return
            }
        }
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

        DispatchQueue.main.async {
            self.devicePath = path
            self.isConnected = true
        }

        // Start read loop
        queue.async { [weak self] in
            self?.readLoop()
        }

        return true
    }

    private func closePort() {
        if fd >= 0 {
            close(fd)
            fd = -1
        }
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
                continue
            }

            if byte == 0x0A { // newline
                if let line = String(data: lineBuf, encoding: .ascii) {
                    parseLine(line)
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

    private func parseLine(_ line: String) {
        if line.hasPrefix("M") {
            parsePanelLine(line)
        } else if line.hasPrefix("P") {
            parsePedestalLine(line)
        }
    }

    /// Parse "M<mode>,J<0|1>"
    private func parsePanelLine(_ line: String) {
        let body = line.dropFirst() // drop "M"
        let parts = body.split(separator: ",", maxSplits: 1)
        guard parts.count == 2 else { return }

        guard let mode = Int(parts[0]), (0...10).contains(mode) else { return }

        let joltPart = parts[1]
        guard joltPart.hasPrefix("J") else { return }
        let joltVal = joltPart.dropFirst()
        guard joltVal == "0" || joltVal == "1" else { return }
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
    }

    /// Parse "P<addr>,B<0|1>,T<tof_mm>,H<pwm>"
    private func parsePedestalLine(_ line: String) {
        let body = line.dropFirst() // drop "P"
        let parts = body.split(separator: ",")
        guard parts.count >= 4 else { return }

        guard let addr = Int(parts[0]), (1...3).contains(addr) else { return }

        // Parse B<0|1>
        guard parts[1].hasPrefix("B"), let btn = Int(parts[1].dropFirst()) else { return }
        // Parse T<mm>
        guard parts[2].hasPrefix("T"), let tof = Int(parts[2].dropFirst()) else { return }
        // Parse H<pwm>
        guard parts[3].hasPrefix("H"), let halo = Int(parts[3].dropFirst()) else { return }

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
    }
}
