import Foundation
import SwiftUI

/// Dezente Dämonenanimation auf Basis des App-Icons: Augen und Glow werden mit der Drehzahl
/// stärker. Bei „Bewegung reduzieren“ entfällt das sanfte Pulsieren; die Helligkeit folgt dann
/// nur noch der Drehzahl.
struct DemonEmblemView: View {
    /// 0…1 – Intensität aus der Drehzahl.
    let intensity: Double
    /// Ob Sound/Motor aktiv ist.
    let active: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: reduceMotion || !active)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            // Langsames „Atmen“ (0,4 Hz) – kein Blinken.
            let breathe = reduceMotion || !active ? 0 : 0.08 * sin(t * 2 * .pi * 0.4)
            let level = (active ? 0.25 + 0.75 * intensity : 0.12) + breathe

            GeometryReader { proxy in
                let side = min(proxy.size.width, proxy.size.height)
                ZStack {
                    Image("AppArtwork")
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: side * 0.22, style: .continuous))
                        .saturation(0.75 + 0.25 * level)
                        .brightness(-0.12 + 0.12 * level)

                    // Augen-Glow (Positionen entsprechen den Augen im Icon)
                    ForEach([CGPoint(x: 0.367, y: 0.452), CGPoint(x: 0.635, y: 0.452)], id: \.x) { eye in
                        Circle()
                            .fill(RadialGradient(colors: [DemonTheme.neon.opacity(0.95 * level), DemonTheme.green.opacity(0.35 * level), .clear],
                                                 center: .center, startRadius: 0, endRadius: side * 0.09))
                            .frame(width: side * 0.18, height: side * 0.18)
                            .position(x: eye.x * side, y: eye.y * side)
                            .blendMode(.screen)
                    }

                    // Schallwellen-Glow unten
                    Capsule()
                        .fill(RadialGradient(colors: [DemonTheme.neon.opacity(0.5 * level), .clear], center: .center, startRadius: 0, endRadius: side * 0.22))
                        .frame(width: side * 0.5, height: side * 0.12)
                        .position(x: 0.5 * side, y: 0.70 * side)
                        .blendMode(.screen)
                }
                .frame(width: side, height: side)
                .shadow(color: DemonTheme.blurple.opacity(0.25 + 0.35 * level), radius: side * 0.08)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}
