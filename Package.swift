// swift-tools-version: 6.2
import PackageDescription
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "Audioglass",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "Audioglass", targets: ["Audioglass"])],
    targets: [
        .target(name: "DSPBridge", publicHeadersPath: "include"),
        .executableTarget(name: "Audioglass", dependencies: ["DSPBridge"],
            linkerSettings: [.unsafeFlags(["-L\(root)/Rust/target/release", "-laudioglass_dsp"])])
    ]
)
