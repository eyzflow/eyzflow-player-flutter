import Flutter
import UIKit
import CoreMedia

// EYZFlow patch: the Cast button over AVKit's controls (CastOverlayButton).
// The Android counterpart is VideoPlayerView.setCastButtonVisible.
extension VideoPlayerView {
    func handleSetCastButtonVisible(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let arguments = call.arguments as? [String: Any],
              let visible = arguments["visible"] as? Bool else {
            result(FlutterError(code: "INVALID_ARGUMENTS", message: "Invalid arguments", details: nil))
            return
        }
        // Only over AVKit's own controls: the light and texture views have
        // none. Not before iOS 15 (UIButton.Configuration).
        guard #available(iOS 15.0, *), !usesLightView, !isTextureBacked else {
            result(nil)
            return
        }
        let view = playerViewController.view!
        // A shared AVPlayerViewController can come back with another view's
        // button on it: reuse it rather than stack a second one.
        let button = view.subviews.compactMap { $0 as? CastOverlayButton }.first
            ?? CastOverlayButton.install(in: view)
        button.removeTarget(nil, action: nil, for: .touchUpInside)
        button.addTarget(self, action: #selector(castButtonTapped), for: .touchUpInside)
        button.accessibilityLabel = arguments["label"] as? String ?? "Cast"
        button.isHidden = !visible
        // Over AVKit's controls, which it may have added after the button.
        view.bringSubviewToFront(button)
        result(nil)
    }

    @objc func castButtonTapped() {
        guard let controllerId = controllerId else { return }
        let seconds = player?.currentTime().seconds ?? 0
        let positionMs = seconds.isFinite ? Int(seconds * 1000) : 0
        SharedPlayerManager.shared.sendControllerEvent(
            "castRequested",
            data: ["positionMs": positionMs],
            for: controllerId
        )
    }
}
