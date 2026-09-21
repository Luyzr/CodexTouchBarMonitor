import AppKit

@MainActor enum MonitorTheme {
    static var name: String { UserDefaults.standard.string(forKey: "MonitorTheme") ?? "dark" }
    static var appearance: NSAppearance? {
        switch name {
        case "light": return NSAppearance(named: .aqua)
        case "system": return nil
        case "custom": return NSAppearance(named: foreground == .black ? .aqua : .darkAqua)
        default: return NSAppearance(named: .darkAqua)
        }
    }
    static func color(_ hex: String?) -> NSColor? {
        guard let hex, hex.count == 7, hex.first == "#", let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
    }
    static var background: NSColor {
        switch name {
        case "light", "system": return .windowBackgroundColor
        case "custom": return color(UserDefaults.standard.string(forKey: "ThemeBackground")) ?? NSColor(calibratedWhite: 0.12, alpha: 1)
        default: return NSColor(calibratedWhite: 0.12, alpha: 1)
        }
    }
    static var foreground: NSColor {
        if name == "light" || name == "system" { return .labelColor }
        guard name == "custom", let rgb = background.usingColorSpace(.sRGB) else { return .white }
        func linear(_ value: CGFloat) -> CGFloat { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
        return luminance > 0.179 ? .black : .white
    }
    static var accent: NSColor {
        name == "custom" ? (color(UserDefaults.standard.string(forKey: "ThemeAccent")) ?? .systemBlue) : .controlAccentColor
    }
}

@MainActor final class AttentionFeedback {
    var output: ((Bool, Bool) -> Void)?
    private var lastDelivery = Date.distantPast
    func play(preview: Bool = false) {
        let sound = UserDefaults.standard.bool(forKey: "SoundFeedback")
        let haptic = UserDefaults.standard.bool(forKey: "HapticFeedback")
        guard sound || haptic, preview || Date().timeIntervalSince(lastDelivery) >= 2 else { return }
        lastDelivery = Date()
        if let output { output(sound, haptic); return }
        if sound { NSSound(named: "Ping")?.play() }
        if haptic { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
    }
}
