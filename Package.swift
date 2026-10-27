// swift-tools-version:6.2
// Music Toolbox: a native Mac app over the music panel on the server. It uploads music, loads it
// onto devices and shows what is wrong with files for a device. build.sh wraps it into an .app.
import PackageDescription

let package = Package(
    name: "MusicToolbox",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "MusicToolbox", path: "Sources/MusicToolbox")
    ],
    swiftLanguageModes: [.v5]
)
