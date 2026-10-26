import Darwin
import Foundation
import XCTest
@testable import OrbitAgent

final class ManagedOpenClawTests: XCTestCase {
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
    func testFakeGatewayHasOneOwnerAndDrainsAfterLastClient() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
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
