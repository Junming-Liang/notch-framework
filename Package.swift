// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "NotchFramework", platforms: [.macOS(.v13)],
    products: [.library(name: "NotchExtensionCore", targets: ["NotchExtensionCore"]),
               .executable(name: "NotchHost", targets: ["NotchHost"]),
               .executable(name: "NotchSmoke", targets: ["NotchSmoke"]),
               .executable(name: "NotchNetworkSmoke", targets: ["NotchNetworkSmoke"])],
    targets: [.target(name: "NotchExtensionCore"),
              .executableTarget(name: "NotchHost", dependencies: ["NotchExtensionCore"]),
              .executableTarget(name: "NotchSmoke", dependencies: ["NotchExtensionCore"]),
              .executableTarget(name: "NotchNetworkSmoke", dependencies: ["NotchExtensionCore"]),
              .testTarget(name: "NotchExtensionCoreTests", dependencies: ["NotchExtensionCore"], resources: [.copy("Fixtures")])])
