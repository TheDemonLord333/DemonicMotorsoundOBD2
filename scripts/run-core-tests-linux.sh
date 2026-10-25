#!/usr/bin/env bash
# Baut die plattformunabhängigen Kernmodule (DemonicMotorsoundOBD2/Core) und führt die
# Unit-Tests (DemonicMotorsoundOBD2Tests) ohne Xcode in einem Swift-6.2-Linux-Container aus.
#
# Die Compiler-Einstellungen entsprechen dem Xcode-Projekt: Swift-5-Sprachmodus,
# Standard-Isolation MainActor und „Approachable Concurrency“.
# Die Apple-spezifischen Schichten (CoreBluetooth, Network, AVFAudio, SwiftUI) werden dabei
# NICHT gebaut – dafür ist Xcode erforderlich.
#
# Voraussetzung: Docker. Aufruf: scripts/run-core-tests-linux.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK_DIR:-$(mktemp -d)}"
IMAGE="${SWIFT_IMAGE:-swift:6.2-noble}"

rm -rf "$WORK/Sources" "$WORK/Tests"
mkdir -p "$WORK/Sources/DemonicMotorsoundOBD2" "$WORK/Tests/CoreTests"
cp -R "$ROOT/DemonicMotorsoundOBD2/Core/." "$WORK/Sources/DemonicMotorsoundOBD2/"
cp "$ROOT"/DemonicMotorsoundOBD2Tests/*.swift "$WORK/Tests/CoreTests/"

cat > "$WORK/Package.swift" <<'PKG'
// swift-tools-version: 6.2
import PackageDescription

let concurrency: [SwiftSetting] = [
    .swiftLanguageMode(.v5),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
    name: "DemonicMotorsoundCore",
    targets: [
        .target(name: "DemonicMotorsoundOBD2", swiftSettings: concurrency + [.defaultIsolation(MainActor.self)]),
        .testTarget(name: "CoreTests", dependencies: ["DemonicMotorsoundOBD2"], swiftSettings: concurrency),
    ]
)
PKG

docker run --rm -v "$WORK":/pkg -w /pkg "$IMAGE" swift test "$@"
