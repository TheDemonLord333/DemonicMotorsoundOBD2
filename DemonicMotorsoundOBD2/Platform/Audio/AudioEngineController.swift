import AVFAudio
import AVFoundation
import Foundation
import Observation

/// Art der aktuellen Audioausgabe.
enum AudioRouteKind: Equatable {
    case speaker
    case bluetooth
    case carPlay
    case wired
    case usb
    case airPlay
    case other

    var isExternal: Bool { self != .speaker }

    var title: String {
        switch self {
        case .speaker: "iPhone-Lautsprecher"
        case .bluetooth: "Bluetooth"
        case .carPlay: "CarPlay"
        case .wired: "Kabel / AUX"
        case .usb: "USB-Audio"
        case .airPlay: "AirPlay"
        case .other: "Andere Ausgabe"
        }
    }

    var symbolName: String {
        switch self {
        case .speaker: "iphone"
        case .bluetooth: "dot.radiowaves.left.and.right"
        case .carPlay: "car.fill"
        case .wired: "cable.connector"
        case .usb: "cable.connector.horizontal"
        case .airPlay: "airplayaudio"
        case .other: "speaker.wave.2"
        }
    }

    static func from(_ port: AVAudioSession.Port) -> AudioRouteKind {
        switch port {
        case .builtInSpeaker, .builtInReceiver: .speaker
        case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP: .bluetooth
        case .carAudio: .carPlay
        case .headphones, .lineOut: .wired
        case .usbAudio: .usb
        case .airPlay: .airPlay
        default: .other
        }
    }
}

/// Steuert AVAudioSession und AVAudioEngine mit einer `AVAudioSourceNode` als Echtzeitquelle.
///
/// - Kategorie `.playback`: Wiedergabe auch bei Stummschalter und im Hintergrund (nur solange
///   der Sound aktiv ist). Optional `.mixWithOthers`, um mit Musik anderer Apps zu mischen.
/// - Unterbrechungen (Anrufe, Siri), Routenwechsel, Engine-Konfigurationswechsel und
///   Neustarts der Mediendienste werden behandelt.
/// - Fällt eine externe Ausgabe weg, wird pausiert, damit der Sound nicht überraschend über den
///   iPhone-Lautsprecher weiterläuft. Ein Neustart erfolgt nur manuell.
@Observable
final class AudioEngineController {
    enum Status: Equatable {
        case stopped
        case running
        case interrupted
        case routeLost
        case failed(String)

        var title: String {
            switch self {
            case .stopped: "Sound aus"
            case .running: "Sound läuft"
            case .interrupted: "Unterbrochen (z. B. Anruf oder Siri)"
            case .routeLost: "Audioausgabe getrennt – Sound pausiert"
            case .failed(let message): message
            }
        }
    }

    private(set) var status: Status = .stopped
    private(set) var routeName = "—"
    private(set) var routeKind: AudioRouteKind = .speaker
    private(set) var outputLatency: TimeInterval?
    private(set) var sampleRate: Double = 0
    private(set) var notice: String?

    var mixWithOthers = false {
        didSet {
            guard oldValue != mixWithOthers, status == .running else { return }
            try? configureSession()
        }
    }

    var isRunning: Bool { status == .running }

    let control: SynthControl
    private let synth: EngineSynthesizer
    private var engine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private var routeWasExternalWhenStarted = false
    private var observers: [NSObjectProtocol] = []
    private var engineObserver: NSObjectProtocol?

    init(control: SynthControl) {
        self.control = control
        synth = EngineSynthesizer(control: control)
        registerSessionObservers()
        refreshRoute()
    }

    // MARK: - Start / Stopp

    func start() {
        notice = nil
        do {
            try configureSession()
            teardownEngine()
            try buildEngine()
            try engine?.start()
            status = .running
            refreshRoute()
            routeWasExternalWhenStarted = routeKind.isExternal
        } catch {
            teardownEngine()
            status = .failed("Audio konnte nicht gestartet werden: \(error.localizedDescription)")
        }
    }

    func stop() {
        teardownEngine()
        status = .stopped
        deactivateSession()
    }

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: mixWithOthers ? [.mixWithOthers] : [])
        // ~10 ms Puffer: geringe Latenz bei moderatem Energiebedarf. iOS kann abweichen.
        try? session.setPreferredIOBufferDuration(0.01)
        try session.setActive(true)
    }

    private func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func buildEngine() throws {
        let newEngine = AVAudioEngine()
        let hardwareFormat = newEngine.outputNode.outputFormat(forBus: 0)
        let rate = hardwareFormat.sampleRate > 0 ? hardwareFormat.sampleRate : 48_000
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else {
            throw NSError(domain: "DemonicMotorsound", code: 1, userInfo: [NSLocalizedDescriptionKey: "Audioformat nicht verfügbar"])
        }
        // Zustand vorbereiten, bevor der Render-Callback läuft (sanftes Einblenden inklusive).
        synth.prepare(sampleRate: rate)
        let node = AVAudioSourceNode(format: format, renderBlock: Self.makeRenderBlock(synth: synth))
        newEngine.attach(node)
        newEngine.connect(node, to: newEngine.mainMixerNode, format: format)
        newEngine.mainMixerNode.outputVolume = 1
        newEngine.prepare()

        engine = newEngine
        sourceNode = node
        sampleRate = rate
        engineObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: newEngine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleEngineConfigurationChange() }
        }
    }

    private func teardownEngine() {
        if let engineObserver {
            NotificationCenter.default.removeObserver(engineObserver)
        }
        engineObserver = nil
        engine?.stop()
        if let sourceNode, let engine {
            engine.detach(sourceNode)
        }
        sourceNode = nil
        engine = nil
    }

    /// Render-Block außerhalb des MainActor-Kontexts erzeugen, damit der Echtzeitthread keine
    /// Isolationsprüfungen auslöst. Der Block alloziert nicht und nutzt keine Locks.
    nonisolated private static func makeRenderBlock(synth: EngineSynthesizer) -> AVAudioSourceNodeRenderBlock {
        return { isSilence, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard buffers.count > 0, let firstData = buffers[0].mData else { return noErr }
            let frames = Int(frameCount)
            let samples = firstData.assumingMemoryBound(to: Float.self)
            let silent = synth.render(samples, frameCount: frames)
            if buffers.count > 1 {
                for index in 1..<buffers.count {
                    if let data = buffers[index].mData {
                        data.copyMemory(from: firstData, byteCount: frames * MemoryLayout<Float>.size)
                    }
                }
            }
            isSilence.pointee = ObjCBool(silent)
            return noErr
        }
    }

    // MARK: - Route

    func refreshRoute() {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs
        if let first = outputs.first {
            routeKind = AudioRouteKind.from(first.portType)
            routeName = outputs.map(\.portName).joined(separator: ", ")
        } else {
            routeKind = .other
            routeName = "Keine Ausgabe"
        }
        outputLatency = session.outputLatency + session.ioBufferDuration
    }

    // MARK: - Systemereignisse

    private func registerSessionObservers() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
            let typeValue = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsValue = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            MainActor.assumeIsolated {
                self?.handleInterruption(typeValue: typeValue, optionsValue: optionsValue)
            }
        })

        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] note in
            let reasonValue = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated {
                self?.handleRouteChange(reasonValue: reasonValue)
            }
        })

        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleMediaServicesReset()
            }
        })
    }

    private func handleInterruption(typeValue: UInt?, optionsValue: UInt?) {
        guard let typeValue, let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        switch type {
        case .began:
            if status == .running {
                teardownEngine()
                status = .interrupted
            }
        case .ended:
            guard status == .interrupted else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue ?? 0)
            if options.contains(.shouldResume) {
                refreshRoute()
                // Nicht fortsetzen, wenn die externe Ausgabe inzwischen weg ist.
                if routeWasExternalWhenStarted && !routeKind.isExternal {
                    status = .routeLost
                    notice = "Die externe Audioausgabe ist nicht mehr verfügbar. Sound bitte manuell neu starten."
                } else {
                    start() // startet mit sanftem Einblenden
                }
            } else {
                status = .stopped
                notice = "Sound nach Unterbrechung gestoppt. Bei Bedarf erneut starten."
                deactivateSession()
            }
        @unknown default:
            break
        }
    }

    private func handleRouteChange(reasonValue: UInt?) {
        let previousKind = routeKind
        refreshRoute()
        guard status == .running else { return }
        let reason = reasonValue.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
        let lostExternal = (reason == .oldDeviceUnavailable && previousKind.isExternal)
            || (routeWasExternalWhenStarted && !routeKind.isExternal)
        if lostExternal {
            teardownEngine()
            status = .routeLost
            notice = "Die Audioausgabe „\(previousKind.title)“ wurde getrennt. Der Sound ist pausiert, damit er nicht über den iPhone-Lautsprecher weiterläuft."
            deactivateSession()
        } else if routeKind.isExternal {
            routeWasExternalWhenStarted = true
        }
    }

    private func handleEngineConfigurationChange() {
        // Die Engine wurde vom System gestoppt (z. B. neue Abtastrate). Nur neu aufbauen,
        // wenn der Sound laufen soll und die Route nicht verloren ging.
        guard status == .running else { return }
        refreshRoute()
        if routeWasExternalWhenStarted && !routeKind.isExternal {
            teardownEngine()
            status = .routeLost
            notice = "Die externe Audioausgabe wurde getrennt. Sound bitte manuell neu starten."
            deactivateSession()
            return
        }
        start()
    }

    private func handleMediaServicesReset() {
        let wasRunning = status == .running
        teardownEngine()
        status = .stopped
        if wasRunning {
            notice = "Die iOS-Audiodienste wurden neu gestartet. Bitte den Sound erneut starten."
        }
    }
}
