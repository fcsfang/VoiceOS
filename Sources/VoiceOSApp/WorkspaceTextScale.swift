import SwiftUI

/// App-wide reading size. `标准` is slightly larger than the pre-setting fixed
/// sizes because the old scale read small on a desktop display.
enum AppTextSize: String, CaseIterable, Identifiable {
    case small, standard, large, xlarge
    var id: String { rawValue }
    var label: String {
        switch self {
        case .small: "小"
        case .standard: "标准"
        case .large: "大"
        case .xlarge: "特大"
        }
    }
    var scale: CGFloat {
        switch self {
        case .small: 1.0
        case .standard: 1.12
        case .large: 1.28
        case .xlarge: 1.45
        }
    }
    var dynamicType: DynamicTypeSize {
        switch self {
        case .small: .large
        case .standard: .xLarge
        case .large: .xxLarge
        case .xlarge: .xxxLarge
        }
    }
}

private struct VOSTextScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = AppTextSize.standard.scale
}

extension EnvironmentValues {
    var vosTextScale: CGFloat {
        get { self[VOSTextScaleKey.self] }
        set { self[VOSTextScaleKey.self] = newValue }
    }
}

private struct VOSFontModifier: ViewModifier {
    @Environment(\.vosTextScale) private var scale
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design
    let digits: Bool
    func body(content: Content) -> some View {
        let font = Font.system(size: size * scale, weight: weight, design: design)
        content.font(digits ? font.monospacedDigit() : font)
    }
}

extension View {
    func vosFont(_ size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default, monospacedDigit: Bool = false) -> some View {
        modifier(VOSFontModifier(size: size, weight: weight, design: design, digits: monospacedDigit))
    }
}
