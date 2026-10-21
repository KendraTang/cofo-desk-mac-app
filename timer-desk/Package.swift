// swift-tools-version: 6.0
import PackageDescription

// Command Line Tools ship Swift Testing outside the default search paths. SwiftPM only enables
// the Swift Testing runner when it sees the -F flag on the command line, so run ./test.sh.
let cltDeveloper = "/Library/Developer/CommandLineTools/Library/Developer"
let testingLinkerFlags: [String] = [
    "-F", "\(cltDeveloper)/Frameworks",
    "-Xlinker", "-rpath", "-Xlinker", "\(cltDeveloper)/Frameworks",
    "-Xlinker", "-rpath", "-Xlinker", "\(cltDeveloper)/usr/lib",
]

let package = Package(
    name: "timer-desk",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "TimerDeskCore"),
        .executableTarget(name: "timer-desk", dependencies: ["TimerDeskCore"]),
        .testTarget(
            name: "TimerDeskCoreTests",
            dependencies: ["TimerDeskCore"],
            linkerSettings: [.unsafeFlags(testingLinkerFlags)]
        ),
    ]
)
