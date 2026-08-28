import AppKit
import SwiftUI

enum TaskPilotAppearancePreferences {
    static let themeKey = "OrbitAgent.style.theme"
    static let inputFontSizeKey = "OrbitAgent.style.inputFontSize"
    static let outputFontSizeKey = "OrbitAgent.style.outputFontSize"
    static let animateColorsKey = "OrbitAgent.style.animateColors"
    static let customStartColorKey = "OrbitAgent.style.customStartColor"
    static let customEndColorKey = "OrbitAgent.style.customEndColor"
    static let customGradientKey = "OrbitAgent.style.customGradient"
    static let customImagePathKey = "OrbitAgent.style.customImagePath"

    static let defaultInputFontSize = 15.0
    static let defaultOutputFontSize = 16.0
    static let minimumInputFontSize = 12.0
    static let maximumInputFontSize = 30.0
    static let minimumOutputFontSize = 12.0
    static let maximumOutputFontSize = 38.0

    static func clampedInputFontSize(_ value: Double) -> Double {
        min(max(value, minimumInputFontSize), maximumInputFontSize)
    }

    static func clampedOutputFontSize(_ value: Double) -> Double {
        min(max(value, minimumOutputFontSize), maximumOutputFontSize)
    }
}

struct TaskPilotBlueSwitchStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.label
            Capsule(style: .continuous)
                .fill(configuration.isOn ? Color.blue : Color.secondary.opacity(0.28))
                .frame(width: 40, height: 23)
                .overlay {
                    Circle()
                        .fill(.white)
                        .padding(2.5)
                        .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
                        .offset(x: configuration.isOn ? 8.5 : -8.5)
                }
                .opacity(isEnabled ? 1 : 0.55)
                .animation(.easeOut(duration: 0.14), value: configuration.isOn)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard isEnabled else { return }
            configuration.isOn.toggle()
        }
    }
}

enum TaskPilotTheme: String, CaseIterable, Identifiable {
    case light = "Light"
    case dark = "Dark"
    case red = "Red"
    case blue = "Blue"
    case green = "Green"
    case aquamarine = "Aquamarine"
    case multicolored = "Multicolored"
    case gradients = "Gradients"
    case flowingColors = "Flowing Colors"
    case stream = "Stream"
    case ocean = "Ocean"
    case dinosaurs = "Dinosaurs"
    case forest = "Forest"
    case tropicalRainforest = "Tropical Rainforest"
    case grasslandsSunset = "Grasslands with Sunset"
    case custom = "Custom"

    var id: String { rawValue }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .light: .light
        case .custom: nil
        default: .dark
        }
    }

    var colors: [Color] {
        switch self {
        case .light:
            [
                Color(red: 0.945, green: 0.972, blue: 1.0),
                Color(red: 0.985, green: 0.993, blue: 1.0)
            ]
        case .dark:
            [Color(red: 0.035, green: 0.045, blue: 0.075), Color(red: 0.12, green: 0.08, blue: 0.22)]
        case .red:
            [Color(red: 0.24, green: 0.035, blue: 0.055), Color(red: 0.86, green: 0.14, blue: 0.20)]
        case .blue:
            [Color(red: 0.035, green: 0.12, blue: 0.28), Color(red: 0.16, green: 0.48, blue: 0.95)]
        case .green:
            [Color(red: 0.025, green: 0.20, blue: 0.12), Color(red: 0.20, green: 0.68, blue: 0.32)]
        case .aquamarine:
            [Color(red: 0.02, green: 0.28, blue: 0.29), Color(red: 0.27, green: 0.92, blue: 0.75)]
        case .multicolored:
            [.pink, .purple, .indigo, .cyan, .green, .yellow, .orange]
        case .gradients:
            [Color(red: 0.45, green: 0.18, blue: 0.92), Color(red: 0.96, green: 0.22, blue: 0.58), Color.orange]
        case .flowingColors:
            [.indigo, .purple, .pink, .orange, .cyan]
        case .stream:
            [Color(red: 0.03, green: 0.26, blue: 0.40), Color(red: 0.11, green: 0.62, blue: 0.74), Color(red: 0.66, green: 0.94, blue: 0.91)]
        case .ocean:
            [Color(red: 0.01, green: 0.08, blue: 0.24), Color(red: 0.02, green: 0.35, blue: 0.57), Color(red: 0.18, green: 0.78, blue: 0.83)]
        case .dinosaurs:
            [Color(red: 0.08, green: 0.20, blue: 0.08), Color(red: 0.35, green: 0.58, blue: 0.18), Color(red: 0.83, green: 0.67, blue: 0.28)]
        case .forest:
            [Color(red: 0.025, green: 0.12, blue: 0.07), Color(red: 0.08, green: 0.36, blue: 0.18), Color(red: 0.37, green: 0.58, blue: 0.26)]
        case .tropicalRainforest:
            [Color(red: 0.01, green: 0.17, blue: 0.12), Color(red: 0.05, green: 0.50, blue: 0.30), Color(red: 0.17, green: 0.76, blue: 0.63), Color(red: 0.97, green: 0.62, blue: 0.20)]
        case .grasslandsSunset:
            [Color(red: 0.30, green: 0.15, blue: 0.42), Color(red: 0.94, green: 0.34, blue: 0.23), Color(red: 0.98, green: 0.70, blue: 0.26), Color(red: 0.25, green: 0.48, blue: 0.18)]
        case .custom:
            [.indigo, .purple]
        }
    }

    var accent: Color {
        switch self {
        case .light: .blue
        case .red: .red
        case .blue, .ocean, .stream: .blue
        case .green, .forest, .dinosaurs: .green
        case .aquamarine, .tropicalRainforest: .teal
        case .grasslandsSunset: .orange
        default: .indigo
        }
    }

    var surfaceColor: Color {
        self == .light
            ? Color(red: 0.982, green: 0.991, blue: 1.0)
            : .black.opacity(0.18)
    }

    var borderColor: Color {
        self == .light ? .black.opacity(0.11) : .white.opacity(0.16)
    }

    var logoColors: [Color] {
        if self == .light {
            return [
                Color(red: 0.25, green: 0.64, blue: 0.96),
                Color(red: 0.56, green: 0.79, blue: 0.99)
            ]
        }
        return [accent, colors.last ?? accent]
    }

    var animatesByDefault: Bool {
        [.multicolored, .gradients, .flowingColors, .stream, .ocean].contains(self)
    }
}

enum TaskPilotThemeColorCodec {
    static func color(from hex: String, fallback: Color = .indigo) -> Color {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6 || value.count == 8,
              let number = UInt64(value, radix: 16) else { return fallback }

        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double
        if value.count == 8 {
            red = Double((number >> 24) & 0xff) / 255
            green = Double((number >> 16) & 0xff) / 255
            blue = Double((number >> 8) & 0xff) / 255
            alpha = Double(number & 0xff) / 255
        } else {
            red = Double((number >> 16) & 0xff) / 255
            green = Double((number >> 8) & 0xff) / 255
            blue = Double(number & 0xff) / 255
            alpha = 1
        }
        return Color(red: red, green: green, blue: blue, opacity: alpha)
    }

    static func hex(from color: Color) -> String? {
        guard let converted = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        return String(
            format: "#%02X%02X%02X%02X",
            Int(round(converted.redComponent * 255)),
            Int(round(converted.greenComponent * 255)),
            Int(round(converted.blueComponent * 255)),
            Int(round(converted.alphaComponent * 255))
        )
    }
}

struct TaskPilotThemeBackground: View {
    let preset: TaskPilotTheme
    let animateColors: Bool
    let customStartHex: String
    let customEndHex: String
    let customGradient: Bool
    let customImagePath: String

    var body: some View {
        TimelineView(.animation(minimumInterval: animateColors ? 1.0 / 30.0 : 60)) { timeline in
            GeometryReader { proxy in
                ZStack {
                    gradient(at: timeline.date)

                    if preset == .custom,
                       !customImagePath.isEmpty,
                       let image = NSImage(contentsOfFile: customImagePath) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .clipped()
                            .overlay(.black.opacity(0.16))
                    }

                    if preset == .dinosaurs {
                        Text("🦕     🦖          🦕")
                            .font(.system(size: max(34, proxy.size.width / 13)))
                            .opacity(0.13)
                            .rotationEffect(.degrees(-8))
                            .accessibilityHidden(true)
                    }
                }
            }
        }
        .ignoresSafeArea()
    }

    private func gradient(at date: Date) -> LinearGradient {
        let colors: [Color]
        if preset == .custom {
            let start = TaskPilotThemeColorCodec.color(from: customStartHex)
            let end = TaskPilotThemeColorCodec.color(from: customEndHex, fallback: .purple)
            colors = customGradient ? [start, end] : [start, start]
        } else {
            colors = preset.colors
        }

        guard animateColors else {
            return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        let phase = date.timeIntervalSinceReferenceDate * 0.23
        let start = UnitPoint(
            x: 0.5 + cos(phase) * 0.5,
            y: 0.5 + sin(phase * 0.83) * 0.5
        )
        let end = UnitPoint(x: 1 - start.x, y: 1 - start.y)
        return LinearGradient(colors: colors, startPoint: start, endPoint: end)
    }
}

struct AppearanceSettingsView: View {
    @AppStorage(TaskPilotAppearancePreferences.themeKey) private var themeRawValue = TaskPilotTheme.light.rawValue
    @AppStorage(TaskPilotAppearancePreferences.inputFontSizeKey) private var inputFontSize = TaskPilotAppearancePreferences.defaultInputFontSize
    @AppStorage(TaskPilotAppearancePreferences.outputFontSizeKey) private var outputFontSize = TaskPilotAppearancePreferences.defaultOutputFontSize
    @AppStorage(TaskPilotAppearancePreferences.animateColorsKey) private var animateColors = false
    @AppStorage(TaskPilotAppearancePreferences.customStartColorKey) private var customStartHex = "#5B5BF7FF"
    @AppStorage(TaskPilotAppearancePreferences.customEndColorKey) private var customEndHex = "#B43DF2FF"
    @AppStorage(TaskPilotAppearancePreferences.customGradientKey) private var customGradient = true
    @AppStorage(TaskPilotAppearancePreferences.customImagePathKey) private var customImagePath = ""

    private var theme: TaskPilotTheme {
        TaskPilotTheme(rawValue: themeRawValue) ?? .light
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Color theme", selection: $themeRawValue) {
                ForEach(TaskPilotTheme.allCases) { preset in
                    Text(preset.rawValue).tag(preset.rawValue)
                }
            }

            fontSizeControl(
                title: "Input text size",
                value: $inputFontSize,
                range: TaskPilotAppearancePreferences.minimumInputFontSize...TaskPilotAppearancePreferences.maximumInputFontSize
            )
            fontSizeControl(
                title: "Output text size",
                value: $outputFontSize,
                range: TaskPilotAppearancePreferences.minimumOutputFontSize...TaskPilotAppearancePreferences.maximumOutputFontSize
            )

            Toggle("Animate flowing colors", isOn: $animateColors)
                .toggleStyle(.switch)

            if theme == .custom {
                Divider()
                HStack(spacing: 18) {
                    ColorPicker("First color", selection: colorBinding(for: $customStartHex), supportsOpacity: true)
                    ColorPicker("Second color", selection: colorBinding(for: $customEndHex), supportsOpacity: true)
                }
                Toggle("Blend custom colors as a gradient", isOn: $customGradient)

                HStack {
                    Button("Choose Background Image…") { chooseCustomImage() }
                    if !customImagePath.isEmpty {
                        Text(URL(fileURLWithPath: customImagePath).lastPathComponent)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Button("Remove", role: .destructive) { customImagePath = "" }
                    }
                }
            }
        }
        .onChange(of: themeRawValue) { _, newValue in
            if let selected = TaskPilotTheme(rawValue: newValue), selected.animatesByDefault {
                animateColors = true
            }
        }
    }

    private func fontSizeControl(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        HStack {
            Text(title)
                .frame(width: 118, alignment: .leading)
            Slider(value: value, in: range, step: 1)
            Text("\(Int(value.wrappedValue)) pt")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
    }

    private func colorBinding(for value: Binding<String>) -> Binding<Color> {
        Binding(
            get: { TaskPilotThemeColorCodec.color(from: value.wrappedValue) },
            set: { color in
                if let hex = TaskPilotThemeColorCodec.hex(from: color) {
                    value.wrappedValue = hex
                }
            }
        )
    }

    private func chooseCustomImage() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Custom \(TaskPilotIdentity.displayName) Background"
        panel.prompt = "Use Image"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        customImagePath = url.path
    }
}
