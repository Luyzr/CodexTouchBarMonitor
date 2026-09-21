// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "CodexTouchBarMonitor", platforms: [.macOS(.v13)], products: [
.executable(name: "CodexTouchBarMonitor", targets: ["MonitorApp"])
], targets: [
.target(name: "MonitorCore"),
.target(name: "TouchBarPrivateBridge", publicHeadersPath: "include", linkerSettings: [.linkedFramework("AppKit")]),
.executableTarget(name: "MonitorApp", dependencies: ["MonitorCore", "TouchBarPrivateBridge"]),
.executableTarget(name: "MonitorCoreTests", dependencies: ["MonitorCore"], path: "Tests/MonitorCoreTests", exclude: ["StatusTests.swift"])
])
