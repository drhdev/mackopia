import AgentProtocol
import BackupDomain
import BackupEngine
import KopiaCLI
import KopiaServer
import Persistence
import Secrets
import SystemIntegration
import TestSupport
import Testing

// Building this test validates that every module in the initial dependency graph compiles.
@Test func packageModulesCompile() {}
