#if os(iOS)
import AVFoundation
import AVKit
import SwiftUI

/// Hosts the system microphone picker (AirPods, headsets, built-in) from iOS 26.
/// The system sheet switches the route itself, which is more reliable than choosing a
/// port by hand while voice processing is active.
@MainActor
final class InputPickerHost: NSObject, AVInputPickerInteraction.Delegate {
    private var interaction: AVInputPickerInteraction?
    var onDismiss: () -> Void = {}

    func attach(to view: UIView) {
        guard interaction == nil else { return }
        let i = AVInputPickerInteraction()
        i.audioSession = AVAudioSession.sharedInstance()
        i.delegate = self
        view.addInteraction(i)
        interaction = i
    }

    func present() { interaction?.present() }

    nonisolated func inputPickerInteractionDidEndDismissing(_ inputPickerInteraction: AVInputPickerInteraction) {
        Task { @MainActor in self.onDismiss() }
    }
}

struct InputPickerAnchor: UIViewRepresentable {
    let host: InputPickerHost

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        host.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
#endif
