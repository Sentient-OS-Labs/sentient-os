import SwiftUI
import AppKit

@MainActor final class LabModel: ObservableObject {
    @Published var snapshot = LabSnapshot()
    @Published var history: [LabSample] = []
    @Published var paused = false
    @Published var rate = 100.0 { didSet { reader.setRate(rate) } }
    @Published var baseline: Double?
    @Published var zoom = 0.5
    @Published var tab = 0
    @Published var recordingPath: String?
    @Published var message = ""
    private var recording: FileHandle?
    @Published var experimentMode = ExperimentPlan.Mode.missedTaps
    @Published var positionLabel = "Table"
    @Published var manualAction = ExperimentPlan.ManualAction.missedTaps
    private var runManualAction = ExperimentPlan.ManualAction.missedTaps
    @Published var completedMissedRuns = 0
    @Published var experimentStopping = false
    private var runPositionLabel = ""
    private var experimentEnd = Double.infinity
    @Published var onLap = false
    @Published var lightingLabel = ""
    @Published var completedTapRuns = 0
    private var runOnLap = false
    private var runLightingLabel = ""
    var experimentPlan: ExperimentPlan { ExperimentPlan(mode: experimentMode) }
    @Published var skippedTrials = Set<Int>()
    private var experimentALSFile: FileHandle?
    private var experimentMotionFile: FileHandle?
    private var motionCounts: [String: Int] = [:]
    private var motionFirst: [String: Double] = [:]
    private var motionLast: [String: Double] = [:]
    private var experimentALSFrames = 0
    private var experimentALSFirst: Double?
    private var experimentALSLast: Double?
    private var experimentRequestedHz = 100.0
    @Published var experimentActive = false
    @Published var experimentElapsed = 0.0
    @Published var experimentResult = ""
    private var experimentTask: Task<Void, Never>?
    private var experimentFile: FileHandle?
    private var experimentURL: URL?
    private var experimentStart = 0.0
    private var experimentPreviousRate = 100.0
    private var experimentSamples = 0
    private var experimentFineSamples = 0
    private var experimentFirstTime: Double?
    private var experimentLastTime: Double?
    private var latestDeliveredTime = 0.0
    private var cueEvents: [[String: Any]] = []
    var experimentPhase: ExperimentPlan.Phase { experimentPlan.phase(at: experimentElapsed) }
    lazy var reader = LabSensors { [weak self] value in Task { @MainActor in self?.receive(value) } }
    var fine: Double? { history.last?.fine }
    var coarse: Double? { history.last?.coarse }
    var lux: Double? { history.last?.lux }
    func start() { reader.start() }
    func stop() {
        if experimentActive { finishExperiment(completed: false) }
        reader.stop(); try? recording?.close()
    }
    func receive(_ value: LabSnapshot) {
        latestDeliveredTime = value.samples.last?.time ?? latestDeliveredTime
        if let handle = experimentMotionFile {
            let frames = value.motionFrames.filter { $0.time >= experimentStart && $0.time <= experimentEnd }
            if !frames.isEmpty {
                let rows = frames.map { frame in
                    [String(format: "%.9f", frame.time - experimentStart), String(format: "%.9f", frame.arrivalTime - experimentStart),
                     String(frame.deviceTicks), frame.timestampSource, frame.kind.rawValue, String(frame.sequence),
                     String(format: "%.9f", frame.vector.x), String(format: "%.9f", frame.vector.y), String(format: "%.9f", frame.vector.z), frame.rawHex].joined(separator: ",")
                }.joined(separator: "\n") + "\n"
                do { try handle.write(contentsOf: Data(rows.utf8)) }
                catch { finishExperiment(completed: false, error: error.localizedDescription); return }
                for frame in frames {
                    let key = frame.kind.rawValue
                    motionCounts[key, default: 0] += 1
                    if motionFirst[key] == nil { motionFirst[key] = frame.time }
                    motionLast[key] = frame.time
                }
            }
        }
        if let handle = experimentALSFile {
            let frames = value.alsFrames.filter { $0.time >= experimentStart && $0.time <= experimentEnd }
            if !frames.isEmpty {
                let rows = frames.map { frame in
                    ([String(format: "%.9f", frame.time - experimentStart), String(format: "%.9f", frame.arrivalTime - experimentStart),
                      String(frame.deviceTicks), frame.timestampSource, String(frame.sequence),
                      frame.lux.map { String(format: "%.9f", $0) } ?? ""] + frame.channels.map(String.init) + [frame.rawHex]).joined(separator: ",")
                }.joined(separator: "\n") + "\n"
                do { try handle.write(contentsOf: Data(rows.utf8)) }
                catch { finishExperiment(completed: false, error: error.localizedDescription); return }
                experimentALSFrames += frames.count
                if experimentALSFirst == nil { experimentALSFirst = frames.first?.time }
                experimentALSLast = frames.last?.time
            }
        }
        if let handle = experimentFile {
            let samples = value.samples.filter { $0.time >= experimentStart && $0.time <= experimentEnd }
            if !samples.isEmpty {
                func optional(_ value: Double?) -> String { value.map { String(format: "%.9f", $0) } ?? "" }
                let rows = samples.map { sample in
                    [String(format: "%.9f", sample.time - experimentStart), String(format: "%.9f", sample.time),
                     optional(sample.fine), optional(sample.coarse), sample.fineRaw, sample.coarseRaw,
                     String(format: "%.9f", sample.fineReadTime - experimentStart), String(format: "%.9f", sample.coarseReadTime - experimentStart),
                     String(format: "%.3f", sample.readDuration * 1_000_000), optional(sample.inputAngle),
                     optional(sample.inputTime.map { $0 - experimentStart }), optional(sample.lux)].joined(separator: ",")
                }.joined(separator: "\n") + "\n"
                do { try handle.write(contentsOf: Data(rows.utf8)) }
                catch { finishExperiment(completed: false, error: error.localizedDescription); return }
                experimentSamples += samples.count
                experimentFineSamples += samples.filter { $0.fine != nil }.count
                if experimentFirstTime == nil { experimentFirstTime = samples.first?.time }
                experimentLastTime = samples.last?.time
            }
        }
        if let recording {
            let rows = value.samples.map { "\($0.time),\($0.fine.map(String.init(describing:)) ?? ""),\($0.coarse.map(String.init(describing:)) ?? ""),\($0.lux.map(String.init(describing:)) ?? "")" }.joined(separator:"\n") + "\n"
            try? recording.write(contentsOf: Data(rows.utf8))
        }
        guard !paused else { return }
        snapshot = value
        history.append(contentsOf: value.samples)
        if let latest = history.last?.time { history.removeAll { $0.time < latest - 20 } }
        if baseline == nil { baseline = fine }
    }
    func startExperiment() {
        guard !experimentActive else { return }
        if recording != nil { record() }
        do {
            let directory = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Captures")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            runOnLap = onLap; runLightingLabel = lightingLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            runManualAction = manualAction
            runPositionLabel = positionLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = experimentPlan.isManual ? (manualAction == .missedTaps ? "missed-taps" : "motion-control") : experimentMode == .tapping ? "tapping" : experimentMode == .fusion ? "fusion" : experimentMode == .ambient ? "ambient" : "experiment"
            let url = directory.appendingPathComponent("\(prefix)-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6)).csv")
            let header = "seconds,reader_seconds,report7_degrees,report1_degrees,report7_hex,report1_hex,report7_read_seconds,report1_read_seconds,read_duration_us,lid_input_degrees,lid_input_seconds,als_lux\n"
            try Data(header.utf8).write(to: url)
            experimentFile = try FileHandle(forWritingTo: url); try experimentFile?.seekToEnd()
            let alsURL = url.deletingPathExtension().appendingPathExtension("als.csv")
            try Data("seconds,arrival_seconds,device_ticks,timestamp_source,sequence,lux,channel0,channel1,channel2,channel3,raw_hex\n".utf8).write(to: alsURL)
            experimentALSFile = try FileHandle(forWritingTo: alsURL); try experimentALSFile?.seekToEnd()
            motionCounts = [:]; motionFirst = [:]; motionLast = [:]
            if experimentPlan.recordsMotion {
                let motionURL = url.deletingPathExtension().appendingPathExtension("motion.csv")
                try Data("seconds,arrival_seconds,device_ticks,timestamp_source,kind,sequence,x,y,z,raw_hex\n".utf8).write(to: motionURL)
                experimentMotionFile = try FileHandle(forWritingTo: motionURL); try experimentMotionFile?.seekToEnd()
            }
            reader.setMotionEnabled(experimentPlan.recordsMotion)
            experimentALSFrames = 0; experimentALSFirst = nil; experimentALSLast = nil
            skippedTrials = []
            experimentURL = url; experimentPreviousRate = rate
            experimentSamples = 0; experimentFineSamples = 0
            experimentFirstTime = nil; experimentLastTime = nil; cueEvents = []
            experimentRequestedHz = experimentMode == .lid ? 500 : 100
            experimentResult = ""; paused = false; rate = experimentRequestedHz
            experimentStart = reader.elapsedTime; experimentEnd = experimentStart + experimentPlan.duration
            experimentElapsed = 0; experimentStopping = false; experimentActive = true
            message = experimentPlan.recordsMotion ? "Recording synchronized light, gyroscope and acceleration. No actions are enabled." : experimentMode == .ambient ? "Recording native ALS packets and labelled controls. No tap detector is enabled." : "Experiment recording locally at a requested 500 Hz."
            experimentTask = Task { [weak self] in
                guard let self else { return }
                var lastCue = 0
                while !Task.isCancelled && self.experimentActive {
                    self.experimentElapsed = self.reader.elapsedTime - self.experimentStart
                    if let index = self.experimentPhase.cueIndex, index != lastCue {
                        lastCue = index
                        self.cueEvents.append(["tap": index, "trial": index,
                            "kind": self.experimentPlan.trials[index - 1].rawValue,
                            "scheduled_seconds": self.experimentPlan.cueTime(index - 1),
                            "ui_update_seconds": self.experimentElapsed])
                    }
                    if self.reader.elapsedTime >= self.experimentEnd {
                        // Drain the last sensor batch before closing the CSV.
                        for _ in 0..<40 {
                            let drain = self.experimentMode == .lid ? 0 : 0.4
                            if self.latestDeliveredTime >= self.experimentEnd + drain { break }
                            try? await Task.sleep(for: .milliseconds(25))
                            if Task.isCancelled { return }
                        }
                        self.finishExperiment(completed: true); return
                    }
                    do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
                }
            }
        } catch {
            try? experimentFile?.close(); experimentFile = nil
            try? experimentALSFile?.close(); experimentALSFile = nil
            try? experimentMotionFile?.close(); experimentMotionFile = nil
            reader.setMotionEnabled(false)
            message = "Couldn’t start experiment: " + error.localizedDescription
        }
    }
    func stopManualExperiment() {
        guard experimentActive, experimentPlan.isManual, !experimentStopping else { return }
        experimentEnd = reader.elapsedTime
        experimentElapsed = experimentEnd - experimentStart
        experimentStopping = true
        // The existing task drains timestamped native callbacks through this stop boundary.
    }
    func finishExperiment(completed: Bool, error: String? = nil) {
        guard experimentActive else { return }
        experimentActive = false; experimentStopping = false; experimentTask?.cancel(); experimentTask = nil
        try? experimentFile?.close(); experimentFile = nil
        try? experimentALSFile?.close(); experimentALSFile = nil
        try? experimentMotionFile?.close(); experimentMotionFile = nil
        reader.setMotionEnabled(false)
        rate = experimentPreviousRate
        let span = max(0.001, (experimentLastTime ?? experimentStart) - (experimentFirstTime ?? experimentStart))
        let achieved = Double(max(0, experimentSamples - 1)) / span
        if let url = experimentURL {
            let complete = completed && cueEvents.count == experimentPlan.trials.count
                && (experimentMode == .lid || experimentALSFrames > 0)
                && (!experimentPlan.recordsMotion || (motionCounts["gyro", default: 0] > 0 && motionCounts["accel", default: 0] > 0))
            let nativeSpan = max(0.001, (experimentALSLast ?? 0) - (experimentALSFirst ?? 0))
            let nativeRate = Double(max(0, experimentALSFrames - 1)) / nativeSpan
            let measuredMotionRates = motionCounts.map { key, count in
                (key, Double(max(0, count - 1)) / max(0.001, (motionLast[key] ?? 0) - (motionFirst[key] ?? 0)))
            }
            let metadata: [String: Any] = ["completed": complete, "mode": experimentMode.rawValue,
                "on_lap": runOnLap, "lighting_label": runLightingLabel,
                "position_label": runPositionLabel,
                "manual_start_stop": experimentPlan.isManual,
                "manual_action": runManualAction.rawValue,
                "is_negative_control": experimentPlan.isManual && runManualAction != .missedTaps,
                "tap_count_is_instruction_not_detection": experimentPlan.isManual,
                "start_stop_note": experimentPlan.isManual ? "Start and Stop are user mouse actions. Their timestamps are experiment boundaries, not finger-contact labels; inspect boundary handling movement separately." : "",
                "tap_target": experimentPlan.isManual ? runManualAction.instruction : "light sensor left of camera, user-identified",
                "primary_signal": experimentPlan.isManual ? "motion_for_hover_hint_research" : "ambient_light",
                "requested_hz": experimentRequestedHz,
                "native_als_reports": experimentALSFrames, "native_als_hz": nativeRate,
                "motion_file": experimentPlan.recordsMotion ? url.deletingPathExtension().appendingPathExtension("motion.csv").lastPathComponent : "",
                "motion_counts": motionCounts, "motion_hz": Dictionary(uniqueKeysWithValues: measuredMotionRates),
                "motion_units": ["accel": "g", "gyro": "degrees_per_second"],
                "motion_status_at_end": snapshot.motionStatus,
                "als_file": url.deletingPathExtension().appendingPathExtension("als.csv").lastPathComponent,
                "skipped_trials": skippedTrials.sorted(),
                "trials": experimentPlan.trials.enumerated().map { ["trial": $0.offset + 1, "kind": $0.element.rawValue, "instruction": $0.element.instruction, "scheduled_seconds": experimentPlan.cueTime($0.offset)] as [String: Any] },
                "achieved_poll_hz": achieved, "sample_count": experimentSamples, "valid_report7_samples": experimentFineSamples,
                "baseline_seconds": experimentPlan.isManual ? 0 : experimentPlan.quietSeconds, "tap_count": experimentPlan.targetTapCount, "trial_count": experimentPlan.trials.count,
                "tap_spacing_seconds": experimentPlan.trialLength, "preparation_seconds": experimentPlan.preparationSeconds,
                "action_seconds": experimentPlan.actionSeconds,
                "duration_seconds": experimentPlan.isManual ? max(0, min(reader.elapsedTime, experimentEnd)-experimentStart) : experimentPlan.duration,
                "cue_timing": "ui_update_seconds marks the main-thread state change, not a hardware display-presentation timestamp",
                "cues": cueEvents, "sensor": snapshot.details, "hid_elements": snapshot.elements,
                "note": "ALS companion CSV contains each native callback once, including unchanged lux. IOHID timestamps are not necessarily optical integration times. Polling frequency does not equal new data frequency. No interpolation. Typed control text is never saved.",
                "error": error ?? ""]
            do { try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted,.sortedKeys]).write(to: url.deletingPathExtension().appendingPathExtension("json")) }
            catch { message = "CSV saved, but metadata could not be written: " + error.localizedDescription }
            if complete && experimentPlan.isManual && runManualAction == .missedTaps { completedMissedRuns += 1 }
            if complete && experimentMode == .tapping { completedTapRuns += 1 }
            if experimentPlan.isManual {
                experimentResult = "\(complete ? "Run saved" : "Partial run saved") · \(runManualAction.label) · \(motionCounts["gyro", default: 0]) gyro samples"
            } else if experimentPlan.recordsMotion {
                experimentResult = "\(complete ? "Combined experiment saved" : "Partial combined experiment saved") · \(experimentALSFrames) light reports · \(motionCounts["gyro", default: 0]) gyro samples"
            } else if experimentMode == .ambient {
                experimentResult = String(format: "%@ · %d native light reports · %.1f reports/s", complete ? "Light experiment saved" : "Partial light experiment saved", experimentALSFrames, nativeRate)
            } else {
                experimentResult = String(format: "%@ · %d samples · %.1f polls/s achieved", complete ? "Experiment saved" : "Partial experiment saved", experimentSamples, achieved)
            }
            message = error ?? url.path
        }
    }

    func skipTrial() {
        if let index = experimentPlan.trialIndex(at: experimentElapsed) { skippedTrials.insert(index + 1) }
    }
    func record() {
        if let recording { try? recording.close(); self.recording = nil; message = "Saved " + (recordingPath ?? ""); recordingPath = nil; return }
        do {
            let directory = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Captures")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("lid-\(Int(Date().timeIntervalSince1970)).csv")
            try Data("seconds,report7_degrees,report1_degrees,als_lux\n".utf8).write(to: url)
            recording = try FileHandle(forWritingTo: url); try recording?.seekToEnd()
            recordingPath = url.path; message = "Recording raw polled values locally."
        } catch { message = error.localizedDescription }
    }
}

struct HingeDiagram: View {
    let angle: Double
    let delta: Double
    var body: some View {
        Canvas { context, size in
            let hinge = CGPoint(x:size.width*0.43,y:size.height*0.77)
            let arm = min(size.height*0.62,size.width*0.46)
            let radians = angle * .pi/180
            let tip = CGPoint(x:hinge.x+cos(radians)*arm,y:hinge.y-sin(radians)*arm)
            var base=Path();base.move(to:hinge);base.addLine(to:CGPoint(x:hinge.x+arm,y:hinge.y))
            context.stroke(base,with:.color(.gray),style:StrokeStyle(lineWidth:9,lineCap:.round))
            var lid=Path();lid.move(to:hinge);lid.addLine(to:tip)
            context.stroke(lid,with:.color(.mint),style:StrokeStyle(lineWidth:7,lineCap:.round))
            var arc=Path()
            for i in 0...80 {let a=radians*Double(i)/80;let point=CGPoint(x:hinge.x+cos(a)*47,y:hinge.y-sin(a)*47);if i==0{arc.move(to:point)}else{arc.addLine(to:point)}}
            context.stroke(arc,with:.color(.white.opacity(0.45)),lineWidth:1)
            context.fill(Path(ellipseIn:CGRect(x:hinge.x-6,y:hinge.y-6,width:12,height:12)),with:.color(.white))
            context.draw(Text(String(format:"%.2f°",angle)).font(.system(size:18,weight:.medium,design:.monospaced)),at:CGPoint(x:hinge.x+64,y:hinge.y-58))
        }
        .overlay(alignment:.bottomLeading){Text(String(format:"Δ from baseline  %+.2f°",delta)).font(.system(size:12,design:.monospaced)).foregroundStyle(.secondary)}
        .accessibilityLabel(String(format:"Side view of laptop hinge, %.2f degrees open",angle))
    }
}

struct TracePlot: View {
    let samples: [LabSample]
    let field: KeyPath<LabSample, Double?>
    let color: Color
    let center: Double?
    let halfRange: Double?
    var body: some View {
        let values=samples.compactMap{$0[keyPath:field]}
        let minimum=values.min() ?? 0, maximum=values.max() ?? 1
        let middle=center ?? (minimum+maximum)/2
        let span=halfRange ?? max(0.05,(maximum-minimum)*0.6)
        let low=middle-span,high=middle+span
        VStack(alignment:.leading,spacing:6){
            HStack{Text(String(format:"%.3f",high));Spacer();Text("last 20 seconds")}.font(.system(size:10,design:.monospaced)).foregroundStyle(.secondary)
            Canvas {context,size in
                for index in 0...4 {var grid=Path();let y=size.height*Double(index)/4;grid.move(to:CGPoint(x:0,y:y));grid.addLine(to:CGPoint(x:size.width,y:y));context.stroke(grid,with:.color(.white.opacity(0.09)),lineWidth:0.5)}
                guard let end=samples.last?.time else{return}
                var path=Path();var began=false;var lastY=0.0
                for sample in samples {
                    guard let value=sample[keyPath:field] else{continue}
                    let x=(sample.time-(end-20))/20*size.width
                    let y=(1-(value-low)/(high-low))*size.height
                    if !began{path.move(to:CGPoint(x:x,y:y));began=true}else{path.addLine(to:CGPoint(x:x,y:lastY));path.addLine(to:CGPoint(x:x,y:y))}
                    lastY=y
                }
                context.clip(to:Path(CGRect(origin:.zero,size:size)))
                context.stroke(path,with:.color(color),lineWidth:1.5)
            }
            HStack{Text(String(format:"%.3f",low));Spacer();Text("unsmoothed · step plot")}.font(.system(size:10,design:.monospaced)).foregroundStyle(.secondary)
        }
    }
}

struct LabView: View {
    @ObservedObject var model: LabModel
    private func value(_ x: Double?, decimals: Int=2)->String{x.map{String(format:"%.*f",decimals,$0)} ?? "—"}
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            HStack(alignment:.top){
                VStack(alignment:.leading,spacing:5){Text("Lid Sensor Lab").font(.system(size:25,weight:.semibold));Text("Live hinge measurements + ambient light. No motion-triggered actions.").foregroundStyle(.secondary)}
                Spacer()
                Button(model.paused ? "Resume" : "Freeze"){model.paused.toggle()}.disabled(model.experimentActive)
                Button(model.recordingPath == nil ? "Record CSV" : "Stop recording"){model.record()}.disabled(model.experimentActive)
                Button(model.experimentActive ? (model.experimentPlan.isManual ? (model.experimentStopping ? "Saving…" : "Stop & save") : "Cancel experiment") : "Start experiment") {
                    if model.experimentActive {
                        if model.experimentPlan.isManual { model.stopManualExperiment() }
                        else { model.finishExperiment(completed: false) }
                    } else { model.startExperiment() }
                }.buttonStyle(.borderedProminent).tint(.mint).disabled(model.experimentStopping)
            }
            HStack(spacing:32){
                metric("PRECISE · REPORT 7",value(model.fine)+"°",.mint)
                metric("COARSE · REPORT 1",value(model.coarse,decimals:0)+"°",.gray)
                metric("AMBIENT LIGHT",value(model.lux)+" lx",.orange)
                Spacer()
                VStack(alignment:.trailing,spacing:6){Text(String(format:"%.0f polls/s · %.1f value changes/s",model.snapshot.pollHz,model.snapshot.changedHz));Text("Smallest observed step: "+value(model.snapshot.minimumStep)+"°")}.font(.system(size:12,design:.monospaced)).foregroundStyle(.secondary)
            }
            Picker("Experiment", selection: $model.experimentMode) {
                Text("Motion trials · manual").tag(ExperimentPlan.Mode.missedTaps)
                Text("Just taps · 45 sec").tag(ExperimentPlan.Mode.tapping)
                Text("Light + motion controls · 133 sec").tag(ExperimentPlan.Mode.fusion)
                Text("Light controls · 101 sec").tag(ExperimentPlan.Mode.ambient)
                Text("Lid-only taps · 29 sec").tag(ExperimentPlan.Mode.lid)
            }.pickerStyle(.segmented).disabled(model.experimentActive)
            if model.experimentPlan.isManual {
                HStack(spacing: 18) {
                    Toggle("On my lap", isOn: $model.onLap).toggleStyle(.checkbox)
                    TextField("Position / support (e.g. couch, knees raised)", text: $model.positionLabel)
                        .textFieldStyle(.roundedBorder).frame(minWidth: 260)
                    Picker("Action", selection: $model.manualAction) {
                        ForEach(ExperimentPlan.ManualAction.allCases, id: \.self) { action in
                            Text(action.label).tag(action)
                        }
                    }.frame(width: 240)
                    Text("Missed-tap runs: \(model.completedMissedRuns)").font(.system(size:12)).foregroundStyle(.secondary)
                }.disabled(model.experimentActive)
            } else if model.experimentMode == .tapping {
                HStack(spacing: 18) {
                    Toggle("On my lap", isOn: $model.onLap).toggleStyle(.checkbox)
                    TextField("Lighting label (optional)", text: $model.lightingLabel).textFieldStyle(.roundedBorder).frame(width: 230)
                    Spacer()
                    Text("5 seconds still → 10 taps, 4 seconds apart").font(.system(size:12)).foregroundStyle(.secondary)
                    Text("Saved this session: \(model.completedTapRuns)").font(.system(size:12)).foregroundStyle(.secondary)
                }.disabled(model.experimentActive)
            }
            Picker("View",selection:$model.tab){Text("Live measurements").tag(0);Text("Raw reports & sources").tag(1);Text("HID descriptor").tag(2)}.pickerStyle(.segmented).disabled(model.experimentActive)
            if model.experimentActive {
                ExperimentPanel(model: model)
            } else if model.tab == 0 {
                HStack(spacing:26){
                    HingeDiagram(angle:model.fine ?? model.coarse ?? 90,delta:(model.fine ?? 0)-(model.baseline ?? 0)).frame(width:290,height:230)
                    VStack(alignment:.leading,spacing:10){
                        HStack{Text("Precise hinge angle").font(.headline);Spacer();Picker("Range",selection:$model.zoom){Text("Auto").tag(0.0);Text("±0.1°").tag(0.1);Text("±0.5°").tag(0.5);Text("±2°").tag(2.0)}.frame(width:170);Button("Set baseline"){model.baseline=model.fine}}
                        TracePlot(samples:model.history,field:\.fine,color:.mint,center:model.zoom==0 ? nil:model.baseline,halfRange:model.zoom==0 ? nil:model.zoom).frame(height:185)
                    }
                }
                Divider()
                HStack(spacing:25){
                    VStack(alignment:.leading,spacing:8){Text("Whole-degree report").font(.headline);TracePlot(samples:model.history,field:\.coarse,color:.gray,center:nil,halfRange:nil)}
                    VStack(alignment:.leading,spacing:8){Text("Ambient light").font(.headline);TracePlot(samples:model.history,field:\.lux,color:.orange,center:nil,halfRange:nil)}
                }.frame(height:155)
                HStack{Text("ALS channels: "+model.snapshot.alsChannels.map(String.init).joined(separator:" · "));Spacer();Text(String(format:"ALS %.1f reports/s · lid input %.1f reports/s",model.snapshot.alsHz,model.snapshot.callbackHz))}.font(.system(size:11,design:.monospaced)).foregroundStyle(.secondary)
                Text("0.01° is the report’s encoding resolution, not a measured accuracy guarantee. Polling faster does not necessarily make the sensor update faster. No interpolation or gyro-derived angle is shown.").font(.system(size:12)).foregroundStyle(.secondary)
            } else if model.tab == 1 {
                ScrollView {
                    VStack(alignment:.leading,spacing:14){
                        Text(model.snapshot.details)
                        Text("Feature report bytes").font(.headline)
                        ForEach(model.snapshot.reports.keys.sorted(),id:\.self){key in Text("Report \(key): "+(model.snapshot.reports[key] ?? ""))}
                        Text("HID element API (same device; scaling is not additional precision)").font(.headline)
                        Text(model.snapshot.hidValues)
                        Text("Latest pushed lid angle: "+value(model.snapshot.inputAngle)+"°")
                        Text("ALS packet · 122 bytes · float32 lux at byte 40").font(.headline)
                        Text(model.snapshot.alsHex).textSelection(.enabled)
                        Text("Channels at bytes 20 / 24 / 28 / 32 are unsigned raw channel counts. Spectral labels are not assumed. Other ALS bytes remain undecoded.").foregroundStyle(.secondary)
                    }.font(.system(size:12,design:.monospaced)).frame(maxWidth:.infinity,alignment:.leading).textSelection(.enabled)
                }
            } else {
                ScrollView{Text(model.snapshot.elements).font(.system(size:12,design:.monospaced)).frame(maxWidth:.infinity,alignment:.leading).textSelection(.enabled)}
            }
            if !model.experimentResult.isEmpty && !model.experimentActive {
                Text(model.experimentResult).font(.system(size:13,weight:.medium)).foregroundStyle(.mint)
            }
            Spacer(minLength:0)
            Divider()
            HStack{Picker("Polling",selection:$model.rate){Text("20 Hz").tag(20.0);Text("100 Hz").tag(100.0);Text("250 Hz").tag(250.0);Text("500 Hz").tag(500.0)}.frame(width:190).disabled(model.experimentActive);Text(model.message.isEmpty ? "Tip: tap the lid, tap the desk, then cover the light sensor and compare." : model.message).font(.system(size:11)).foregroundStyle(.secondary);Spacer();if model.paused{Text("FROZEN").foregroundStyle(.orange)}}
        }
        .padding(26).frame(minWidth:1080,minHeight:800)
        .background(Color(white:0.055)).preferredColorScheme(.dark)
    }
    private func metric(_ label:String,_ text:String,_ color:Color)->some View{
        VStack(alignment:.leading,spacing:6){Text(label).font(.system(size:10,weight:.medium)).foregroundStyle(.secondary);Text(text).font(.system(size:32,weight:.medium,design:.monospaced)).foregroundStyle(color)}
    }
}

struct ExperimentPanel: View {
    @ObservedObject var model: LabModel
    @State private var scratch = ""
    @FocusState private var typingFocused: Bool
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(model.experimentPlan.isManual ? model.manualAction.label : model.experimentMode == .tapping ? "Tap the light sensor left of the camera · move your finger away between taps" : model.experimentMode != .lid ? "\(model.experimentPlan.targetTapCount) taps + \(model.experimentPlan.trials.count - model.experimentPlan.targetTapCount) controls · wait for NOW" : "6 taps · 4 seconds apart · raw lid reports requested at 500 Hz")
                    .font(.system(size:13)).foregroundStyle(.secondary)
                Spacer()
                if !model.experimentPlan.tapsOnly && !model.experimentPlan.isManual {
                    Button("Skip this trial") { model.skipTrial() }
                        .disabled(model.experimentPlan.trialIndex(at: model.experimentElapsed) == nil)
                }
            }
            VStack(spacing: 10) {
                if let index = model.experimentPlan.trialIndex(at: model.experimentElapsed), model.skippedTrials.contains(index + 1) {
                    Text("SKIPPED").font(.system(size:50,weight:.medium))
                    Text("Keep your hands away until the next trial.").foregroundStyle(.secondary)
                } else {
                    switch model.experimentPhase {
                    case .manual:
                        Text(model.experimentStopping ? "SAVING…" : model.manualAction.title)
                            .font(.system(size:48,weight:.semibold)).foregroundStyle(.mint)
                        Text(model.manualAction.instruction).font(.system(size:18))
                        if model.manualAction == .typing {
                            TextField("Type here", text: $scratch).textFieldStyle(.roundedBorder).frame(width: 300)
                                .focused($typingFocused).task { typingFocused = true }
                                .onDisappear { scratch = ""; typingFocused = false }
                        }
                        Text("Then press Stop & save. No countdown or automatic stop.").foregroundStyle(.secondary)
                        Text(String(format:"%.1f seconds recorded",model.experimentElapsed)).font(.system(size:18,design:.monospaced))
                    case .quiet(let seconds):
                        Text("DON’T TOUCH ANYTHING").font(.system(size:18,weight:.medium))
                        Text("\(seconds)").font(.system(size:74,weight:.medium,design:.monospaced))
                        Text("Measuring the untouched baseline").foregroundStyle(.secondary)
                    case .tap(let index):
                        Text("TAP").font(.system(size:80,weight:.semibold)).foregroundStyle(.mint)
                        Text("Tap \(index) of \(model.experimentPlan.targetTapCount) · light sensor left of camera").font(.system(size:18))
                    case .prepare(let index):
                        Text("WAIT · \(max(1, Int(ceil(model.experimentPlan.cueTime(index - 1) - model.experimentElapsed))))").font(.system(size:44,weight:.semibold))
                        Text("Next: " + model.experimentPlan.trials[index - 1].title).font(.system(size:20,weight:.medium)).foregroundStyle(.secondary)
                        Text(model.experimentPlan.trials[index - 1].instruction).font(.system(size:17)).multilineTextAlignment(.center)
                    case .action(let index):
                        let kind = model.experimentPlan.trials[index - 1]
                        Text("NOW · TRIAL \(index) / \(model.experimentPlan.trials.count)").font(.system(size:14)).foregroundStyle(.secondary)
                        Text(kind.title).font(.system(size:44,weight:.semibold)).foregroundStyle(kind == .tap ? .mint : .orange)
                        Text(kind.instruction).font(.system(size:17)).multilineTextAlignment(.center)
                        if kind == .typing {
                            TextField("Type abc here", text: $scratch).textFieldStyle(.roundedBorder).frame(width:220)
                                .focused($typingFocused).task { typingFocused = true }
                                .onDisappear { scratch = ""; typingFocused = false }
                        }
                    case .wait(let seconds, let next):
                        Text("HANDS AWAY · HOLD STILL").font(.system(size:18,weight:.medium))
                        Text("\(seconds)").font(.system(size:64,weight:.medium,design:.monospaced))
                        Text(next.map { "Next trial: \($0)" } ?? "Finishing the final capture window").foregroundStyle(.secondary)
                    case .done:
                        Text("SAVING…").font(.system(size:48,weight:.medium))
                    }
                }
            }.frame(maxWidth:.infinity,minHeight:205)
            if !model.experimentPlan.isManual {
                ProgressView(value:min(model.experimentElapsed,model.experimentPlan.duration),total:model.experimentPlan.duration).tint(.mint)
            }
            TracePlot(samples:model.history,field:model.experimentMode == .lid ? \.fine : \.lux,
                      color:model.experimentMode == .lid ? .mint : .orange,center:nil,halfRange:nil).frame(height:125)
            if model.experimentPlan.recordsMotion {
                Text(String(format: "Native streams · light %.1f Hz · gyro %.0f Hz · acceleration %.0f Hz", model.snapshot.alsHz, model.snapshot.gyroHz, model.snapshot.accelHz))
                    .font(.system(size:12,design:.monospaced)).foregroundStyle(.secondary)
            }
            Text(model.experimentPlan.isManual ? "Recording motion + light + lid angle locally. This experiment does not open the notch or trigger a hover hint." : model.experimentMode == .tapping ? "Light is the primary signal. Motion is recorded alongside it for comparison. Stops and saves automatically." : model.experimentMode != .lid ? "Native light packets are recorded once each. Controls test whether shadows can imitate contact. Skip any trial you cannot perform." : "The recording stops automatically. Follow the cue; no mouse or keyboard is needed.")
                .font(.system(size:12)).foregroundStyle(.secondary)
        }
    }
}

@MainActor final class LabDelegate: NSObject, NSApplicationDelegate {
    let model=LabModel()
    var window:NSWindow?
    func applicationDidFinishLaunching(_ notification:Notification){
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Lid Sensor Lab", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; NSApp.mainMenu = menu
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1180,height:850),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title="Lid Sensor Lab";window.isReleasedWhenClosed=false
        window.contentView=NSHostingView(rootView:LabView(model:model));window.center();window.makeKeyAndOrderFront(nil)
        self.window=window;NSApp.activate(ignoringOtherApps:true);model.start()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool{true}
    func applicationWillTerminate(_ notification:Notification){model.stop()}
}
@main enum Main {
    static func main(){MainActor.assumeIsolated{let app=NSApplication.shared;let delegate=LabDelegate();app.delegate=delegate;app.setActivationPolicy(.regular);withExtendedLifetime(delegate){app.run()}}}
}
