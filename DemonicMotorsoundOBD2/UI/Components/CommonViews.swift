import AVKit
import CoreTransferable
import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Systemeigene Auswahl der Audioausgabe (AirPlay/Bluetooth/…).
struct RoutePickerButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = UIColor(DemonTheme.green)
        view.activeTintColor = UIColor(DemonTheme.blurple)
        view.prioritizesVideoDevices = false
        view.accessibilityLabel = "Audioausgabe wählen"
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

/// Kachel für einen Fahrzeugwert mit Aktualitätsanzeige.
struct ValueTile: View {
    let reading: SignalReading
    var titleOverride: String?
    var footnote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(titleOverride ?? reading.signal.title, systemImage: reading.signal.symbolName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(DemonTheme.textSecondary)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if let value = reading.displayValue {
                    Text(reading.signal.format(value))
                        .font(.title2.weight(.bold).monospacedDigit())
                        .foregroundStyle(reading.freshness == .aging ? DemonTheme.warning : .white)
                        .contentTransition(.numericText())
                    Text(reading.signal.unit)
                        .font(.caption)
                        .foregroundStyle(DemonTheme.textSecondary)
                } else {
                    Text("—")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(DemonTheme.textSecondary)
                }
            }
            Text(reading.statusText + (reading.age.map { reading.freshness == .fresh ? "" : " · \($0.germanDecimal(1)) s" } ?? ""))
                .font(.caption2)
                .foregroundStyle(statusColor)
            if let footnote {
                Text(footnote)
                    .font(.caption2)
                    .foregroundStyle(DemonTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .neonPanel(glow: 0.1, padding: 12)
        .accessibilityElement(children: .combine)
    }

    private var statusColor: Color {
        if reading.availability == .unsupported { return DemonTheme.textSecondary }
        switch reading.freshness {
        case .fresh: return reading.origin == .demo ? DemonTheme.blurple : DemonTheme.green
        case .aging: return DemonTheme.warning
        case .stale: return DemonTheme.danger
        case .none: return DemonTheme.textSecondary
        }
    }
}

/// Beschrifteter Schieberegler mit Wertanzeige.
struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var step: Double?
    var format: (Double) -> String = { "\(Int(($0 * 100).rounded())) %" }
    var help: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value))
                    .monospacedDigit()
                    .foregroundStyle(DemonTheme.textSecondary)
            }
            .font(.subheadline)
            if let step {
                Slider(value: $value, in: range, step: step)
                    .accessibilityLabel(title)
                    .accessibilityValue(format(value))
            } else {
                Slider(value: $value, in: range)
                    .accessibilityLabel(title)
                    .accessibilityValue(format(value))
            }
            if let help {
                Text(help)
                    .font(.caption)
                    .foregroundStyle(DemonTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Dauerhaft sichtbares Banner im Demomodus.
struct DemoBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "theatermasks.fill")
            Text("DEMOMODUS")
                .fontWeight(.heavy)
                .tracking(2)
            Text("· simulierte Daten")
                .font(.caption)
        }
        .font(.subheadline)
        .foregroundStyle(.black)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(DemonTheme.accentGradient)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Demomodus aktiv, simulierte Daten")
    }
}

/// Werkzeugleisten-Schaltfläche zur Anleitung.
struct GuideToolbarButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.showGuide = true
        } label: {
            Label("Anleitung", systemImage: "book.closed.fill")
        }
    }
}

/// Exportierbares Diagnoseprotokoll.
nonisolated struct DiagnosticExport: Transferable, Sendable {
    let text: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .plainText) { export in
            Data(export.text.utf8)
        }
        .suggestedFileName("DemonicMotorsound-Diagnose.txt")
    }
}
