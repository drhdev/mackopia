import Foundation
import Testing

struct TestPythonRuntimeTests {
    @Test func checkedInterpreterTakesPrecedenceOverSwiftPMPath() {
        let configured = "/checked-runtime/bin/python3"
        let resolved = TestPythonRuntime.resolve(environment: [
            "MACKOPIA_TEST_PYTHON": configured,
            "PATH": "/usr/bin:/opt/homebrew/bin",
        ])
        #expect(resolved.path == configured)
    }

    @Test func localRunsFindAnExecutableInAbsolutePathEntries() {
        let resolved = TestPythonRuntime.resolve(environment: ["PATH": "relative-entry:/usr/bin"])
        #expect(resolved.path == "/usr/bin/python3")
    }
}
