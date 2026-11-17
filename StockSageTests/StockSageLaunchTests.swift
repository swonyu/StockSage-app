#if os(macOS)
import Testing
import Foundation
@testable import StockSage

@Suite("Retired QA launch boundary")
struct StockSageLaunchTests {
    @Test @MainActor func legacyCaptureExitsBeforeStartingSwiftUI() async throws {
        let executable = try #require(Bundle.main.executableURL)
        try #require(Bundle.main.bundleIdentifier == "SA.StockSage", "Probe only this freshly built test host")
        for arguments in [["--qa"], ["--section", "paper", "--qa"]] {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            // Do not inherit XCTest injection or owner environment into the child.
            process.environment = ["PATH": "/usr/bin:/bin"]
            let diagnostic = Pipe()
            process.standardError = diagnostic
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            defer { if process.isRunning { process.terminate() } }
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while process.isRunning, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            try #require(!process.isRunning, "Rejected capture must not start an application event loop")
            #expect(process.terminationStatus == 64)
            let output = String(decoding: diagnostic.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            #expect(output == StockSageLauncher.unsupportedQAMessage)
        }
    }
}
#endif
