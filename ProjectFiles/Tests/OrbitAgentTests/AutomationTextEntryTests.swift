import XCTest
@testable import OrbitAgent

final class AutomationTextEntryTests: XCTestCase {
    private final class Field {
        var value: String? = ""
        var selection: NSRange? = NSRange(location: 0, length: 0)
        var focusAllowed = true
        var focused = false
        var direct: TextAttributeDelivery = .accepted
        var selected: TextAttributeDelivery = .unsupported
        var selectsAll = true
        var ignoreDirect = false
        var pending: String?
        var delayed = false
        var reads = 0
        var valueWrites = 0
        var selectionWrites = 0
        var keyWrites = 0
        var polls = 0
        var cancelReadback = false

        func enter(_ text: String, replacement: Bool = false, secure: Bool = false) async throws -> AutomationTextEntryResult {
            try await AutomationTextEntryPolicy.enter(text: text, replacement: replacement, secure: secure,
                focus: {
                    guard self.focusAllowed else { throw AccessibilityActionError.focusMismatch }
                    self.focused = true
                }, preflight: {
                    guard self.focused else { throw AccessibilityActionError.focusMismatch }
                }, readValue: { self.reads += 1; return self.value }, readSelection: { self.selection },
                setValue: { requested in
                    guard self.direct != .unsupported else { return .unsupported }
                    self.valueWrites += 1
                    if !self.ignoreDirect {
                        if self.delayed { self.pending = requested }
                        else { self.value = requested }
                    }
                    return self.direct
                }, setSelectedText: { text in
                    guard self.selected != .unsupported else { return .unsupported }
                    self.selectionWrites += 1
                    self.value = AutomationTextEntryPolicy.inserting(text, into: self.value, selection: self.selection)
                    return self.selected
                }, selectRange: { range in
                    guard self.selectsAll else { return false }
                    self.selection = range
                    return true
                }, typeText: { text, preflight in
                    try preflight()
                    self.keyWrites += 1
                    self.value = AutomationTextEntryPolicy.inserting(text, into: self.value, selection: self.selection)
                }, waitForMatch: { matches in
                    for _ in 0..<4 {
                        if self.cancelReadback { throw AccessibilityActionError.cancelled }
                        if matches() { return }
                        self.polls += 1
                        if self.polls == 2, let pending = self.pending { self.value = pending }
                    }
                })
        }
    }

    func testFocusMustBeConfirmedBeforeAnyTextDelivery() async {
        let field = Field()
        field.focusAllowed = false
        do { _ = try await field.enter("hello"); XCTFail("Unfocused input must be rejected") }
        catch { XCTAssertEqual((error as? AccessibilityActionError)?.code, "focus_mismatch") }
        XCTAssertEqual(field.valueWrites + field.selectionWrites + field.keyWrites, 0)
    }

    func testSelectedTextEntryPreservesInsertionAndSelection() async throws {
        let field = Field()
        field.selected = .accepted
        field.value = "hello old world"
        field.selection = NSRange(location: 6, length: 3)
        let result = try await field.enter("new")
        XCTAssertEqual(field.value, "hello new world")
        XCTAssertEqual(result.method, "accessibility_selected_text")
        XCTAssertTrue(result.verified)
        XCTAssertEqual(field.valueWrites, 0)
        XCTAssertEqual(field.selectionWrites, 1)
        XCTAssertEqual(field.keyWrites, 0)
    }

    func testReplacementIsIdempotentAndDoesNotDuplicateText() async throws {
        let field = Field()
        field.value = "existing"
        let result = try await field.enter("existing", replacement: true)
        XCTAssertTrue(result.verified)
        XCTAssertEqual(result.verification, "already_matched")
        XCTAssertEqual(field.valueWrites + field.selectionWrites + field.keyWrites, 0)
    }

    func testUnsupportedValueUsesSelectedTextExactlyOnce() async throws {
        let field = Field()
        field.direct = .unsupported
        field.selected = .accepted
        let result = try await field.enter("hello", replacement: true)
        XCTAssertTrue(result.verified)
        XCTAssertEqual(result.method, "accessibility_selected_text")
        XCTAssertEqual(field.selectionWrites, 1)
        XCTAssertEqual(field.keyWrites, 0)
    }

    func testUnicodeFallbackKeepsExistingPrefix() async throws {
        let field = Field()
        field.direct = .unsupported
        field.value = "first "
        field.selection = NSRange(location: 6, length: 0)
        let result = try await field.enter("second")
        XCTAssertTrue(result.verified)
        XCTAssertEqual(field.value, "first second")
        XCTAssertEqual(field.keyWrites, 1)
    }

    func testKeyboardReplacementRequiresAcknowledgedWholeFieldSelection() async throws {
        let field = Field()
        field.direct = .unsupported
        field.value = "old value"
        let result = try await field.enter("new", replacement: true)
        XCTAssertTrue(result.verified)
        XCTAssertEqual(field.value, "new")
        let rejected = Field()
        rejected.direct = .unsupported
        rejected.selectsAll = false
        do { _ = try await rejected.enter("new", replacement: true); XCTFail("Unselected replacement must fail") }
        catch { XCTAssertEqual((error as? AccessibilityActionError)?.code, "delivery_rejected") }
        XCTAssertEqual(rejected.keyWrites, 0)
    }

    func testEmptyReplacementClearsInsteadOfAppending() async throws {
        let field = Field()
        field.direct = .unsupported
        field.value = "remove this"
        let result = try await field.enter("", replacement: true)
        XCTAssertTrue(result.verified)
        XCTAssertEqual(field.value, "")
        XCTAssertEqual(field.keyWrites, 1)
    }

    func testIgnoredOrPartialEntryIsUnconfirmedAndNeverReplayed() async throws {
        for status in [TextAttributeDelivery.accepted, .uncertain] {
            for actual in ["", "hel", "hellohello"] {
                let field = Field()
                field.value = actual
                field.ignoreDirect = true
                field.direct = status
                let result = try await field.enter("hello", replacement: true)
                XCTAssertEqual(result.verification, "mismatch")
                XCTAssertFalse(result.verified)
                XCTAssertEqual(field.valueWrites, 1)
                XCTAssertEqual(field.selectionWrites + field.keyWrites, 0)
            }
        }
    }

    func testAmbiguousDeliveryCanBeProvenByReadbackWithoutRetry() async throws {
        let field = Field()
        field.direct = .uncertain
        let result = try await field.enter("hello", replacement: true)
        XCTAssertTrue(result.verified)
        XCTAssertEqual(field.valueWrites, 1)
        XCTAssertEqual(field.keyWrites, 0)
    }

    func testDelayedValueWaitsLocallyAndDoesNotDeliverAgain() async throws {
        let field = Field()
        field.delayed = true
        let result = try await field.enter("hello", replacement: true)
        XCTAssertTrue(result.verified)
        XCTAssertEqual(field.polls, 2)
        XCTAssertEqual(field.valueWrites, 1)
        XCTAssertEqual(field.keyWrites, 0)
    }

    func testUnreadableValueDoesNotClaimVerifiedEntry() async throws {
        let field = Field()
        field.value = nil
        field.selection = nil
        let result = try await field.enter("hello")
        XCTAssertEqual(result.verification, "unavailable")
        XCTAssertFalse(result.verified)
        XCTAssertEqual(field.keyWrites, 1)
    }

    func testSecureEntryNeverReadsValueOrReturnsTheSecret() async throws {
        let field = Field()
        let secret = "private credential"
        let result = try await field.enter(secret, secure: true)
        XCTAssertEqual(field.reads, 0)
        XCTAssertFalse(result.verified)
        XCTAssertFalse(String(describing: result.dictionary(pid: 42)).contains(secret))
        XCTAssertTrue(AutomationTextEntryPolicy.isSecure(role: "AXTextField", subrole: "AXSecureTextField"))
    }

    func testInvalidOrUnknownSelectionNeverGuessesInsertionPosition() {
        XCTAssertNil(AutomationTextEntryPolicy.inserting("x", into: "hello", selection: nil))
        for range in [NSRange(location: NSNotFound, length: 0), NSRange(location: 2, length: Int.max),
                      NSRange(location: -1, length: 0), NSRange(location: 0, length: -1),
                      NSRange(location: 99, length: 0), NSRange(location: 1, length: 0)] {
            XCTAssertNil(AutomationTextEntryPolicy.inserting("x", into: "😀abc", selection: range))
        }
        XCTAssertEqual(AutomationTextEntryPolicy.inserting("X", into: "😀abc", selection: NSRange(location: 2, length: 1)), "😀Xbc")
    }

    func testBrowserAddressCheckRejectsPageFormsAndUnidentifiedInputs() {
        XCTAssertTrue(AutomationTextEntryPolicy.isBrowserAddressField(label: "Address and Search", ancestorRoles: ["AXGroup", "AXToolbar", "AXWindow"]))
        XCTAssertFalse(AutomationTextEntryPolicy.isBrowserAddressField(label: "Street address", ancestorRoles: ["AXGroup", "AXWebArea", "AXToolbar", "AXWindow"]))
        XCTAssertFalse(AutomationTextEntryPolicy.isBrowserAddressField(label: "Search", ancestorRoles: ["AXToolbar", "AXWindow"]))
        XCTAssertFalse(AutomationTextEntryPolicy.isBrowserAddressField(label: "Address", ancestorRoles: ["AXGroup", "AXWindow"]))
    }

    func testFocusLossDuringChunkedEntryStopsRemainingChunks() throws {
        var focused = true
        var delivered: [String] = []
        XCTAssertThrowsError(try AutomationTextEntryPolicy.deliverChunks(["first", "second", "third"], preflight: {
            guard focused else { throw AccessibilityActionError.focusMismatch }
        }, cancelled: { false }, deliver: { text in
            delivered.append(text)
            focused = false
        })) { error in XCTAssertEqual((error as? AccessibilityActionError)?.code, "delivery_uncertain") }
        XCTAssertEqual(delivered, ["first"])
    }

    func testFocusLossBeforeFirstChunkDoesNotDeliver() {
        var deliveries = 0
        XCTAssertThrowsError(try AutomationTextEntryPolicy.deliverChunks(["hello"], preflight: {
            throw AccessibilityActionError.focusMismatch
        }, cancelled: { false }, deliver: { _ in deliveries += 1 })) { error in
            XCTAssertEqual((error as? AccessibilityActionError)?.code, "focus_mismatch")
        }
        XCTAssertEqual(deliveries, 0)
    }

    func testCancellationDuringChunksStopsWithoutReplay() {
        var cancelled = false
        var deliveries = 0
        XCTAssertThrowsError(try AutomationTextEntryPolicy.deliverChunks(["first", "second"], preflight: {
            if cancelled { throw AccessibilityActionError.cancelled }
        }, cancelled: { cancelled }, deliver: { _ in
            deliveries += 1
            cancelled = true
        })) { error in XCTAssertEqual((error as? AccessibilityActionError)?.code, "cancelled") }
        XCTAssertEqual(deliveries, 1)
    }

    func testCancellationDuringReadbackNeverReplaysEntry() async {
        let field = Field()
        field.cancelReadback = true
        do { _ = try await field.enter("hello", replacement: true); XCTFail("Cancellation should propagate") }
        catch { XCTAssertEqual((error as? AccessibilityActionError)?.code, "cancelled") }
        XCTAssertEqual(field.valueWrites, 1)
        XCTAssertEqual(field.keyWrites, 0)
    }
}
