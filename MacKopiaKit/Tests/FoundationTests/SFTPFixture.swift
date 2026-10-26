import Darwin
import Foundation
import Testing

struct SFTPFixture {
    let process: Process
    let control: Pipe
    let port: Int
    let username: String
    let privateKey: String
    let wrongKey: String
    let hostKey: String
    let encryptedKey: String
    let passphrase: String

    init(root: URL) async throws {
        process = Process(); control = Pipe()
        let readiness = Pipe()
        process.executableURL = TestPythonRuntime.executable
        process.arguments = [
            NativeKopiaFixture.root.appendingPathComponent("Scripts/native_sftp_fixture.py").path,
            root.path,
        ]
        process.environment = [
            "HOME": root.path, "TMPDIR": root.path, "PYTHONDONTWRITEBYTECODE": "1",
        ]
        process.standardInput = control; process.standardOutput = readiness;
        process.standardError = FileHandle.nullDevice
        try process.run()
        do {
            let fd = readiness.fileHandleForReading.fileDescriptor
            #expect(fcntl(fd, F_SETFL, O_NONBLOCK) == 0)
            var data = Data(); var buffer = [UInt8](repeating: 0, count: 16_384)
            let deadline = ContinuousClock.now.advanced(by: .seconds(15))
            while !data.contains(10), ContinuousClock.now < deadline {
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count > 0 { data.append(contentsOf: buffer.prefix(count)) }
                if count == 0 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let value = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            port = try #require(value["port"] as? Int)
            username = try #require(value["username"] as? String)
            privateKey = try #require(value["privateKey"] as? String)
            wrongKey = try #require(value["wrongKey"] as? String)
            hostKey = try #require(value["hostKey"] as? String)
            encryptedKey = try #require(value["encryptedKey"] as? String)
            passphrase = try #require(value["passphrase"] as? String)
        } catch {
            try? control.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            throw error
        }
    }
    func close() {
        try? control.fileHandleForWriting.close()
        process.waitUntilExit()
    }
}
