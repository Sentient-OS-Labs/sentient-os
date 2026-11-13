// Native ambient light with motion corroboration. Motion report intervals are restored on shutdown.
import Foundation
import IOKit
import IOKit.hid

nonisolated enum PhysicalTapClock {
    static let scale: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()
    static var now: Double { Double(mach_absolute_time()) * scale }
}

nonisolated final class PhysicalTapSensor: @unchecked Sendable {
    enum Status: Sendable { case starting, ready, settling, unavailable, stalled, stopped }
    let onTap: @Sendable (Double, UInt64) -> Void
    let onStatus: @Sendable (Status, UInt64) -> Void
    private let onSample: (@Sendable (PhysicalTapSample) -> Void)?
    private let lock = NSCondition()
    private var wanted = false
    private var running = false
    private var generation: UInt64 = 0
    private var sensitivity = 1.1
    private var eligible = false
    private var eligibleSince = Double.infinity
    private var eligibilityCheckedAt = -Double.infinity
    // All following state belongs to the worker thread.
    private var detector = PhysicalTapDetector()
    private var streams: [Stream] = []
    private var driverIntervals: [(io_service_t, CFTypeRef)] = []
    private var lastAccel = 0.0
    private var lastGyro = 0.0
    private var receivedAccel = false
    private var receivedGyro = false

    private final class Stream {
        let device: IOHIDDevice
        let usage: Int
        weak var owner: PhysicalTapSensor?
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 128)

        init(device: IOHIDDevice, usage: Int, owner: PhysicalTapSensor) {
            self.device = device
            self.usage = usage
            self.owner = owner
        }
        deinit { buffer.deallocate() }
    }
    private var lidDevice: IOHIDDevice?
    private var lidGuard = PhysicalTapLidGuard()
    private var streamGeneration: UInt64 = 0
    private var streamStarted = 0.0
    private var lastLight = 0.0
    private var receivedLight = false

    init(onTap: @escaping @Sendable (Double, UInt64) -> Void,
         onStatus: @escaping @Sendable (Status, UInt64) -> Void,
         onSample: (@Sendable (PhysicalTapSample) -> Void)? = nil) {
        self.onTap = onTap
        self.onStatus = onStatus
        self.onSample = onSample
    }

    func configure(enabled: Bool, sensitivity: Double, generation: UInt64) {
        let launch = lock.withLock {
            wanted = enabled
            eligible = false
            self.sensitivity = sensitivity
            self.generation = generation
            guard enabled, !running else { return false }
            running = true
            return true
        }
        if launch {
            let thread = Thread { [self] in run() }
            thread.name = "Sentient ambient-light tap sensor"
            thread.qualityOfService = .utility
            thread.start()
        }
    }
    private var configuration: (enabled: Bool, sensitivity: Double, generation: UInt64) {
        lock.withLock { (wanted, sensitivity, generation) }
    }

    func acceptsDelivery(at time: Double, generation: UInt64) -> Bool {
        lock.withLock {
            wanted && self.generation == generation && eligible && time >= eligibleSince
                && PhysicalTapClock.now - eligibilityCheckedAt <= 0.5
        }
    }

    private func updateEligibility(at time: Double) {
        let allowed = lidGuard.allowsTap(at: time) && receivedAccel && receivedGyro && receivedLight
            && time - lastAccel < 0.1 && time - lastGyro < 0.1 && time - lastLight < 0.65
        if !allowed { detector.reset(at: time) }
        lock.withLock {
            if allowed && !eligible { eligibleSince = time }
            eligible = allowed
            eligibilityCheckedAt = time
        }
    }

    func drainForTermination() {
        lock.lock()
        wanted = false
        let deadline = Date().addingTimeInterval(1)
        while running {
            if !lock.wait(until: deadline) { break }
        }
        lock.unlock()
    }

    private func run() {
        var lastAttempt = -Double.infinity
        var publishedStatus: Status?
        var lastLidPoll = -Double.infinity
        var lastValidLidRead = 0.0
        while configuration.enabled {
            let config = configuration
            let now = PhysicalTapClock.now
            if streamGeneration != config.generation {
                streamGeneration = config.generation
                streamStarted = now
                lastAttempt = -.infinity
                detector.sensitivity = config.sensitivity
                detector.reset(at: now)
                receivedLight = false
                receivedAccel = false
                receivedGyro = false
                lastAccel = now
                lastGyro = now
                lastLight = now
                publishedStatus = nil
                lastLidPoll = -.infinity
                lastValidLidRead = now
                lidGuard.reset(at: now)
            }
            if streams.isEmpty, now - lastAttempt >= 8 {
                lastAttempt = now
                onStatus(.starting, streamGeneration)
                if !open() { close(); onStatus(.unavailable, streamGeneration) }
                streamStarted = now
                lastLight = now
                receivedLight = false
                receivedAccel = false
                receivedGyro = false
                lastAccel = now
                lastGyro = now
                detector.reset(at: now)
                publishedStatus = nil
                lastLidPoll = -.infinity
                lastValidLidRead = now
                lidGuard.reset(at: now)
            }
            guard !streams.isEmpty else {
                Thread.sleep(forTimeInterval: 0.1)
                continue
            }
            let readingTime = PhysicalTapClock.now
            if readingTime - lastLidPoll >= 0.1 {
                lastLidPoll = readingTime
                let angle = readLidAngle()
                if angle != nil { lastValidLidRead = readingTime }
                onSample?(PhysicalTapSample(kind: .lid, time: readingTime, value: SIMD3(angle ?? .nan, 0, 0)))
                lidGuard.update(angle: angle, at: readingTime)
                updateEligibility(at: readingTime)
            }
            CFRunLoopRunInMode(.defaultMode, 0.05, false)
            let afterReports = PhysicalTapClock.now
            updateEligibility(at: afterReports)
            if afterReports - lastLight > 2 || afterReports - lastAccel > 2
                || afterReports - lastGyro > 2 || afterReports - lastValidLidRead > 2 {
                close()
                publishedStatus = nil
                onStatus(.stalled, streamGeneration)
            } else if receivedLight && receivedAccel && receivedGyro {
                let status: Status = lidGuard.allowsTap(at: PhysicalTapClock.now) ? .ready : .settling
                if status != publishedStatus {
                    publishedStatus = status
                    onStatus(status, streamGeneration)
                }
            }
        }
        close()
        let restart = lock.withLock { () -> (Bool, Double, UInt64) in
            running = false
            lock.broadcast()
            return (wanted, sensitivity, generation)
        }
        if restart.0 { configure(enabled: true, sensitivity: restart.1, generation: restart.2) }
        else { onStatus(.stopped, restart.2) }
    }

    private func open() -> Bool {
        for service in Self.services("AppleSPUHIDDevice") {
            defer { IOObjectRelease(service) }
            let page = Self.number(service, "PrimaryUsagePage"), usage = Self.number(service, "PrimaryUsage")
            let isMotion = page == 0xFF00 && (usage == 3 || usage == 9)
                && Self.number(service, "MaxInputReportSize") == 22
            let isLight = page == 0xFF00 && usage == 4 && Self.number(service, "MaxInputReportSize") == 122
            let isLid = page == 0x20 && usage == 0x8A
            guard isMotion || isLight || isLid,
                  !streams.contains(where: { $0.usage == usage }), !(isLid && lidDevice != nil),
                  let device = IOHIDDeviceCreate(kCFAllocatorDefault, service), IOHIDDeviceOpen(device, 0) == kIOReturnSuccess else { continue }
            if isLid { lidDevice = device; continue }
            let stream = Stream(device: device, usage: usage, owner: self)
            IOHIDDeviceRegisterInputReportWithTimeStampCallback(device, stream.buffer, 128, { context, result, _, _, _, report, length, stamp in
                guard result == kIOReturnSuccess, let context else { return }
                let stream = Unmanaged<Stream>.fromOpaque(context).takeUnretainedValue()
                let bytes = UnsafeBufferPointer(start: report, count: length)
                let time = Double(stamp) * PhysicalTapClock.scale
                if stream.usage == 4 {
                    if let lux = PhysicalTapReport.lux(bytes) { stream.owner?.receiveLight(lux, at: time) }
                } else if let vector = PhysicalTapReport.vector(bytes) {
                    stream.owner?.receiveMotion(usage: stream.usage, value: vector, at: time)
                }
            }, Unmanaged.passUnretained(stream).toOpaque())
            streams.append(stream)
            IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        }
        guard streams.count == 3, lidDevice != nil else { return false }
        for driver in Self.services("AppleSPUHIDDriver") {
            let page = Self.number(driver, "PrimaryUsagePage"), usage = Self.number(driver, "PrimaryUsage")
            guard page == 0xFF00, usage == 3 || usage == 9,
                  let original = IORegistryEntryCreateCFProperty(driver, "ReportInterval" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
                  IORegistryEntrySetCFProperty(driver, "ReportInterval" as CFString, NSNumber(value: 1250)) == kIOReturnSuccess else {
                IOObjectRelease(driver); continue
            }
            driverIntervals.append((driver, original))
        }
        return driverIntervals.count == 2
    }

    private func readLidAngle() -> Double? {
        guard let lidDevice else { return nil }
        var bytes = [UInt8](repeating: 0, count: 8)
        var count = bytes.count
        if IOHIDDeviceGetReport(lidDevice, kIOHIDReportTypeFeature, 7, &bytes, &count) == kIOReturnSuccess,
           count >= 5, bytes[0] == 7 {
            let raw = UInt32(bytes[1]) | UInt32(bytes[2]) << 8 | UInt32(bytes[3]) << 16 | UInt32(bytes[4]) << 24
            return Double(raw) / 100
        }
        count = bytes.count
        guard IOHIDDeviceGetReport(lidDevice, kIOHIDReportTypeFeature, 1, &bytes, &count) == kIOReturnSuccess,
              count >= 3, bytes[0] == 1 else { return nil }
        return Double(UInt16(bytes[1]) | UInt16(bytes[2]) << 8)
    }

    private func close() {
        lock.withLock { eligible = false }
        for stream in streams {
            IOHIDDeviceUnscheduleFromRunLoop(stream.device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceRegisterInputReportWithTimeStampCallback(stream.device, stream.buffer, 128, nil, nil)
            IOHIDDeviceClose(stream.device, 0)
        }
        streams.removeAll()
        if let lidDevice { IOHIDDeviceClose(lidDevice, 0) }
        lidDevice = nil
        for (driver, original) in driverIntervals {
            // Preserve a newer interval requested by another sensor client.
            if Self.number(driver, "ReportInterval") == 1250 {
                IORegistryEntrySetCFProperty(driver, "ReportInterval" as CFString, original)
            }
            IOObjectRelease(driver)
        }
        driverIntervals.removeAll()
        receivedAccel = false
        receivedGyro = false
        receivedLight = false
    }

    private func receiveMotion(usage: Int, value: SIMD3<Double>, at time: Double) {
        let now = PhysicalTapClock.now
        let config = configuration
        guard config.enabled, config.generation == streamGeneration,
              time >= streamStarted, abs(now - time) < 0.2 else { return }
        if usage == 3 {
            lastAccel = now
            receivedAccel = true
            onSample?(PhysicalTapSample(kind: .acceleration, time: time, value: value))
            detector.accel(value, at: time)
        } else if usage == 9 {
            lastGyro = now
            receivedGyro = true
            onSample?(PhysicalTapSample(kind: .rotation, time: time, value: value))
            detector.gyro(value, at: time)
        }
    }

    private func receiveLight(_ lux: Double, at time: Double) {
        let now = PhysicalTapClock.now
        let config = configuration
        guard config.enabled, config.generation == streamGeneration,
              time >= streamStarted, abs(now - time) < 0.2 else { return }
        receivedLight = true
        lastLight = now
        onSample?(PhysicalTapSample(kind: .light, time: time, value: SIMD3(lux, 0, 0)))
        guard lidGuard.allowsTap(at: time) else {
            detector.reset(at: time)
            return
        }
        if detector.light(lux, at: time) { onTap(time, streamGeneration) }
    }

    private static func number(_ service: io_service_t, _ key: String) -> Int {
        (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue ?? -1
    }
    private static func services(_ name: String) -> [io_service_t] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(name), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [io_service_t] = []
        while case let service = IOIteratorNext(iterator), service != 0 { result.append(service) }
        return result
    }
}
