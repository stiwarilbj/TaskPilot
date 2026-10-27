import Darwin
import Foundation
import CoreServices
import XCTest
@testable import OrbitAgent

final class ManagedOpenClawTests: XCTestCase {
    func testManagedEnvironmentMatchesSharedPolicyAndIsIdempotent() throws {
        struct Fixture: Decodable { let name: String; let inherited: [String: String]; let expected: [String: String]; let code: Int }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/managed-environment-cases.json")
        for fixture in try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url)) {
            let result = OpenClawService.managedEnvironment(inherited: fixture.inherited, nodePath: "/private/node/bin/node")
            XCTAssertEqual(result.values, fixture.expected, fixture.name)
            XCTAssertEqual(result.mismatchCode, fixture.code, fixture.name)
            let repeated = OpenClawService.managedEnvironment(inherited: result.values, nodePath: "/private/node/bin/node")
            XCTAssertEqual(repeated.values, result.values); XCTAssertEqual(repeated.mismatchCode, 0)
        }
    }

    func testManagedEnvironmentReachesChildWithoutShellLookupOrNodeInjection() {
        let effective = OpenClawService.managedEnvironment(inherited: ["NODE_OPTIONS": "--import rejected", "PATH": "/untrusted", "LC_ALL": "custom"], nodePath: "/private/node/bin/node")
        let result = OpenClawService.run(executable: URL(fileURLWithPath: "/usr/bin/env"), arguments: [], timeout: 2, environment: effective.values)
        XCTAssertEqual(result.status, 0)
        let lines = Set(result.output.split(separator: "\n").map(String.init))
        XCTAssertTrue(lines.contains("PATH=/private/node/bin:/usr/bin:/bin:/usr/sbin:/sbin"))
        XCTAssertTrue(lines.contains("LC_ALL=en_US.UTF-8"))
        XCTAssertFalse(lines.contains(where: { $0.hasPrefix("NODE_") }))
    }

    private func hintFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:root) }
        return root
    }
    private func waitForHints(_ hints: ManagedRuntimeFileHints, at now: TimeInterval = 0) -> ManagedRuntimeFileHints.Changes {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        repeat {
            let changes = hints.takeChanges(at:now)
            if !changes.isEmpty { return changes }
            Thread.sleep(forTimeInterval:0.01)
        } while ProcessInfo.processInfo.systemUptime < deadline
        XCTFail("Expected filesystem invalidation hint")
        return []
    }
    func testNotificationLossFlagsRequireFullAuditButOrdinaryEventsDoNot() throws {
        let root = try hintFixture(), file = root.appendingPathComponent("config")
        try Data("local".utf8).write(to: file)
        let hints = ManagedRuntimeFileHints(root: root, watchNotificationGaps: false)
        defer { hints.close() }
        hints.configure([file: .configuration])
        hints.noteEventFlags([FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified),
                              FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone)])
        XCTAssertTrue(hints.takeChanges(at: 0).isEmpty)
        for (index, flag) in [kFSEventStreamEventFlagMustScanSubDirs, kFSEventStreamEventFlagUserDropped,
                             kFSEventStreamEventFlagKernelDropped, kFSEventStreamEventFlagEventIdsWrapped,
                             kFSEventStreamEventFlagRootChanged, kFSEventStreamEventFlagMount,
                             kFSEventStreamEventFlagUnmount].enumerated() {
            hints.noteEventFlags([FSEventStreamEventFlags(flag)])
            XCTAssertEqual(hints.takeChanges(at: Double(index * 5)), .rescanRequired)
        }
        hints.noteEventFlags([FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped)])
        XCTAssertTrue(hints.takeChanges(at: 34).isEmpty)
        XCTAssertEqual(hints.takeChanges(at: 35), .rescanRequired)
        try Data("changed".utf8).write(to: file)
        hints.refresh()
        XCTAssertEqual(hints.takeChanges(at: 40), .configuration)
        hints.close()
        hints.noteEventFlags([FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped)])
        XCTAssertTrue(hints.takeChanges(at: 50).isEmpty)
    }

    func testDirectoryReplacementRequiresRescanEvenWhenFileMetadataMatches() throws {
        let root = try hintFixture(), folder = root.appendingPathComponent("instance"), file = folder.appendingPathComponent("config")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data("local".utf8).write(to: file)
        let hints = ManagedRuntimeFileHints(root: root, watchNotificationGaps: false, openDescriptor: { _ in -1 })
        defer { hints.close() }
        hints.configure([file: .configuration])
        try FileManager.default.moveItem(at: folder, to: root.appendingPathComponent("previous"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data("local".utf8).write(to: file)
        hints.refresh()
        XCTAssertEqual(hints.takeChanges(at: 0), [.configuration, .rescanRequired])
    }

    func testGapAuditRequirementSurvivesFailureUntilSuccessfulFullPass() {
        var schedule = FullIntegrityAuditSchedule()
        schedule.record(at: 100, succeeded: true)
        schedule.requireFullAudit()
        XCTAssertTrue(schedule.shouldRun(at: 200))
        schedule.record(at: 200, succeeded: false)
        XCTAssertTrue(schedule.fullAuditRequired)
        XCTAssertEqual(schedule.lastSuccessfulAudit, 100)
        XCTAssertFalse(schedule.shouldRun(at: 259))
        XCTAssertTrue(schedule.shouldRun(at: 260))
        schedule.record(at: 260, succeeded: true)
        XCTAssertFalse(schedule.fullAuditRequired)
        XCTAssertFalse(schedule.shouldRun(at: 261))
    }
    func testFileHintsObserveWritesAndAtomicReplacementAndRearm() throws {
        let root = try hintFixture(), file = root.appendingPathComponent("code")
        try Data("first".utf8).write(to:file)
        let hints = ManagedRuntimeFileHints(root:root); defer { hints.close() }
        hints.configure([file:.installation])
        XCTAssertTrue(hints.takeChanges(at:0).isEmpty)
        try Data("second".utf8).write(to:file)
        XCTAssertEqual(waitForHints(hints),.installation)
        try Data("replacement".utf8).write(to:file,options:.atomic)
        XCTAssertEqual(waitForHints(hints,at:5),.installation)
        try Data("third".utf8).write(to:file)
        XCTAssertEqual(waitForHints(hints,at:10),.installation)
    }
    func testFileHintsCoalesceAndIgnoreUnrelatedBookkeeping() throws {
        let root = try hintFixture(), file = root.appendingPathComponent("config")
        try Data("first".utf8).write(to:file)
        let hints = ManagedRuntimeFileHints(root:root); defer { hints.close() }
        hints.configure([file:.configuration])
        try Data("health".utf8).write(to:root.appendingPathComponent("health.json"),options:.atomic)
        hints.refresh()
        XCTAssertTrue(hints.takeChanges(at:0).isEmpty)
        try Data("changed".utf8).write(to:file)
        hints.refresh()
        XCTAssertEqual(hints.takeChanges(at:0),.configuration)
        try Data("changed again".utf8).write(to:file)
        hints.refresh()
        XCTAssertTrue(hints.takeChanges(at:4).isEmpty)
        XCTAssertEqual(hints.takeChanges(at:5),.configuration)
    }
    func testFileHintsDetectMissingDirectoriesAndStopWatchingOldTargets() throws {
        let root = try hintFixture(), folder = root.appendingPathComponent("instance")
        let file = folder.appendingPathComponent("config")
        let hints = ManagedRuntimeFileHints(root:root); defer { hints.close() }
        hints.configure([file:.configuration])
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        try Data("created".utf8).write(to:file)
        XCTAssertEqual(waitForHints(hints),.configuration)
        let replacement = root.appendingPathComponent("other")
        try Data("other".utf8).write(to:replacement)
        hints.configure([replacement:.installation])
        try Data("old".utf8).write(to:file)
        hints.refresh()
        XCTAssertTrue(hints.takeChanges(at:10).isEmpty)
        hints.close()
        try Data("closed".utf8).write(to:replacement)
        hints.refresh()
        XCTAssertTrue(hints.takeChanges(at:20).isEmpty)
    }
    func testUnsupportedWatchesRetainTimedRefreshAndDoNotFollowOutsidePaths() throws {
        let root = try hintFixture(), file = root.appendingPathComponent("config")
        try Data("initial".utf8).write(to:file)
        let hints = ManagedRuntimeFileHints(root:root,openDescriptor:{ _ in -1 }); defer { hints.close() }
        hints.configure([file:.configuration])
        try Data("changed".utf8).write(to:file)
        XCTAssertTrue(hints.takeChanges(at:0).isEmpty)
        hints.refresh() // Existing timed audit is still a validation/rearm boundary.
        XCTAssertEqual(hints.takeChanges(at:0),.configuration)
        let outside = try hintFixture().appendingPathComponent("other")
        try Data("outside".utf8).write(to:outside)
        hints.configure([outside:.installation])
        hints.refresh()
        XCTAssertTrue(hints.takeChanges(at:10).isEmpty)
        var schedule = FullIntegrityAuditSchedule()
        schedule.record(at:100,succeeded:true)
        XCTAssertTrue(schedule.shouldRun(at:3700))
    }

    func testFullIntegrityAuditScheduleUsesMonotonicTimeAndSuccessfulPassesOnly() {
        var schedule = FullIntegrityAuditSchedule()
        XCTAssertTrue(schedule.shouldRun(at:100)) // Gateway host startup.
        schedule.record(at:100,succeeded:false)
        XCTAssertFalse(schedule.shouldRun(at:159))
        XCTAssertTrue(schedule.shouldRun(at:160))
        schedule.record(at:160,succeeded:true)
        XCTAssertFalse(schedule.shouldRun(at:3759))
        XCTAssertTrue(schedule.shouldRun(at:3760))
        XCTAssertTrue(schedule.shouldRun(at:159)) // A monotonic clock reset forces a full pass.
        schedule.reset()
        XCTAssertTrue(schedule.shouldRun(at:10))
    }

    private func descriptor(_ root: URL) throws -> ManagedOpenClawDescriptor {
        let port = 24200
        let value: [String:Any] = ["version":1,"instance_id":UUID().uuidString.lowercased(),
            "installation_fingerprint":"pin","configuration_fingerprint":"config",
            "executable":root.path+"/openclaw","node":root.path+"/node","entry":root.path+"/entry",
            "state":root.path+"/state","config":root.path+"/config","workspace":root.path+"/workspace",
            "token_file":root.path+"/token","port":port,"endpoint":"ws://127.0.0.1:\(port)",
            "openclaw_version":"fixture","node_version":"fixture"]
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try JSONSerialization.data(withJSONObject:value).write(to:root.appendingPathComponent("runtime.json"))
        return try ManagedOpenClawDescriptor.load(from:root.appendingPathComponent("runtime.json"))
    }
    func testHealthRequiresFreshMatchingFingerprintsAndBothBirthIdentities() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let instance = try descriptor(root)
        let identity = try XCTUnwrap(ManagedProcessIdentity.read(getpid()))
        let record = try JSONSerialization.jsonObject(with:JSONEncoder().encode(identity))
        let healthy: [String:Any] = ["version":1,"state":"healthy","instance_id":instance.instanceID,
            "installation_fingerprint":"pin","configuration_fingerprint":"config","checked_at":1000.0,
            "host_identity":record,"gateway_identity":record]
        XCTAssertTrue(instance.acceptsHealth(healthy,now:1001))
        for (key, value) in [("installation_fingerprint","old" as Any),("configuration_fingerprint","old"),
                             ("checked_at",900.0),("checked_at",1002.0),("gateway_identity",[:])] {
            var changed = healthy; changed[key] = value
            XCTAssertFalse(instance.acceptsHealth(changed,now:1001))
        }
        var reused = healthy
        reused["gateway_identity"] = ["pid":identity.pid,"seconds":identity.seconds+1,"microseconds":identity.microseconds]
        XCTAssertFalse(instance.acceptsHealth(reused,now:1001))
    }
    func testRepairExcludesWholeActionsAndNewDeliveryWithoutBlocking() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        var action: ManagedRuntimePermit? = try ManagedRuntimePermit(root:root,repairing:false,requireHealth:false)
        XCTAssertThrowsError(try ManagedRuntimePermit(root:root,repairing:true))
        withExtendedLifetime(action) {}; action = nil
        var repair: ManagedRuntimePermit? = try ManagedRuntimePermit(root:root,repairing:true)
        XCTAssertThrowsError(try ManagedRuntimePermit(root:root,repairing:false,requireHealth:false))
        let lease = TaskLease(); lease.managedRuntimeRoot = root
        var delivered = false
        XCTAssertThrowsError(try lease.commit { delivered = true })
        XCTAssertFalse(delivered)
        withExtendedLifetime(repair) {}; repair = nil
        XCTAssertNoThrow(try ManagedRuntimePermit(root:root,repairing:true))
    }
    func testRestartBudgetSurvivesSerializationAndHealthyRefreshDoesNotEraseAttempts() throws {
        var budget = GatewayRecoveryBudget()
        XCTAssertEqual(budget.failed(now:1000),1)
        XCTAssertEqual(budget.failed(now:1001),3)
        XCTAssertEqual(budget.failed(now:1004),10)
        XCTAssertEqual(budget.failed(now:1014),60)
        XCTAssertFalse(budget.restartReserved)
        for delay in [120.0,240,300,300] { XCTAssertEqual(budget.failed(now:1015),delay) }
        budget = try JSONDecoder().decode(GatewayRecoveryBudget.self,from:JSONEncoder().encode(budget))
        budget.healthy()
        XCTAssertEqual(budget.restarts.count,3)
        XCTAssertEqual(budget.failed(now:1020),60)
        XCTAssertEqual(budget.failed(now:1610),1)
    }
    func testOldBudgetDecodesWithoutResettingSpentAttempts() throws {
        let data = Data(#"{"restarts":[1,2,3],"nextProbe":70,"circuits":1}"#.utf8)
        var budget = try JSONDecoder().decode(GatewayRecoveryBudget.self,from:data)
        XCTAssertFalse(budget.restartReserved)
        XCTAssertEqual(budget.failed(now:10),120)
        XCTAssertEqual(budget.restarts.count,3)
    }
    func testClientLeaseMatchesBirthIdentityAndRejectsReusedPID() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let file = try ManagedGatewayHost.registerClient(root:root)
        XCTAssertTrue(ManagedGatewayHost.clientsAlive(root:root))
        let actual = try JSONDecoder().decode(ManagedProcessIdentity.self,from:Data(contentsOf:file))
        XCTAssertTrue(actual.alive)
        let stale = ManagedProcessIdentity(pid:actual.pid,seconds:actual.seconds+1,microseconds:actual.microseconds)
        try ManagedGatewayHost.write(stale,to:file)
        XCTAssertFalse(ManagedGatewayHost.clientsAlive(root:root))
        XCTAssertFalse(FileManager.default.fileExists(atPath:file.path))
        XCTAssertNotNil(ManagedProcessIdentity.read(getpid())) // No signal was sent to reused PID.
    }
    func testOccupiedPortIsNeverConsideredAvailable() throws {
        let fd = socket(AF_INET,SOCK_STREAM,0); XCTAssertGreaterThanOrEqual(fd,0); defer { close(fd) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1")
        XCTAssertEqual(withUnsafePointer(to:&address) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { Darwin.bind(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) } },0)
        XCTAssertEqual(listen(fd,1),0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to:&address) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { getsockname(fd,$0,&length) } }
        XCTAssertFalse(ManagedGatewayHost.portAvailable(Int(UInt16(bigEndian:address.sin_port))))
    }
    func testBoundedVerifierCommandCancelsAndDrainsTree() throws {
        let cancellation = OpenClawCommandCancellation()
        let completed = expectation(description:"Cancelled owned command")
        let start = ProcessInfo.processInfo.systemUptime
        DispatchQueue.global().async {
            let result = OpenClawService.run(executable:URL(fileURLWithPath:"/bin/sleep"), arguments:["60"], timeout:90,cancellation:cancellation)
            XCTAssertEqual(result.status,-2); completed.fulfill()
        }
        DispatchQueue.global().asyncAfter(deadline:.now()+0.1) { cancellation.cancel() }
        wait(for:[completed],timeout:5)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime-start,5)
    }
    func testPreCancelledCommandDoesNotLaunch() {
        let cancellation = OpenClawCommandCancellation(); cancellation.cancel()
        let result = OpenClawService.run(executable:URL(fileURLWithPath:"/nonexistent"), arguments:[], timeout:1,cancellation:cancellation)
        XCTAssertEqual(result.status,-2)
    }
    func testFailedLaunchReturnsWithoutWaitingForUnlaunchedTree() {
        let result = OpenClawService.run(executable:URL(fileURLWithPath:"/nonexistent"), arguments:[], timeout:1)
        XCTAssertEqual(result.status,-1)
    }
    func testDescriptorChecksKnownPrivateAncestorsAndCredentialDirectories() throws {
        let root = try hintFixture(); XCTAssertEqual(chmod(root.path, 0o700), 0)
        let state = root.appendingPathComponent("instances/fixture")
        let install = root.appendingPathComponent("installations/fixture")
        for path in ["installations", "installations/fixture", "instances", "instances/fixture", "instances/fixture/workspace", "instances/fixture/agents", "instances/fixture/agents/main", "instances/fixture/agents/main/agent"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
        }
        let port = 24200
        let value: [String:Any] = ["version":1,"instance_id":UUID().uuidString.lowercased(),
            "installation_fingerprint":"fixture","configuration_fingerprint":"fixture",
            "executable":state.path+"/openclaw","node":install.path+"/node/bin/node","entry":install.path+"/openclaw.mjs",
            "state":state.path,"config":state.path+"/openclaw.json","workspace":state.path+"/workspace","token_file":state.path+"/token",
            "port":port,"endpoint":"ws://127.0.0.1:\(port)","openclaw_version":"fixture","node_version":"fixture"]
        let url = root.appendingPathComponent("runtime.json")
        try JSONSerialization.data(withJSONObject:value).write(to:url)
        let descriptor = try ManagedOpenClawDescriptor.load(from:url)
        try descriptor.checkPrivateDirectories()
        let credentialDirectory = state.appendingPathComponent("agents/main/agent")
        XCTAssertEqual(chmod(credentialDirectory.path, 0o755), 0)
        XCTAssertThrowsError(try descriptor.checkPrivateDirectories()) {
            XCTAssertEqual($0 as? PrivateDirectoryPermissions.Failure, .permissions)
        }
        try PrivateDirectoryPermissions.check(credentialDirectory, repair:true)
        try descriptor.checkPrivateDirectories()
        let workspace = state.appendingPathComponent("workspace")
        try FileManager.default.removeItem(at:workspace)
        try FileManager.default.createSymbolicLink(at:workspace, withDestinationURL:state)
        XCTAssertThrowsError(try descriptor.checkPrivateDirectories()) {
            XCTAssertEqual($0 as? PrivateDirectoryPermissions.Failure, .symlink)
        }
    }

    func testUnsafeDirectoryFaultRequiresAttentionRatherThanReinstall() {
        for cause in ["private_directory_symlink", "private_directory_ownership", "private_directory_changed", "private_directory_unavailable"] {
            XCTAssertEqual(ManagedGatewayHost.directoryAttentionCause(["causes":[cause]]), cause)
        }
        XCTAssertNil(ManagedGatewayHost.directoryAttentionCause(["causes":["private_directory_permissions"]]))
        XCTAssertNil(ManagedGatewayHost.directoryAttentionCause(["causes":["installation"]]))
    }

    func testFakeGatewayHasOneOwnerAndDrainsAfterLastClient() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true, attributes:[.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at:root) }
        let cli = root.appendingPathComponent("openclaw")
        let script = """
        #!/bin/sh
        case "$1" in
          config) exit 0 ;;
          health) printf '{"ok":true}\\n'; exit 0 ;;
          gateway) printf 'launch\\n' >> "\(root.appendingPathComponent("launches").path)"; /bin/sleep 60 & wait ;;
        esac
        """
        try script.write(to:cli,atomically:true,encoding:.utf8)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:cli.path)
        let url = root.appendingPathComponent("runtime.json")
        let port = (30000..<40000).first(where:ManagedGatewayHost.portAvailable)!
        let value: [String:Any] = ["version":1,"instance_id":UUID().uuidString.lowercased(),
            "installation_fingerprint":"fixture","configuration_fingerprint":"fixture",
            "executable":cli.path,"node":cli.path,"entry":cli.path,"state":root.path+"/state",
            "config":root.path+"/config","workspace":root.path+"/workspace","token_file":root.path+"/token",
            "port":port,"endpoint":"ws://127.0.0.1:\(port)","openclaw_version":"fixture","node_version":"fixture"]
        try JSONSerialization.data(withJSONObject:value).write(to:url)
        let client = try ManagedGatewayHost.registerClient(root:root)
        let runtime = root.appendingPathComponent("runtime")
        try "#!/bin/sh\nprintf '{\"ok\":true}\\n'\n".write(to:runtime,atomically:true,encoding:.utf8)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:runtime.path)
        let ended = expectation(description:"Gateway descendants drained")
        DispatchQueue.global().async {
            XCTAssertEqual(ManagedGatewayHost.run(descriptorURL:url,runtimeURL:runtime),0)
            ended.fulfill()
        }
        let limit = ProcessInfo.processInfo.systemUptime + 5
        var healthy = false
        while !healthy && ProcessInfo.processInfo.systemUptime < limit {
            if let data = try? Data(contentsOf:root.appendingPathComponent("health.json")),
               let health = try? JSONSerialization.jsonObject(with:data) as? [String:Any] {
                healthy = health["state"] as? String == "healthy"
            }
            Thread.sleep(forTimeInterval:0.02)
        }
        XCTAssertTrue(healthy)
        XCTAssertEqual(ManagedGatewayHost.run(descriptorURL:url,runtimeURL:runtime),0)
        XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("launches"),encoding:.utf8).split(separator:"\n").count,1)
        // Supported offline configuration updates must drain the owned tree,
        // exclude native delivery, and resume only after the requester releases.
        let request = root.appendingPathComponent("configuration-request.json")
        let id = UUID().uuidString
        let owner = try JSONSerialization.jsonObject(with:JSONEncoder().encode(ManagedProcessIdentity.read(getpid())!))
        try JSONSerialization.data(withJSONObject:["request_id":id,"owner":owner]).write(to:request,options:.atomic)
        let acknowledged = root.appendingPathComponent("configuration-ack.json")
        let drainDeadline = ProcessInfo.processInfo.systemUptime + 5
        while !FileManager.default.fileExists(atPath:acknowledged.path) && ProcessInfo.processInfo.systemUptime < drainDeadline {
            Thread.sleep(forTimeInterval:0.02)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath:acknowledged.path))
        XCTAssertThrowsError(try ManagedRuntimePermit(root:root,repairing:false,requireHealth:false))
        try FileManager.default.removeItem(at:request)
        try FileManager.default.removeItem(at:client)
        wait(for:[ended],timeout:5)
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("gateway-processes.json").path))
    }

    func testOwnershipJournalPrecedesReleaseAndFailurePreventsEffects() throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:marker) }
        let process = SubprocessSupervisor()
        process.executableURL = URL(fileURLWithPath:"/usr/bin/touch")
        process.arguments = [marker.path]
        process.onLaunchAcknowledged = { identity in
            XCTAssertFalse(FileManager.default.fileExists(atPath:marker.path))
            XCTAssertEqual(identity.pid,identity.group)
            throw ManagedOpenClawError.command("Injected journal failure")
        }
        XCTAssertThrowsError(try process.run())
        XCTAssertTrue(process.snapshot.treeFinished)
        XCTAssertFalse(FileManager.default.fileExists(atPath:marker.path))
        process.markOutputDrained()
    }

}
