// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Plank",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Plank", targets: ["Plank"])],
    targets: [.executableTarget(name: "Plank", resources: [.copy("Resources/MaterialIcons")])]
)
