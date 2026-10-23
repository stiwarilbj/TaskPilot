import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import OrbitAgent

final class TaskResultShelfTests: XCTestCase {
    private let identity = String(repeating: "a", count: 64)

    private func file(_ kind: AgentTaskResultKind = .file, state: AgentTaskResultState = .verified,
                      path: String = "/tmp/report.pdf") -> AgentTaskResultObject {
        AgentTaskResultObject(id: AgentTaskResultObject.resultID(kind: kind, target: path), kind: kind,
                              state: state, name: URL(fileURLWithPath: path).lastPathComponent,
                              location: URL(fileURLWithPath: path).deletingLastPathComponent().path,
                              path: path, url: nil, fileIdentity: identity, fileVersion: identity,
                              parentIdentity: identity)
    }

    private func row(_ item: AgentTaskResultObject) -> [String: Any] {
        var value: [String: Any] = ["id": item.id, "kind": item.kind.rawValue,
                                    "state": item.state.rawValue, "name": item.name,
                                    "location": item.location]
        if let path = item.path { value["path"] = path }
        if let url = item.url { value["url"] = url; value["hostname"] = item.location }
        if let fileIdentity = item.fileIdentity { value["file_identity"] = fileIdentity }
        if let fileVersion = item.fileVersion { value["file_version"] = fileVersion }
        if let parentIdentity = item.parentIdentity { value["parent_identity"] = parentIdentity }
        return value
    }

    func testParsesDeduplicatedTypedFileFolderAndWebResults() throws {
        let file = file()
        let folderPath = "/tmp/Reports"
        let folder = AgentTaskResultObject(id: AgentTaskResultObject.resultID(kind: .folder, target: folderPath),
                                           kind: .folder, state: .verified, name: "Reports", location: "/tmp",
                                           path: folderPath, url: nil, fileIdentity: identity,
                                           fileVersion: identity, parentIdentity: identity)
        let webURL = "https://example.com/reports"
        let web = AgentTaskResultObject(id: AgentTaskResultObject.resultID(kind: .web, target: webURL),
                                        kind: .web, state: .verified, name: "Report page", location: "example.com",
                                        path: nil, url: webURL, fileIdentity: nil,
                                        fileVersion: nil, parentIdentity: nil)
        let parsed = try XCTUnwrap(AgentTaskResultObject.parseList([row(file), row(folder), row(web)]))
        XCTAssertEqual(parsed, [file, folder, web])
        XCTAssertNil(AgentTaskResultObject.parseList([row(file), row(file)]))
    }

    func testRejectsInventedPathsMalformedMetadataAndUnsafeWebDestinations() throws {
        let valid = file()
        var invalidPath = row(valid)
        invalidPath["path"] = "relative/report.pdf"
        XCTAssertNil(AgentTaskResultObject.parseList([invalidPath]))

        var invalidIdentity = row(valid)
        invalidIdentity["file_identity"] = "not-an-identity"
        XCTAssertNil(AgentTaskResultObject.parseList([invalidIdentity]))

        let unsafe = ["file:///tmp/report.pdf", "javascript:alert(1)", "https://user:secret@example.com/"]
        for url in unsafe {
            let website: [String: Any] = [
                "id": AgentTaskResultObject.resultID(kind: .web, target: url),
                "kind": "web", "state": "verified", "name": "Example",
                "location": "example.com", "hostname": "example.com", "url": url,
            ]
            XCTAssertNil(AgentTaskResultObject.parseList([website]), url)
        }

        var stale = row(valid)
        stale["state"] = "verified"
        stale["id"] = AgentTaskResultObject.resultID(kind: .file, target: "/tmp/other.pdf")
        XCTAssertNil(AgentTaskResultObject.parseList([stale]))
        XCTAssertNil(AgentTaskResultObject.parseList("not an array"))
    }

    @MainActor
    func testCardsExposeOnlyRelevantExplicitActionsAndUseInjectedHandlers() {
        let file = file()
        let folderPath = "/tmp/Reports"
        let folder = AgentTaskResultObject(id: AgentTaskResultObject.resultID(kind: .folder, target: folderPath),
                                           kind: .folder, state: .needsRecheck, name: "Reports", location: "/tmp",
                                           path: folderPath, url: nil, fileIdentity: nil,
                                           fileVersion: nil, parentIdentity: nil)
        let url = "https://example.com/"
        let web = AgentTaskResultObject(id: AgentTaskResultObject.resultID(kind: .web, target: url),
                                        kind: .web, state: .verified, name: "Example", location: "example.com",
                                        path: nil, url: url, fileIdentity: nil,
                                        fileVersion: nil, parentIdentity: nil)
        XCTAssertEqual(TaskResultShelfAction.available(for: file), [.quickLook, .reveal, .copyPath])
        XCTAssertEqual(TaskResultShelfAction.available(for: folder), [.openFolder, .reveal, .copyPath])
        XCTAssertEqual(TaskResultShelfAction.available(for: web), [.openWebsite])

        var delivered: [(TaskResultShelfAction, String)] = []
        let dispatcher = TaskResultShelfDispatcher { action, item in
            delivered.append((action, item.id))
            return .completed
        }
        for action in TaskResultShelfAction.available(for: file) { _ = dispatcher.perform(action, for: file) }
        for action in TaskResultShelfAction.available(for: folder) { _ = dispatcher.perform(action, for: folder) }
        for action in TaskResultShelfAction.available(for: web) { _ = dispatcher.perform(action, for: web) }
        XCTAssertEqual(delivered.map(\.0), [.quickLook, .reveal, .copyPath, .openFolder, .reveal, .copyPath, .openWebsite])
        XCTAssertEqual(delivered.count, 7)
    }

    func testLocalActionsRejectReplacementAndReturnQuickLookTargetWithoutOpeningIt() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("taskpilot-result-\(UUID().uuidString).txt")
        try Data("Verified result".utf8).write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }

        let noIdentity = AgentTaskResultObject(id: AgentTaskResultObject.resultID(kind: .file, target: path.path),
                                               kind: .file, state: .verified, name: path.lastPathComponent,
                                               location: path.deletingLastPathComponent().path, path: path.path,
                                               url: nil, fileIdentity: nil, fileVersion: nil, parentIdentity: nil)
        let result = await TaskResultShelfActionService.perform(.quickLook, for: noIdentity)
        XCTAssertEqual(result, .preview(path))

        let missingPath = path.deletingLastPathComponent().appendingPathComponent("missing-\(UUID().uuidString)")
        let missing = AgentTaskResultObject(id: AgentTaskResultObject.resultID(kind: .file, target: missingPath.path),
                                            kind: .file, state: .verified, name: missingPath.lastPathComponent,
                                            location: missingPath.deletingLastPathComponent().path,
                                            path: missingPath.path, url: nil, fileIdentity: nil,
                                            fileVersion: nil, parentIdentity: nil)
        guard case .unavailable = await TaskResultShelfActionService.perform(.quickLook, for: missing) else {
            return XCTFail("A missing result must not be previewed")
        }

        let replaced = AgentTaskResultObject(id: noIdentity.id, kind: .file, state: .verified,
                                             name: noIdentity.name, location: noIdentity.location,
                                             path: noIdentity.path, url: nil, fileIdentity: identity,
                                             fileVersion: identity, parentIdentity: nil)
        guard case .unavailable = await TaskResultShelfActionService.perform(.quickLook, for: replaced) else {
            return XCTFail("A replacement must not be previewed")
        }
    }

    @MainActor
    func testUnavailableQuickLookShowsAnInlineAccessibleExplanation() {
        let view = TaskResultQuickLookView.previewView(for: URL(fileURLWithPath: "/tmp/report.pdf")) { _, _ in nil }
        let message = view as? NSTextField
        XCTAssertEqual(message?.stringValue, "Quick Look preview is unavailable for this result.")
        XCTAssertEqual(message?.accessibilityLabel(), message?.stringValue)
    }

    @MainActor
    func testRendersMixedShelfInNarrowWindowFixture() throws {
        let file = file()
        let url = "https://example.com/"
        let web = AgentTaskResultObject(id: AgentTaskResultObject.resultID(kind: .web, target: url),
                                        kind: .web, state: .verified, name: "A long example result page title",
                                        location: "example.com", path: nil, url: url,
                                        fileIdentity: nil, fileVersion: nil, parentIdentity: nil)
        let view = TaskResultShelfView(results: [file, web], surface: Color(nsColor: .windowBackgroundColor),
                                       border: Color(nsColor: .separatorColor), accent: .blue)
            .frame(width: 320, height: 190, alignment: .topLeading)
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(x: 0, y: 0, width: 320, height: 190)
        hostingView.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 1_000)
        try png.write(to: URL(fileURLWithPath: "/tmp/taskpilot-result-shelf-mixed.png"))
    }
}
