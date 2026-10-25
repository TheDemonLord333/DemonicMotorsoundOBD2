import Foundation
import SwiftUI

/// Farben und Stilelemente – abgeleitet vom App-Icon (Neon-Grün, Blau-Violett, dunkles Metall).
enum DemonTheme {
    /// Spotify-Grün
    static let green = Color(red: 0x1D / 255, green: 0xB9 / 255, blue: 0x54 / 255)
    /// Helles Neon-Grün für Glow-Akzente
    static let neon = Color(red: 0x5B / 255, green: 0xFF / 255, blue: 0x7F / 255)
    /// Discord-Blau-Violett
    static let blurple = Color(red: 0x58 / 255, green: 0x65 / 255, blue: 0xF2 / 255)
    static let violet = Color(red: 0x7B / 255, green: 0x4D / 255, blue: 0xFF / 255)
    static let background = Color(red: 0.016, green: 0.018, blue: 0.024)
    static let panel = Color(red: 0.055, green: 0.063, blue: 0.078)
    static let panelHighlight = Color(red: 0.10, green: 0.11, blue: 0.135)
    static let metal = Color(red: 0.20, green: 0.22, blue: 0.26)
    static let textSecondary = Color(white: 0.68)
    static let warning = Color(red: 1.0, green: 0.71, blue: 0.2)
    static let danger = Color(red: 1.0, green: 0.32, blue: 0.38)

    static let accentGradient = LinearGradient(colors: [green, blurple], startPoint: .leading, endPoint: .trailing)
    static let borderGradient = LinearGradient(colors: [green.opacity(0.55), blurple.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// Dunkles Panel mit dezentem Neonrand.
struct NeonPanel: ViewModifier {
    var glow: Double = 0.25
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(LinearGradient(colors: [DemonTheme.panelHighlight, DemonTheme.panel], startPoint: .top, endPoint: .bottom))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(DemonTheme.borderGradient, lineWidth: 1)
                    .opacity(0.8)
            )
            .shadow(color: DemonTheme.blurple.opacity(glow * 0.6), radius: 14)
    }
}

extension View {
    func neonPanel(glow: Double = 0.25, padding: CGFloat = 16) -> some View {
        modifier(NeonPanel(glow: glow, padding: padding))
    }

    /// Dunkler Hintergrund mit dezentem Schallwellen-Motiv.
    func demonBackground() -> some View {
        background(DemonBackdrop().ignoresSafeArea())
    }
}

/// Hintergrund: fast schwarz, mit gedämpften Glows und Schallwellenlinien.
struct DemonBackdrop: View {
    var body: some View {
        ZStack {
            DemonTheme.background
            RadialGradient(colors: [DemonTheme.blurple.opacity(0.18), .clear], center: .topTrailing, startRadius: 10, endRadius: 420)
            RadialGradient(colors: [DemonTheme.green.opacity(0.10), .clear], center: .bottomLeading, startRadius: 10, endRadius: 380)
            Canvas { context, size in
                // Statische, dezente Schallwellen (keine Animation → keine Last).
                for line in 0..<3 {
                    var path = Path()
                    let baseY = size.height * (0.82 + CGFloat(line) * 0.045)
                    path.move(to: CGPoint(x: 0, y: baseY))
                    for x in stride(from: 0, through: size.width, by: 4) {
                        let envelope = sin(Double(x / size.width) * .pi)
                        let y = baseY + CGFloat(sin(Double(x) / (18 + Double(line) * 7)) * 10 * envelope)
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                    context.stroke(path, with: .color((line == 1 ? DemonTheme.blurple : DemonTheme.green).opacity(0.07)), lineWidth: 1.5)
                }
            }
        }
    }
}

/// Kleines Statusabzeichen.
struct StatusChip: View {
    let text: String
    let systemImage: String
    var color: Color = DemonTheme.green

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(color.opacity(0.14)))
            .overlay(Capsule().strokeBorder(color.opacity(0.45), lineWidth: 1))
            .foregroundStyle(color)
    }
}

/// Abschnittsüberschrift im Panel.
struct PanelHeader: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .foregroundStyle(DemonTheme.accentGradient)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

extension DataQuality {
    var color: Color {
        switch self {
        case .good: DemonTheme.green
        case .delayed, .waiting: DemonTheme.warning
        case .lost, .noSource: DemonTheme.danger
        }
    }

    var symbolName: String {
        switch self {
        case .good: "checkmark.seal.fill"
        case .delayed: "clock.badge.exclamationmark"
        case .waiting: "hourglass"
        case .lost: "exclamationmark.triangle.fill"
        case .noSource: "xmark.octagon"
        }
    }
}

extension Double {
    /// Deutsches Zahlenformat ohne Nachkommastellen.
    var germanInteger: String {
        formatted(.number.precision(.fractionLength(0)).locale(Locale(identifier: "de_DE")))
    }

    func germanDecimal(_ digits: Int) -> String {
        formatted(.number.precision(.fractionLength(digits)).locale(Locale(identifier: "de_DE")))
    }
}
