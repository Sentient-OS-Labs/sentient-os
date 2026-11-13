# Physical notch taps

Physical taps open quick access on supported built-in displays. Settings → Notch & Shortcuts
controls the feature, second-tap action, sensitivity and optional calibration. The existing
preference defaults to enabled with Standard tuning. Close notch is the default second action;
Take Over or another action requires an explicit selection. Keyboard and pointer entry remain
available when sensors are unavailable or the feature is disabled.

## Ownership and sensing

`PhysicalNotchTap` owns the sensor lifecycle and delivers accepted events on the main actor.
`PhysicalTapSensor` reads native ambient light, accelerometer, gyroscope and lid angle on a
background thread. `PhysicalTapDetector` emits an event only after an ambient-light dip recovers
with nearby evidence from both motion streams. Motion callbacks never dispatch actions alone.
Every tap, including a second or continued tap, follows the same optical requirement.

The detector rejects invalid, duplicate and out-of-order readings. Gaps discard pending evidence.
Accepted taps have a 300 ms debounce; a rejected duplicate does not extend it. Ambient light uses
its native reporting rate. The two motion drivers request a 1,250 μs reporting interval while
active and restore saved values on shutdown if another client has not changed them. Missing or
stale motion blocks recognition. Native optical sampling limits the response rate; the interface
does not promise a particular physical tap latency or recognition accuracy on every Mac.

Startup, wake and lid movement require three seconds of settled lid readings. A cumulative 0.75°
change restarts settling. Closed, invalid or stale lid readings block actions. Sleep, screen sleep,
locking, unavailable built-in displays and calibration stop or suspend recognition. Main-actor
delivery rechecks ownership and generation, so queued events cannot act after eligibility changes.

## Onboarding warmup

The foreground film can own a sensor warmup request before the interactive lesson. Warmup follows
the same preference, display, sleep and lock gates. It does not admit actions. Each visible owner
releases only its own request; lesson admission timestamps fence earlier events. Unsupported or
stalled sensing offers the keyboard route rather than blocking onboarding.

## Calibration and the location cue

The optional calibration window owns the sensors while collecting a quiet baseline, five taps and
two noncontact finger passes. Ordinary notch actions are suspended. The evaluation replays the
production detector at Gentle, Standard and Firm, including a small threshold relaxation to check
separation. Every tap must appear once; quiet and pass trials must produce no actions. Streams
must remain continuous, the lid stable and the passes visibly shade the sensor.

Only successful calibration saves a versioned profile and sensitivity. Cancellation, failure and
interruption preserve existing tuning and the on/off preference. Raw samples are held in memory
and discarded. Manual sensitivity controls remain available independently of calibration.

The sensor-location illustration and passive Opal marker guide touch near the built-in notch.
The placement follows the measured hardware cutout geometry; it is not a verified sensor map for
every MacBook model. The marker is hit-transparent and does not take focus. Active tasks, voice,
completion and short notices suppress the idle touch cue. Dismissal can briefly retain the small
marker without delaying the next eligible tap.

`PhysicalMissedTapDetector` recognizes a conservative sequence of motion impulses only to show a
brief discovery hint. It cannot open input or execute an action. Keyboard/pointer activity, active
work, invalid lid state and stale streams suppress it. Detection is checked again before display.

## Files and verification

| File | Responsibility |
|---|---|
| `PhysicalNotchTap.swift` | App-lifetime ownership, warmup, admission and queued-event fencing |
| `PhysicalTapSensor.swift` | Native sensor streams, lid settling, interval restoration and teardown |
| `PhysicalTapDetector.swift` | Optical pulse and motion corroboration |
| `PhysicalTapCalibration.swift` | Bounded capture and calibration evaluation |
| `PhysicalMissedTapDetector.swift` | Hint-only motion sequence recognition |
| `NotchPreferences.swift` | Existing enable/action keys and versioned calibration profile |
| `../Views/Settings/NotchTouchCalibration.swift` | Calibration window and sensor-location guide |
| `../Self Tests - Temp/PhysicalTapLab.swift` | Isolated native presentation and sensor fixtures |

`Scripts/test_physical_notch_tap.py` exercises the production detector and calibration with
synthetic samples. `test_physical_tap_warmup.py` checks owner lifecycle and action fencing.
`test_missed_notch_hint.py` covers hint-only recognition and input suppression.
`test_onboarding_notch_demo.py` checks lesson ownership and keyboard fallback. The isolated
`ui-physical-tap` app fixture renders real views without live provider calls.

`Scripts/Fixtures/PhysicalTapRecorded.json` supplies bounded recorded-sample regression input.
The standalone `Tools/LidSensorLab` can collect and inspect additional local hardware samples;
its output directory is ignored. Development samples and deterministic fixtures do not establish
population accuracy, real-world false-activation rates or compatibility across every device.
