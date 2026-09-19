#!/usr/bin/env bash
# Local equivalent of .github/workflows/ci.yml.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
Scripts/bootstrap_dependencies.sh
swift build
swift test
xcodebuild -project App/VoiceAgent.xcodeproj -scheme VoiceAgentSim \
  -destination "platform=iOS Simulator,name=${SIMULATOR:-iPhone 17 Pro}" -derivedDataPath .build/xcode-ci build
xcodebuild -project App/VoiceAgent.xcodeproj -scheme VoiceAgent \
  -destination 'generic/platform=iOS' -derivedDataPath .build/xcode-ci CODE_SIGNING_ALLOWED=NO build
echo "CI OK"
