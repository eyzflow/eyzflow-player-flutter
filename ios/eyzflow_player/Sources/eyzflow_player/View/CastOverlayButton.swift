import UIKit

/// EYZFlow patch: the Cast button over AVKit's controls, which have no slot
/// for it. Dart shows it once a Cast device was found; a tap only tells Dart
/// (`castRequested`), which decides.
///
/// It sits under the trailing end of AVKit's top bar, lined up with the
/// volume button. AVKit doesn't expose its controls' frames: inside the
/// plugin's view it lays the bar out 8pt below the view's safe-area top and
/// 8pt from its trailing edge, with 38pt round buttons (measured on iOS 26.5
/// and 18.2, iPhone and iPad). The view's safe area changes under the player
/// (none when it opens, the real one after a rotation), so the button is
/// pinned to the same safe area.
@available(iOS 15.0, *)
final class CastOverlayButton: UIButton {
    static let size: CGFloat = 38
    static let edge: CGFloat = 8
    static let gap: CGFloat = 12

    /// Adds the button to AVKit's view, under the trailing end of its top bar.
    static func install(in view: UIView) -> CastOverlayButton {
        let button = CastOverlayButton(type: .system)
        button.applyStyle()
        button.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(button)
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: guide.topAnchor, constant: edge + size + gap),
            // In landscape AVKit puts the bar over the side safe area.
            button.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -edge),
            button.widthAnchor.constraint(equalToConstant: size),
            button.heightAnchor.constraint(equalToConstant: size),
        ])
        return button
    }

    private func applyStyle() {
        var configuration: UIButton.Configuration
        #if compiler(>=6.2)
            if #available(iOS 26, *) {
                configuration = .glass()
            } else {
                configuration = Self.filledConfiguration()
            }
        #else
            configuration = Self.filledConfiguration()
        #endif
        configuration.image = Self.castIcon()
        configuration.baseForegroundColor = .white
        configuration.cornerStyle = .capsule
        configuration.contentInsets = .zero
        self.configuration = configuration
        // AVKit's controls are dark whatever the app's appearance.
        overrideUserInterfaceStyle = .dark
    }

    private static func filledConfiguration() -> UIButton.Configuration {
        var configuration = UIButton.Configuration.filled()
        configuration.baseBackgroundColor = UIColor(white: 0, alpha: 0.45)
        return configuration
    }

    /// The Google Cast icon (a screen with waves in its corner), drawn as a
    /// template image. SF Symbols has no Cast symbol.
    static func castIcon(pointSize: CGFloat = 20) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: pointSize, height: pointSize))
        let image = renderer.image { context in
            // Drawn on Material's 24-unit grid.
            context.cgContext.scaleBy(x: pointSize / 24, y: pointSize / 24)
            UIColor.black.set()

            let screen = UIBezierPath()
            screen.move(to: CGPoint(x: 2, y: 8))
            screen.addLine(to: CGPoint(x: 2, y: 5))
            screen.addArc(withCenter: CGPoint(x: 3, y: 5), radius: 1, startAngle: .pi, endAngle: -.pi / 2, clockwise: true)
            screen.addLine(to: CGPoint(x: 21, y: 4))
            screen.addArc(withCenter: CGPoint(x: 21, y: 5), radius: 1, startAngle: -.pi / 2, endAngle: 0, clockwise: true)
            screen.addLine(to: CGPoint(x: 22, y: 19))
            screen.addArc(withCenter: CGPoint(x: 21, y: 19), radius: 1, startAngle: 0, endAngle: .pi / 2, clockwise: true)
            screen.addLine(to: CGPoint(x: 14, y: 20))
            screen.lineWidth = 2
            screen.stroke()

            let corner = CGPoint(x: 1, y: 21)
            for radius: CGFloat in [6, 10] {
                let wave = UIBezierPath(arcCenter: corner, radius: radius, startAngle: -.pi / 2, endAngle: 0, clockwise: true)
                wave.lineWidth = 2
                wave.stroke()
            }
            let dot = UIBezierPath()
            dot.move(to: corner)
            dot.addArc(withCenter: corner, radius: 3, startAngle: -.pi / 2, endAngle: 0, clockwise: true)
            dot.close()
            dot.fill()
        }
        return image.withRenderingMode(.alwaysTemplate)
    }
}
