# Lid Sensor Lab

A standalone native diagnostic app for local lid-angle, ambient-light and motion experiments.
It does not trigger Sidekick or require sudo. It is outside the app's synchronized source group.

Build with `zsh Tools/LidSensorLab/build.sh`, then open
`Tools/LidSensorLab/build/Lid Sensor Lab.app`. Run deterministic experiment checks with
`zsh Tools/LidSensorLab/test.sh`.

## Recording

The app supports guided touch trials, manual missed-tap recordings, and controls such as desk
movement, typing and hand-rest motion. Choose the experiment and support conditions before
recording. Start/Stop handling movements are part of the recording and must not be labelled as
intended taps. Closing during a recording preserves a partial run.

CSV samples and companion JSON metadata stay in the ignored `build/Captures/` directory. They
include native timestamps, report values, cue timing and recording boundaries. Text typed into
the control box is not saved. These files are local research output and are not uploaded.

Motion experiments temporarily request a 1,250 μs reporting interval and restore saved values on
completion, cancellation or normal exit. Requested polling rate, sensor refresh rate and observed
value-change rate are different quantities. Repeated samples are not independent measurements.

## Analysis tools

| Tool | Purpose |
|---|---|
| `analyze_experiments.py` | Inspect guided lid experiments and timing |
| `analyze_ambient.py` | Inspect native light trials |
| `analyze_tapping.py` | Replay the production detector against recorded samples |
| `analyze_missed_taps.py` | Explore manual motion recordings |
| `analyze_motion_controls.py` | Compare positive and negative motion trials |
| `Tests/RapidCapture.swift` | Record native sensor streams without dispatching app actions |
| `Tests/TapReplay.swift` | Replay samples through the production detector |
| `Research/` | Low-level device probes and observed report behavior |

Run analysis scripts against your own captures. A fresh clone contains code and bounded regression
fixtures, not a complete collection of hardware recordings. Timing labels measure software cue
updates, not physical display presentation or finger-contact ground truth.

The production feature requires ambient-light recovery with accelerometer and gyroscope evidence
for every tap. Older exploratory probes or analyses do not define the current app behavior.
See `Sentient OS macOS/Notch Magic/Documentation - Physical Screen Tap.md` for the current contract.
Hardware observations from one Mac are not compatibility, accuracy or false-positive guarantees.
