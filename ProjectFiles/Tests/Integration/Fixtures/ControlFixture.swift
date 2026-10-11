import AppKit
import Foundation

final class DoubleTarget: NSView {
    var onDouble: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Double target")
        wantsLayer = true
        layer?.backgroundColor = NSColor.systemBlue.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDouble?() }
    }
    override func accessibilityPerformPress() -> Bool { false }
}

final class IgnoredTarget: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Ignored target")
    }
    required init?(coder: NSCoder) { fatalError() }
    override func accessibilityPerformPress() -> Bool { true }
}

final class FixtureDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var entry: NSTextField!
    var label: NSTextField!
    var clicks = 0, doubles = 0, menus = 0, wrong = 0
    var scroll: NSScrollView!
    let stateURL: URL
    init(stateURL: URL) { self.stateURL = stateURL }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Fixture app")
        appMenu.addItem(withTitle: "Quit Fixture", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let fixtureMenu = NSMenu(title: "Fixture")
        let increment = NSMenuItem(title: "Increment menu", action: #selector(incrementMenu), keyEquivalent: "")
        increment.target = self
        fixtureMenu.addItem(increment)
        let fixtureItem = NSMenuItem(title: "Fixture", action: nil, keyEquivalent: "")
        fixtureItem.submenu = fixtureMenu
        menu.addItem(fixtureItem)
        NSApp.mainMenu = menu

        window = NSWindow(contentRect: NSRect(x: 50, y: 70, width: 600, height: 550),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "TaskPilot Control Fixture"
        let content = window.contentView!
        let button = NSButton(title: "Increment", target: self, action: #selector(incrementButton))
        button.frame = NSRect(x: 30, y: 460, width: 180, height: 40)
        content.addSubview(button)
        let disabled = NSButton(title: "Disabled target", target: self, action: #selector(wrongButton))
        disabled.frame = NSRect(x: 240, y: 460, width: 180, height: 40)
        disabled.isEnabled = false
        content.addSubview(disabled)
        let doubleTarget = DoubleTarget(frame: NSRect(x: 30, y: 400, width: 180, height: 40))
        doubleTarget.onDouble = { [weak self] in self?.doubles += 1; self?.persist() }
        content.addSubview(doubleTarget)
        content.addSubview(IgnoredTarget(frame: NSRect(x: 250, y: 400, width: 150, height: 40)))
        entry = NSTextField(frame: NSRect(x: 30, y: 340, width: 350, height: 30))
        entry.setAccessibilityLabel("Entry field")
        content.addSubview(entry)
        label = NSTextField(labelWithString: "Counters: 0")
        label.frame = NSRect(x: 30, y: 300, width: 480, height: 30)
        content.addSubview(label)
        scroll = NSScrollView(frame: NSRect(x: 30, y: 20, width: 500, height: 260))
        scroll.hasVerticalScroller = true
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 1600))
        for index in 0..<35 {
            let row = NSTextField(labelWithString: "Fixture row \(index)")
            row.frame = NSRect(x: 20, y: index * 42, width: 300, height: 30)
            document.addSubview(row)
        }
        scroll.documentView = document
        scroll.setAccessibilityLabel("Fixture scroll area")
        content.addSubview(scroll)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.persist() }
        persist()
    }

    @objc func incrementButton() { clicks += 1; persist() }
    @objc func incrementMenu() { menus += 1; persist() }
    @objc func wrongButton() { wrong += 1; persist() }

    func persist() {
        guard entry != nil else { return }
        label.stringValue = "Counters: clicks \(clicks), doubles \(doubles), menus \(menus)"
        let state: [String: Any] = ["pid": getpid(), "clicks": clicks, "doubles": doubles,
                                   "menus": menus, "wrong": wrong, "text": entry.stringValue,
                                   "scroll_y": scroll.contentView.bounds.origin.y]
        if let data = try? JSONSerialization.data(withJSONObject: state) {
            try? data.write(to: stateURL, options: .atomic)
        }
    }
}

@main enum ControlFixture {
    static func main() {
        guard CommandLine.arguments.count > 1 else { return }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = FixtureDelegate(stateURL: URL(fileURLWithPath: CommandLine.arguments[1]))
        app.delegate = delegate
        app.run()
    }
}
