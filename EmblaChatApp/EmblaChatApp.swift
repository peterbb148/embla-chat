import Foundation
import Observation
import SwiftUI
import UIKit

import EmblaCore

@main
struct EmblaChatApp: App {
    private let network: NetworkAccess = {
        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--network-policy-fixture") {
                return NetworkAccess(initialState: .unsatisfied)
            }
        #endif
        return .shared
    }()

    var body: some Scene {
        WindowGroup {
            ContentView(network: network)
                #if DEBUG
                    .preferredColorScheme(
                        ProcessInfo.processInfo.arguments.contains("--network-dark-appearance")
                            ? .dark : nil)
                #endif
        }
    }
}

/// Mirrors the dispatch policy; path availability never promises internet reachability.
@MainActor @Observable
final class AppConnectivity {
    let access: NetworkAccess
    private(set) var snapshot: NetworkAccess.Snapshot
    @ObservationIgnored private var observer: UUID?

    init(access: NetworkAccess) {
        self.access = access
        snapshot = access.snapshot
        observer = access.observe { [weak self] value in
            Task { @MainActor [weak self] in
                guard let self, value.revision >= snapshot.revision else { return }
                let changedPrivacy = snapshot.localOnly != value.localOnly
                snapshot = value
                if changedPrivacy {
                    UIAccessibility.post(
                        notification: .announcement,
                        argument: value.localOnly
                            ? "Privacy mode. Network access paused."
                            : "Privacy mode ended. Check connectivity status for network availability."
                    )
                }
            }
        }
    }

    deinit { if let observer { access.removeObserver(observer) } }

    var label: String? {
        switch snapshot.path {
        case .unsatisfied: "Privacy mode — network paused"
        case .unknown: "Checking connectivity"
        case .requiresConnection: "Connection required"
        case .satisfied: snapshot.allowsRequests ? nil : "Preparing network access"
        }
    }
}

/// Additive, noninteractive strokes share the screen perimeter across presented windows.
/// UIKit window-visibility notifications include the keyboard; no private classes are queried.
struct PrivacyBorder: UIViewRepresentable {
    let connectivity: AppConnectivity
    let snapshot: NetworkAccess.Snapshot

    func makeUIView(context: Context) -> Host { Host() }
    func updateUIView(_ view: Host, context: Context) {
        view.apply(connectivity.access, snapshot)
    }
    static func dismantleUIView(_ view: Host, coordinator: ()) { view.hide() }

    final class Host: UIView {
        private final class Presentation {
            weak var window: UIWindow?
            var outline: Outline?
            init(_ window: UIWindow) { self.window = window }
        }
        private var presentations: [Presentation] = []
        private var access: NetworkAccess?
        private var snapshot: NetworkAccess.Snapshot?
        private var viewport = CGRect.zero

        override init(frame: CGRect) {
            super.init(frame: frame)
            for name in [
                UIWindow.didBecomeVisibleNotification,
                UIResponder.keyboardDidShowNotification,
                UIResponder.keyboardWillChangeFrameNotification,
            ] {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(presentationChanged(_:)), name: name, object: nil)
            }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

        @objc private func presentationChanged(_ notification: Notification) {
            if let presented = notification.object as? UIWindow { remember(presented) }
            render()
        }

        private func remember(_ presented: UIWindow) {
            presentations.removeAll { $0.window == nil }
            guard !presentations.contains(where: { $0.window === presented }) else { return }
            presentations.append(Presentation(presented))
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { hide(); return }
            if let access, let snapshot { apply(access, snapshot) }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            if let window, window.bounds != viewport { render() }
        }

        /// Remove every owned stroke before reopening network admission.
        func hide() {
            for presentation in presentations {
                presentation.outline?.removeFromSuperview()
                presentation.outline = nil
            }
        }

        func apply(_ access: NetworkAccess, _ snapshot: NetworkAccess.Snapshot) {
            self.access = access
            self.snapshot = snapshot
            render()
            if !snapshot.localOnly, window != nil {
                access.activateRequests(after: snapshot.revision)
            }
        }

        private func render() {
            guard let source = window, let scene = source.windowScene else { return }
            viewport = source.bounds
            for presented in scene.windows { remember(presented) }
            guard snapshot?.localOnly == true else { hide(); return }
            for presentation in presentations {
                guard let target = presentation.window else { continue }
                let outline: Outline
                if let current = presentation.outline {
                    outline = current
                } else {
                    outline = Outline()
                    presentation.outline = outline
                }
                if outline.superview !== target { target.addSubview(outline) }
                let insets = source.safeAreaInsets
                outline.cornerRadius = max(insets.top, insets.bottom, insets.left, insets.right, 12)
                outline.frame = target.bounds
                target.bringSubviewToFront(outline)
                let highestLayer =
                    target.layer.sublayers?
                    .filter { $0 !== outline.layer }.map(\.zPosition).max() ?? 0
                outline.layer.zPosition = highestLayer + 1
                outline.setNeedsLayout()
            }
        }
    }

    private final class Outline: UIView {
        private let stroke = CAShapeLayer()
        var cornerRadius: CGFloat = 12
        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isUserInteractionEnabled = false
            accessibilityElementsHidden = true
            isOpaque = false
            autoresizingMask = [.flexibleWidth, .flexibleHeight]
            layer.zPosition = 1
            stroke.fillColor = UIColor.clear.cgColor
            stroke.strokeColor = UIColor.systemGreen.cgColor
            stroke.lineWidth = 2
            layer.addSublayer(stroke)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let space = window?.windowScene?.coordinateSpace else { return }
            // Keyboard presentations may use a different UIScreen even on the same phone.
            // Convert only within this window's scene; cross-screen conversion is invalid.
            let perimeter = space.convert(space.bounds, to: self)
            stroke.frame = bounds
            stroke.path =
                UIBezierPath(
                    roundedRect: perimeter.insetBy(dx: 1, dy: 1), cornerRadius: cornerRadius
                ).cgPath
        }
    }
}
