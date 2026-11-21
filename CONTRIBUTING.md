# Contributing

Use a macOS 26 SDK and Swift 6. Run `Scripts/test.sh` and `Scripts/package.sh` before opening a pull request. Include the macOS version, SDK, hardware architecture, and test results for platform-specific changes.

Keep metric collection in the provider, timing in the telemetry engine, and display logic in SwiftUI or AppKit. Sensor proposals should identify their API, demonstrate the measurement on affected hardware, and define the unavailable state across other Macs. Use local loopback fixtures for socket tests. Redact process names and addresses from screenshots or bug reports if they identify private services.

Discuss larger changes in an issue before implementation. Use the repository's private vulnerability reporting channel for security issues. See the [Code of Conduct](CODE_OF_CONDUCT.md) and [Security Policy](SECURITY.md).
