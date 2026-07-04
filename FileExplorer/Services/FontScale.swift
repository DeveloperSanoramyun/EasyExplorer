//
//  FontScale.swift
//  FileExplorer
//
//  Global text-size zoom — ⌘+ / ⌘- / ⌘0 in the View menu. Two
//  mechanisms wired together at the root:
//
//    1. `.dynamicTypeSize(...)` for semantic fonts (.caption, .body,
//       .headline, …) which SwiftUI scales natively.
//    2. `.environment(\.feFontScale, …)` for explicit-size fonts — the
//       `.feFont(size:)` modifier reads the scale and multiplies the
//       point size at render time, so every label that uses it picks
//       up the new value the moment the scale changes.
//
//  The scale lives in `@AppStorage("fe.fontScale")` so it persists
//  across launches and stays consistent across windows.
//

import SwiftUI

/// Discrete preset scales. Five steps centred on 1.0 keeps the View
/// menu compact while covering the realistic range (slightly-shrunken
/// for dense folders, up to 1.5× for high-DPI displays / accessibility).
enum FEFontScale: Double, CaseIterable, Identifiable {
    case xSmall  = 0.85
    case small   = 0.92
    case normal  = 1.00
    case large   = 1.15
    case xLarge  = 1.30
    case xxLarge = 1.50

    var id: Double { rawValue }

    var displayName: String {
        switch self {
        case .xSmall:  return "Smallest"
        case .small:   return "Small"
        case .normal:  return "Default"
        case .large:   return "Large"
        case .xLarge:  return "Larger"
        case .xxLarge: return "Largest"
        }
    }

    /// Map our scale onto SwiftUI's Dynamic Type ladder so semantic
    /// fonts (`.caption`, `.body`, …) move in lockstep with the
    /// explicit-size labels driven by `.feFont(size:)`.
    var dynamicTypeSize: DynamicTypeSize {
        switch self {
        case .xSmall:  return .xSmall
        case .small:   return .small
        case .normal:  return .large       // SwiftUI's "default"
        case .large:   return .xLarge
        case .xLarge:  return .xxLarge
        case .xxLarge: return .xxxLarge
        }
    }

    /// Next/previous step for ⌘+ / ⌘- handlers. Saturates at the ends.
    func bumped(by delta: Int) -> FEFontScale {
        let all = FEFontScale.allCases
        guard let idx = all.firstIndex(of: self) else { return .normal }
        let next = max(0, min(all.count - 1, idx + delta))
        return all[next]
    }

    /// Map a raw Double (as stored in @AppStorage) to a discrete case.
    /// Tolerates floating-point drift so 1.0000001 still resolves to
    /// `.normal`.
    static func from(raw: Double) -> FEFontScale {
        allCases.min(by: { abs($0.rawValue - raw) < abs($1.rawValue - raw) }) ?? .normal
    }
}

private struct FEFontScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1.0
}

extension EnvironmentValues {
    /// Multiplier applied by `.feFont(size:)`. Set on the root view
    /// from the @AppStorage value — defaults to 1.0 (no scaling).
    var feFontScale: CGFloat {
        get { self[FEFontScaleKey.self] }
        set { self[FEFontScaleKey.self] = newValue }
    }
}

private struct FEScaledFontModifier: ViewModifier {
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design
    @Environment(\.feFontScale) private var scale

    func body(content: Content) -> some View {
        // NB: `.font(.system(...))` directly — using `.feFont` here
        // would recurse infinitely.
        content.font(.system(size: size * scale, weight: weight, design: design))
    }
}

extension View {
    /// Drop-in replacement for `.font(.system(size:weight:design:))`
    /// that respects the global font-scale preference. Reads the
    /// multiplier from the environment, so changing the scale at the
    /// root flows through to every label in one tick.
    func feFont(size: CGFloat,
                weight: Font.Weight = .regular,
                design: Font.Design = .default) -> some View {
        modifier(FEScaledFontModifier(size: size, weight: weight, design: design))
    }
}
