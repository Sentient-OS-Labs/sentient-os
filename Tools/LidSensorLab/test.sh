#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
mkdir -p build
xcrun swiftc -parse-as-library Experiment.swift ALSFrame.swift MotionFrame.swift Tests/ExperimentTests.swift -o build/experiment-tests
build/experiment-tests
