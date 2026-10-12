import XCTest
import CoreGraphics
@testable import OrbitAgent

final class ActionContractTests: XCTestCase {
    private var corpusURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/action-contract-cases.json")
    }
    func testSharedCorpusAndDefaults() throws {
        let corpus = try JSONSerialization.jsonObject(with: Data(contentsOf: corpusURL)) as! [String: Any]
        for entry in corpus["cases"] as! [[String: Any]] {
            let name = entry["name"] as! String
            var action = entry["action"] as! [String: Any]
            if let repetition = entry["repeat"] as? [String: Any] {
                action[repetition["field"] as! String] = String(repeating: repetition["text"] as! String, count: repetition["count"] as! Int)
            }
            if let special = entry["special"] as? [String: Any] { action[special["field"] as! String] = Double.infinity }
            do {
                let validated = try ActionContract.validate(action)
                XCTAssertNil(entry["error"], name)
                if let expected = entry["normalized"] as? [String: Any] {
                    XCTAssertEqual(validated as NSDictionary, expected as NSDictionary, name)
                    XCTAssertEqual(try ActionContract.validate(validated) as NSDictionary, validated as NSDictionary, name)
                }
            } catch {
                XCTAssertEqual(error.localizedDescription, entry["error"] as? String, name)
            }
        }
        for (name, fields) in corpus["defaults"] as! [String: [String: Any]] {
            for (field, value) in fields {
                XCTAssertEqual(["value": ActionContract.defaultValue(ActionKind(rawValue: name)!, field)] as NSDictionary,
                               ["value": value] as NSDictionary)
            }
        }
    }
    func testEveryDeclaredActionAndCheckHasAnExhaustiveDispatchKind() {
        XCTAssertEqual(Set(ActionKind.allCases.map(\.rawValue)), Set((ActionContract.definition["actions"] as! [String: Any]).keys))
        let fields = ActionContract.definition["fields"] as! [String: [String: Any]]
        let items = fields["checks"]!["items"] as! [String: Any]
        XCTAssertEqual(Set(OutcomeCheckKind.allCases.map(\.rawValue)), Set((items["variants"] as! [String: Any]).keys))
        XCTAssertEqual(Set(ActionKind.allCases.filter { $0.owner == .runtime }.map(\.rawValue)), ["none", "wait"])
        XCTAssertEqual(TaskToolExecutor.supportedActions, ["read_file", "write_file", "run_command"])
        XCTAssertEqual(Set(ActionContract.keyCodes.keys), Set(fields["key"]!["choices"] as! [String]))
        XCTAssertEqual(ActionContract.modifierAliases["cmd"], "command")
        XCTAssertEqual(ActionContract.modifierAliases["alt"], "option")
        XCTAssertEqual(ActionContract.modifierFlags["command"], CGEventFlags.maskCommand.rawValue)
        XCTAssertEqual(ActionContract.modifierFlags["shift"], CGEventFlags.maskShift.rawValue)
        XCTAssertEqual(ActionContract.modifierFlags["option"], CGEventFlags.maskAlternate.rawValue)
        XCTAssertEqual(ActionContract.modifierFlags["control"], CGEventFlags.maskControl.rawValue)
    }
    func testInvalidPayloadCannotWriteOrLaunchCommand() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let executor = TaskToolExecutor()
        let actions: [[String: Any]] = [
            ["type": "write_file", "path": marker.path, "content": "unexpected", "create_parents": 1],
            ["type": "run_command", "argv": ["/usr/bin/touch", marker.path], "timeout_seconds": true],
            ["type": "write_file", "path": marker.path, "content": ["input_ref": "unresolved"]],
            ["type": "run_command", "argv": ["/usr/bin/touch", ["input_ref": "unresolved"]]]
        ]
        for action in actions {
            do { _ = try await executor.perform(action: action); XCTFail("Invalid payload executed") }
            catch let error as TaskToolError { XCTAssertEqual(error.code, "invalid_action") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }
    func testMalformedDesktopActionsRejectBeforeActivationOrPermissionChecks() async {
        let controller = AccessibilityController()
        let display = DisplayDescriptor(id: 1, name: "fixture", x: 0, y: 0, width: 10, height: 10, isMain: true)
        let actions: [[String: Any]] = [
            ["type": "click", "pid": 42, "x": true, "y": 2],
            ["type": "press"], ["type": "scroll", "delta_y": 0], ["type": "wait", "seconds": 1],
            ["type": "set_value", "element_id": "fixture:field", "text": ["input_ref": "unresolved"]]
        ]
        for action in actions {
            do { _ = try await controller.performStructured(action: action, on: display); XCTFail("Invalid action reached desktop delivery") }
            catch { XCTAssertEqual((error as? AccessibilityActionError)?.code, "invalid_action") }
        }
    }
    func testStartupConfigurationUsesCompiledContractFingerprint() throws {
        let value = try JSONSerialization.jsonObject(with: GeminiModelVerifier.configurationData(apiKey: "")) as! [String: Any]
        XCTAssertEqual(value["action_contract_hash"] as? String, ActionContract.fingerprint)
        XCTAssertEqual(value["action_contract_version"] as? Int, ActionContract.version)
    }
}
