#!/bin/zsh
set -euo pipefail
task_root="${0:A:h:h}"
task_build="$(mktemp -d /tmp/chatcut-title-tests.XXXXXX)"
trap 'rm -rf "$task_build"' EXIT
cd "$task_root"
xcrun swiftc Sources/TimelineConverter.swift Sources/TitleRecovery.swift Sources/ExportService.swift Tests/SyntheticFixtures.swift Tests/TitleRecoveryTests.swift -o "$task_build/title-tests"
"$task_build/title-tests"
