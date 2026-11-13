import Foundation
import IOKit
import IOKit.hid

struct LabSample: Sendable {
    let time: Double
    let fine: Double?
    let coarse: Double?
    let lux: Double?
    let fineRaw: String
    let coarseRaw: String
    let fineReadTime: Double
    let coarseReadTime: Double
    let readDuration: Double
    let inputAngle: Double?
    let inputTime: Double?
}
struct LabSnapshot: Sendable {
    var samples: [LabSample] = []
    var alsFrames: [ALSFrame] = []
    var motionFrames: [MotionFrame] = []
    var motionStatus = "Motion capture off"
    var accelHz = 0.0
    var gyroHz = 0.0
    var reports: [Int: String] = [:]
    var details = "Discovering sensors…"
    var elements = ""
    var alsHex = "Waiting for an ambient-light input report…"
    var alsChannels: [UInt32] = []
    var alsAge: Double?
    var pollHz = 0.0
    var changedHz = 0.0
    var callbackHz = 0.0
    var alsHz = 0.0
    var minimumStep: Double?
    var fineSpan = 0.0
    var inputAngle: Double?
    var inputTime: Double?
    var hidValues = "Waiting for HID element reads…"
}

/// Diagnostic reader. Motion sensors are opt-in for a synchronized experiment; no actions are triggered.
final class LabSensors: @unchecked Sendable {
    let publish: @Sendable (LabSnapshot) -> Void
    private let lock = NSCondition()
    private var stopping = false
    private var requestedHz = 100.0
    private var motionRequested = false
    private var motionActive = false
    private var motionChannels: [MotionChannel] = []
    private var motionIntervals: [(io_service_t, CFTypeRef)] = []
    private var accelCount = 0, gyroCount = 0
    private final class MotionChannel {
        let device: IOHIDDevice
        let kind: MotionFrame.Kind
        weak var reader: LabSensors?
        var sequence: UInt64 = 0
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
        init(device: IOHIDDevice, kind: MotionFrame.Kind, reader: LabSensors) { self.device = device; self.kind = kind; self.reader = reader }
        deinit { buffer.deallocate() }
    }
    private var thread: Thread?
    private var lid: IOHIDDevice?
    private var als: IOHIDDevice?
    private var lidElements: [IOHIDElement] = []
    private var lidBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 256)
    private var alsBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 256)
    // Worker-thread state.
    private var snapshot = LabSnapshot()
    private var latestLux: Double?
    private var alsTime = -Double.infinity
    private var lidCallbacks = 0, alsCallbacks = 0
    private var lastFine: Double?
    private var changes = 0, reads = 0
    private var minFine = Double.infinity, maxFine = -Double.infinity
    private var lastPublish = 0.0, lastStats = 0.0, lastMetadata = 0.0
    private var descriptorText = ""
    private let startTime = ProcessInfo.processInfo.systemUptime
    private static let machScale: Double = {
        var info = mach_timebase_info_data_t(); mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()
    private let machToHostOffset = ProcessInfo.processInfo.systemUptime - Double(mach_absolute_time()) * LabSensors.machScale
    private var alsSequence: UInt64 = 0

    init(publish: @escaping @Sendable (LabSnapshot) -> Void) { self.publish = publish }
    var elapsedTime: Double { ProcessInfo.processInfo.systemUptime - startTime }
    func setRate(_ rate: Double) { lock.withLock { requestedHz = min(500, max(10, rate)) } }
    func setMotionEnabled(_ enabled: Bool) { lock.withLock { motionRequested = enabled } }
    func start() {
        guard thread == nil else { return }
        let worker = Thread { [self] in run() }
        worker.name = "Sentient lid-angle laboratory"; worker.qualityOfService = .userInitiated
        thread = worker; worker.start()
    }
    func stop() {
        lock.lock(); stopping = true
        let deadline = Date().addingTimeInterval(1)
        while thread != nil { if !lock.wait(until: deadline) { break } }
        lock.unlock()
    }
    deinit { lidBuffer.deallocate(); alsBuffer.deallocate() }
    private func run() {
        discover()
        snapshot.details += "\nLid/ALS configuration is unchanged. Motion devices open only during a combined experiment; their reporting intervals are restored afterwards."
        var deadline = ProcessInfo.processInfo.systemUptime
        var previousRate = 0.0
        while !lock.withLock({ stopping }) {
            let wantsMotion = lock.withLock { motionRequested }
            if wantsMotion != motionActive {
                closeMotion()
                motionActive = wantsMotion
                if wantsMotion { openMotion() }
            }
            let began = ProcessInfo.processInfo.systemUptime
            let t = began - startTime
            let r7 = report(7)
            let fineTime = ProcessInfo.processInfo.systemUptime - startTime
            let r1 = report(1)
            let coarseTime = ProcessInfo.processInfo.systemUptime - startTime
            let fine = r7.flatMap { bytes -> Double? in
                guard bytes.count >= 5, bytes[0] == 7 else { return nil }
                let value = Double(LabSensors.u32(bytes, 1)) / 100
                return (0...360).contains(value) ? value : nil
            }
            let coarse = r1.flatMap { bytes -> Double? in
                guard bytes.count >= 3, bytes[0] == 1 else { return nil }
                return Double(UInt16(bytes[1]) | UInt16(bytes[2]) << 8)
            }
            if let fine {
                reads += 1
                minFine = min(minFine, fine); maxFine = max(maxFine, fine)
                if let last = lastFine, fine != last {
                    changes += 1
                    let step = abs(fine - last)
                    snapshot.minimumStep = min(snapshot.minimumStep ?? step, step)
                }
                lastFine = fine
            }
            snapshot.samples.append(.init(time: t, fine: fine, coarse: coarse, lux: latestLux,
                fineRaw: r7.map(LabSensors.hex) ?? "", coarseRaw: r1.map(LabSensors.hex) ?? "",
                fineReadTime: fineTime, coarseReadTime: coarseTime, readDuration: coarseTime - t,
                inputAngle: snapshot.inputAngle, inputTime: snapshot.inputTime))
            if t - lastMetadata >= 0.5 {
                lastMetadata = t
                for id in [2,4,5,8] { _ = report(id) }
                snapshot.hidValues = elementReadings()
            }
            if t - lastStats >= 1 {
                let dt = t - lastStats
                snapshot.pollHz = Double(reads)/dt; snapshot.changedHz = Double(changes)/dt
                snapshot.callbackHz = Double(lidCallbacks)/dt; snapshot.alsHz = Double(alsCallbacks)/dt
                snapshot.accelHz = Double(accelCount)/dt; snapshot.gyroHz = Double(gyroCount)/dt
                accelCount = 0; gyroCount = 0
                snapshot.fineSpan = maxFine.isFinite && minFine.isFinite ? maxFine - minFine : 0
                reads = 0; changes = 0; lidCallbacks = 0; alsCallbacks = 0
                lastStats = t
            }
            if t - lastPublish >= 0.05 {
                snapshot.alsAge = alsTime.isFinite ? max(0, began - alsTime) : nil
                publish(snapshot)
                snapshot.samples.removeAll(keepingCapacity: true)
                snapshot.alsFrames.removeAll(keepingCapacity: true)
                snapshot.motionFrames.removeAll(keepingCapacity: true)
                lastPublish = t
            }
            // Service asynchronous HID reports during the wait, on the same thread as polling.
            let rate = lock.withLock { requestedHz }
            if rate != previousRate { deadline = began; previousRate = rate }
            deadline += 1 / rate
            let now = ProcessInfo.processInfo.systemUptime
            if deadline < now { deadline = now } // No artificial catch-up samples after an overrun.
            if deadline > now { CFRunLoopRunInMode(.defaultMode, deadline - now, false) }
            else { CFRunLoopRunInMode(.defaultMode, 0.00001, true) }
        }
        closeMotion()
        for device in [lid, als].compactMap({ $0 }) {
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceClose(device, 0)
        }
        lid = nil; als = nil
        lock.withLock { thread = nil; lock.broadcast() }
    }
    private func openMotion() {
        var iterator: io_iterator_t = 0
        IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSPUHIDDevice"), &iterator)
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            let page = Self.property(service, "PrimaryUsagePage") as? Int
            let usage = Self.property(service, "PrimaryUsage") as? Int
            guard page == 0xFF00, usage == 3 || usage == 9,
                  Self.property(service, "MaxInputReportSize") as? Int == 22 else { continue }
            let kind: MotionFrame.Kind = usage == 3 ? .accel : .gyro
            guard !motionChannels.contains(where: { $0.kind == kind }),
                  let device = IOHIDDeviceCreate(kCFAllocatorDefault, service), IOHIDDeviceOpen(device, 0) == kIOReturnSuccess else { continue }
            let channel = MotionChannel(device: device, kind: kind, reader: self)
            motionChannels.append(channel)
            IOHIDDeviceRegisterInputReportWithTimeStampCallback(device, channel.buffer, 64, { ctx, result, _, _, _, bytes, count, stamp in
                guard result == 0, let ctx, count == 22 else { return }
                let channel = Unmanaged<MotionChannel>.fromOpaque(ctx).takeUnretainedValue()
                guard let reader = channel.reader else { return }
                let arrival = ProcessInfo.processInfo.systemUptime - reader.startTime
                let deviceTime = Double(stamp) * LabSensors.machScale + reader.machToHostOffset - reader.startTime
                let validTimestamp = stamp > 0 && abs(deviceTime-arrival) < 1
                channel.sequence &+= 1
                guard let frame = MotionFrame.decode(Array(UnsafeBufferPointer(start: bytes, count: count)),
                    kind: channel.kind, sequence: channel.sequence, time: validTimestamp ? deviceTime : arrival,
                    arrival: arrival, ticks: stamp, timestampSource: validTimestamp ? "device" : "arrival_fallback") else { return }
                reader.snapshot.motionFrames.append(frame)
                if frame.kind == .gyro { reader.gyroCount += 1 } else { reader.accelCount += 1 }
            }, Unmanaged.passUnretained(channel).toOpaque())
            IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        }
        IOObjectRelease(iterator)
        guard motionChannels.count == 2 else {
            closeMotion(); snapshot.motionStatus = "Motion sensors could not be opened; this run cannot validate fusion."; return
        }
        var drivers: io_iterator_t = 0
        IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSPUHIDDriver"), &drivers)
        while case let driver = IOIteratorNext(drivers), driver != 0 {
            let page = Self.property(driver, "PrimaryUsagePage") as? Int
            let usage = Self.property(driver, "PrimaryUsage") as? Int
            guard page == 0xFF00, usage == 3 || usage == 9,
                  let old = IORegistryEntryCreateCFProperty(driver, "ReportInterval" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
                  IORegistryEntrySetCFProperty(driver, "ReportInterval" as CFString, NSNumber(value: 1250)) == kIOReturnSuccess else { IOObjectRelease(driver); continue }
            motionIntervals.append((driver, old))
        }
        IOObjectRelease(drivers)
        snapshot.motionStatus = "Native acceleration + gyroscope capture requested; check actual rates below."
    }
    private func closeMotion() {
        for channel in motionChannels {
            IOHIDDeviceUnscheduleFromRunLoop(channel.device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceRegisterInputReportWithTimeStampCallback(channel.device, channel.buffer, 64, nil, nil)
            IOHIDDeviceClose(channel.device, 0)
        }
        motionChannels.removeAll()
        for (driver, old) in motionIntervals {
            if Self.property(driver, "ReportInterval") as? Int == 1250 { IORegistryEntrySetCFProperty(driver, "ReportInterval" as CFString, old) }
            IOObjectRelease(driver)
        }
        motionIntervals.removeAll()
        snapshot.motionStatus = "Motion capture off"
        snapshot.accelHz = 0; snapshot.gyroHz = 0; accelCount = 0; gyroCount = 0
    }
    private func discover() {
        var iterator: io_iterator_t = 0
        IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSPUHIDDevice"), &iterator)
        defer { IOObjectRelease(iterator) }
        var notes: [String] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            let page = Self.property(service, "PrimaryUsagePage") as? Int ?? -1
            let usage = Self.property(service, "PrimaryUsage") as? Int ?? -1
            let size = Self.property(service, "MaxInputReportSize") as? Int ?? -1
            let isLid = page == 0x20 && usage == 0x8A
            let isALS = page == 0xFF00 && usage == 4 && size == 122
            guard (isLid && lid == nil) || (isALS && als == nil), let device = IOHIDDeviceCreate(kCFAllocatorDefault, service) else { continue }
            let result = IOHIDDeviceOpen(device, 0)
            notes.append("\(isLid ? "Lid" : "Ambient light"): page 0x\(String(page, radix:16)), usage 0x\(String(usage, radix:16)), open \(Self.status(result))")
            guard result == kIOReturnSuccess else { continue }
            if isLid {
                lid = device
                lidElements = (IOHIDDeviceCopyMatchingElements(device, nil, 0) as? [IOHIDElement] ?? [])
                    .filter { [1,7].contains(Int(IOHIDElementGetReportID($0))) && IOHIDElementGetType($0) == kIOHIDElementTypeInput_Misc }
                let elements = (IOHIDDeviceCopyMatchingElements(device, nil, 0) as? [IOHIDElement] ?? []).filter { IOHIDElementGetUsagePage($0) == 0x20 }
                snapshot.elements = elements.map { e in
                    let exponent = Int(IOHIDElementGetUnitExponent(e))
                    return "Report \(IOHIDElementGetReportID(e)) · usage 0x\(String(IOHIDElementGetUsage(e),radix:16)) · \(IOHIDElementGetReportSize(e)) bits · logical \(IOHIDElementGetLogicalMin(e))…\(IOHIDElementGetLogicalMax(e)) · decimal exponent \(exponent > 7 ? exponent-16 : exponent)"
                }.joined(separator:"\n")
                if let data = IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data {
                    descriptorText = LabSensors.hex(Array(data))
                    snapshot.elements += "\n\nRaw HID descriptor\n" + descriptorText
                }
                IOHIDDeviceRegisterInputReportCallback(device, lidBuffer, 256, { ctx, result, _, _, _, bytes, count in
                    guard result == 0, let ctx, count >= 3 else { return }
                    let reader = Unmanaged<LabSensors>.fromOpaque(ctx).takeUnretainedValue()
                    reader.lidCallbacks += 1
                    reader.snapshot.inputTime = ProcessInfo.processInfo.systemUptime - reader.startTime
                    if bytes[0] == 7, count >= 5 {
                        reader.snapshot.inputAngle = Double(UInt32(bytes[1]) | UInt32(bytes[2]) << 8 | UInt32(bytes[3]) << 16 | UInt32(bytes[4]) << 24) / 100
                    } else if bytes[0] == 1 { reader.snapshot.inputAngle = Double(UInt16(bytes[1]) | UInt16(bytes[2]) << 8) }
                }, Unmanaged.passUnretained(self).toOpaque())
            } else {
                als = device
                IOHIDDeviceRegisterInputReportWithTimeStampCallback(device, alsBuffer, 256, { ctx, result, _, _, _, bytes, count, stamp in
                    guard result == 0, let ctx, count == 122 else { return }
                    let reader = Unmanaged<LabSensors>.fromOpaque(ctx).takeUnretainedValue()
                    let arrival = ProcessInfo.processInfo.systemUptime - reader.startTime
                    let sensorTime = Double(stamp) * LabSensors.machScale + reader.machToHostOffset - reader.startTime
                    let validTimestamp = stamp > 0 && abs(sensorTime - arrival) < 10
                    reader.alsSequence &+= 1
                    guard let frame = ALSFrame.decode(Array(UnsafeBufferPointer(start: bytes, count: count)),
                        sequence: reader.alsSequence, time: validTimestamp ? sensorTime : arrival,
                        arrival: arrival, ticks: stamp, timestampSource: validTimestamp ? "device" : "arrival_fallback") else { return }
                    reader.latestLux = frame.lux
                    reader.snapshot.alsChannels = frame.channels
                    reader.snapshot.alsHex = frame.rawHex
                    reader.snapshot.alsFrames.append(frame)
                    reader.alsTime = ProcessInfo.processInfo.systemUptime
                    reader.alsCallbacks += 1
                }, Unmanaged.passUnretained(self).toOpaque())
            }
            IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        }
        snapshot.details = notes.joined(separator:"\n")
        if lid == nil { snapshot.details += "\nNo accessible lid sensor found." }
        if als == nil { snapshot.details += "\nNo accessible SPU ambient-light sensor found." }
    }
    private func report(_ id: Int) -> [UInt8]? {
        guard let lid else { return nil }
        var bytes = [UInt8](repeating: 0, count: 64), count = 64
        let result = IOHIDDeviceGetReport(lid, kIOHIDReportTypeFeature, id, &bytes, &count)
        guard result == 0, count > 0, count <= bytes.count else {
            snapshot.reports[id] = Self.status(result); return nil
        }
        let packet = Array(bytes.prefix(count)); snapshot.reports[id] = LabSensors.hex(packet)
        return packet
    }
    private func elementReadings() -> String {
        guard let lid else { return "Unavailable" }
        return lidElements.map { element in
            let output = UnsafeMutablePointer<Unmanaged<IOHIDValue>>.allocate(capacity: 1)
            defer { output.deallocate() }
            let result = IOHIDDeviceGetValue(lid, element, output)
            guard result == 0 else { return "Element report \(IOHIDElementGetReportID(element)): \(Self.status(result))" }
            let value = output.pointee.takeUnretainedValue()
            return String(format:"Element report %d: integer %lld · physical %.8f · calibrated %.8f · timestamp %llu",
                IOHIDElementGetReportID(element), Int64(IOHIDValueGetIntegerValue(value)),
                IOHIDValueGetScaledValue(value, UInt32(kIOHIDValueScaleTypePhysical)),
                IOHIDValueGetScaledValue(value, UInt32(kIOHIDValueScaleTypeCalibrated)), IOHIDValueGetTimeStamp(value))
        }.joined(separator:"\n")
    }
    static func property(_ service: io_service_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
    static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset+1]) << 8 | UInt32(bytes[offset+2]) << 16 | UInt32(bytes[offset+3]) << 24
    }
    static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format:"%02X", $0) }.joined(separator:" ") }
    static func status(_ code: IOReturn) -> String {
        if code == 0 { return "success" }
        if code == kIOReturnUnsupported { return "unsupported (0xE00002C7)" }
        if code == kIOReturnNotPrivileged { return "permission denied" }
        return "0x" + String(UInt32(bitPattern: code), radix: 16)
    }
}
