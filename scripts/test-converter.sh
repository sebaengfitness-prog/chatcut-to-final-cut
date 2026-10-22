#!/bin/zsh
set -euo pipefail
task_root="${0:A:h:h}"
task_build="$(mktemp -d /tmp/chatcut-converter-tests.XXXXXX)"
trap 'rm -rf "$task_build"' EXIT
cd "$task_root"
xcrun swiftc Sources/TimelineConverter.swift Tests/SyntheticFixtures.swift Tests/TimelineConverterTests.swift -o "$task_build/converter-tests"
"$task_build/converter-tests"
