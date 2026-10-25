import Foundation
import SwiftUI

/// Großer Drehzahlmesser mit Neon-Skala.
///
/// Der Hauptzeiger zeigt ausschließlich die tatsächliche (bzw. im Demomodus simulierte)
/// Drehzahl. Die virtuelle Sounddrehzahl erscheint nur als kleine, separat beschriftete Marke.
struct TachometerView<Badge: View>: View {
    /// Tatsächliche Drehzahl; `nil`, wenn kein aktueller Wert vorliegt.
    let rpm: Double?
    /// Virtuelle Sounddrehzahl (nur Markierung).
    let soundRPM: Double?
    let maxRPM: Double
    let redline: Double
    let isDelayed: Bool
    /// Inhalt in der unteren Öffnung des Skalenbogens (z. B. Dämonen-Emblem).
    @ViewBuilder var badge: () -> Badge

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let startAngle = 135.0
    private let sweep = 270.0

    private func angle(for value: Double) -> Angle {
        .degrees(startAngle + sweep * (value / maxRPM).clamped(0, 1))
    }

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let fraction = ((rpm ?? 0) / maxRPM).clamped(0, 1)
            ZStack {
                Canvas { context, canvasSize in
                    drawScale(context: &context, size: canvasSize)
                }

                // Leuchtender Fortschrittsbogen
                Circle()
                    .trim(from: 0, to: 0.75 * fraction)
                    .stroke(
                        AngularGradient(colors: [DemonTheme.green, DemonTheme.neon, DemonTheme.blurple, DemonTheme.violet],
                                        center: .center, startAngle: .degrees(0), endAngle: .degrees(270)),
                        style: StrokeStyle(lineWidth: size * 0.035, lineCap: .round)
                    )
                    .rotationEffect(.degrees(startAngle))
                    .padding(size * 0.06)
                    .shadow(color: DemonTheme.green.opacity(rpm == nil ? 0 : 0.35 + 0.4 * fraction), radius: 10)
                    .opacity(rpm == nil ? 0.15 : (isDelayed ? 0.5 : 1))

                // Marke der virtuellen Sounddrehzahl
                if let soundRPM, soundRPM > 0 {
                    Capsule()
                        .fill(DemonTheme.violet)
                        .frame(width: size * 0.012, height: size * 0.07)
                        .offset(y: -size * 0.40)
                        .rotationEffect(angle(for: soundRPM) + .degrees(90))
                        .shadow(color: DemonTheme.violet.opacity(0.8), radius: 4)
                        .accessibilityHidden(true)
                }

                // Zeiger
                if rpm != nil {
                    Capsule()
                        .fill(LinearGradient(colors: [DemonTheme.neon, DemonTheme.green.opacity(0.4)], startPoint: .top, endPoint: .bottom))
                        .frame(width: size * 0.018, height: size * 0.36)
                        .offset(y: -size * 0.18)
                        .rotationEffect(angle(for: rpm ?? 0) + .degrees(90))
                        .shadow(color: DemonTheme.neon.opacity(0.7), radius: 6)
                        .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.85), value: rpm ?? 0)
                        .opacity(isDelayed ? 0.5 : 1)
                }

                badge()
                    .frame(width: size * 0.26, height: size * 0.26)
                    .offset(y: size * 0.33)

                Circle()
                    .fill(RadialGradient(colors: [DemonTheme.metal, DemonTheme.panel], center: .center, startRadius: 1, endRadius: size * 0.06))
                    .frame(width: size * 0.11, height: size * 0.11)
                    .overlay(Circle().strokeBorder(DemonTheme.green.opacity(0.6), lineWidth: 1.5))
            }
            .frame(width: size, height: size)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Drehzahlmesser")
        .accessibilityValue(rpm.map { "\(Int($0)) Umdrehungen pro Minute" } ?? "Kein aktueller Wert")
    }

    private func drawScale(context: inout GraphicsContext, size: CGSize) {
        let side = min(size.width, size.height)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = side * 0.44

        // Hintergrundbogen
        var arc = Path()
        arc.addArc(center: center, radius: radius, startAngle: .degrees(startAngle), endAngle: .degrees(startAngle + sweep), clockwise: false)
        context.stroke(arc, with: .color(DemonTheme.metal.opacity(0.6)), style: StrokeStyle(lineWidth: side * 0.035, lineCap: .round))

        // Roter Bereich ab angenommener Höchstdrehzahl
        if redline < maxRPM {
            var red = Path()
            red.addArc(center: center, radius: radius, startAngle: angle(for: redline), endAngle: .degrees(startAngle + sweep), clockwise: false)
            context.stroke(red, with: .color(DemonTheme.danger.opacity(0.55)), style: StrokeStyle(lineWidth: side * 0.035, lineCap: .butt))
        }

        // Skalenstriche je 500 U/min, Beschriftung je 1000 U/min
        let steps = Int(maxRPM / 500)
        for step in 0...steps {
            let value = Double(step) * 500
            let a = angle(for: value).radians
            let major = step % 2 == 0
            let inner = radius - side * (major ? 0.075 : 0.045)
            let outer = radius - side * 0.03
            var tick = Path()
            tick.move(to: CGPoint(x: center.x + cos(a) * inner, y: center.y + sin(a) * inner))
            tick.addLine(to: CGPoint(x: center.x + cos(a) * outer, y: center.y + sin(a) * outer))
            let color = value >= redline ? DemonTheme.danger : (major ? DemonTheme.green : DemonTheme.textSecondary.opacity(0.6))
            context.stroke(tick, with: .color(color), lineWidth: major ? 2.5 : 1)
            if major {
                let labelRadius = radius - side * 0.14
                let text = Text("\(Int(value / 1000))")
                    .font(.system(size: side * 0.055, weight: .bold, design: .rounded))
                    .foregroundStyle(value >= redline ? DemonTheme.danger : Color.white.opacity(0.85))
                context.draw(text, at: CGPoint(x: center.x + cos(a) * labelRadius, y: center.y + sin(a) * labelRadius))
            }
        }
        let unit = Text("×1000 U/min").font(.system(size: side * 0.04, weight: .medium)).foregroundStyle(DemonTheme.textSecondary)
        context.draw(unit, at: CGPoint(x: center.x, y: center.y - side * 0.17))
    }
}
