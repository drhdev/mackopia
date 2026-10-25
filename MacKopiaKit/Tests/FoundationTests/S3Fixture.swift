import Darwin
import Foundation
import Testing

struct S3Fixture {
    let process: Process
    let control: Pipe
    let endpoint: String
    let access = UUID().uuidString
    let secret = UUID().uuidString
    let token: String

    init(root: URL, useSessionToken: Bool = true) async throws {
        token = useSessionToken ? UUID().uuidString : ""
        process = Process(); control = Pipe()
        let readiness = Pipe()
        process.executableURL = TestPythonRuntime.executable
        process.arguments = [
            NativeKopiaFixture.root.appendingPathComponent("Scripts/native_s3_fixture.py").path,
            root.appendingPathComponent("storage").path,
        ]
        process.environment = [
            "HOME": root.path, "TMPDIR": root.path, "PYTHONDONTWRITEBYTECODE": "1",
            "FIXTURE_ACCESS": access, "FIXTURE_SECRET": secret, "FIXTURE_TOKEN": token,
        ]
        process.standardInput = control; process.standardOutput = readiness;
        process.standardError = FileHandle.nullDevice
        try process.run()
        do {
            let fd = readiness.fileHandleForReading.fileDescriptor
            #expect(fcntl(fd, F_SETFL, O_NONBLOCK) == 0)
            var data = Data(); var buffer = [UInt8](repeating: 0, count: 1024)
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !data.contains(10), ContinuousClock.now < deadline {
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count > 0 { data.append(contentsOf: buffer.prefix(count)) }
                if count == 0 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let value = try #require(JSONSerialization.jsonObject(with: data) as? [String: Int])
            endpoint = "http://127.0.0.1:\(try #require(value["port"]))"
        } catch {
            try? control.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            throw error
        }
    }
    func close() {
        try? control.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }
}
