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
        case .requiresConnection: "Connection required — availability unverified"
        case .satisfied: snapshot.allowsRequests ? nil : "Preparing network access"
        }
    }
}

/// A separate, non-key, noninteractive window stays above sheets without intercepting touches.
struct PrivacyBorder: UIViewRepresentable {
    let connectivity: AppConnectivity
    let snapshot: NetworkAccess.Snapshot

    func makeUIView(context: Context) -> Host { Host() }
    func updateUIView(_ view: Host, context: Context) {
        view.apply(connectivity.access, snapshot)
    }
    static func dismantleUIView(_ view: Host, coordinator: ()) { view.hide() }

    final class Host: UIView {
        private var border: UIWindow?
        private var access: NetworkAccess?
        private var snapshot: NetworkAccess.Snapshot?
        private var keyboardFrame: CGRect?

        override init(frame: CGRect) {
            super.init(frame: frame)
            NotificationCenter.default.addObserver(
                self, selector: #selector(keyboardChanged(_:)),
                name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
            NotificationCenter.default.addObserver(
                self, selector: #selector(keyboardChanged(_:)),
                name: UIResponder.keyboardWillHideNotification, object: nil)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

        @objc private func keyboardChanged(_ notification: Notification) {
            keyboardFrame =
                notification.name == UIResponder.keyboardWillHideNotification
                ? nil : notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
            (border?.rootViewController?.view as? Outline)?.setKeyboardFrame(keyboardFrame)
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let access, let snapshot { apply(access, snapshot) }
        }

        func hide() { border?.isHidden = true; border = nil }

        func apply(_ access: NetworkAccess, _ snapshot: NetworkAccess.Snapshot) {
            self.access = access
            self.snapshot = snapshot
            guard let scene = window?.windowScene else { return }
            if snapshot.localOnly {
                if border == nil {
                    let overlay = UIWindow(windowScene: scene)
                    overlay.windowLevel = .alert + 1
                    overlay.backgroundColor = .clear
                    overlay.isUserInteractionEnabled = false
                    overlay.accessibilityElementsHidden = true
                    let controller = UIViewController()
                    let outline = Outline()
                    outline.setKeyboardFrame(keyboardFrame)
                    controller.view = outline
                    overlay.rootViewController = controller
                    border = overlay
                }
                border?.isHidden = false
            } else {
                // Hide synchronously before acknowledging this exact online transition.
                hide()
                access.activateRequests(after: snapshot.revision)
            }
        }
    }

    private final class Outline: UIView {
        private let stroke = CAShapeLayer()
        private var keyboardFrame: CGRect?
        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isUserInteractionEnabled = false
            stroke.fillColor = UIColor.clear.cgColor
            stroke.strokeColor = UIColor.systemGreen.cgColor
            stroke.lineWidth = 2
            layer.addSublayer(stroke)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

        func setKeyboardFrame(_ frame: CGRect?) {
            keyboardFrame = frame
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            let radius = max(safeAreaInsets.top, safeAreaInsets.bottom, 12)
            stroke.frame = bounds
            var visible = bounds
            if let keyboardFrame {
                let keyboard = convert(keyboardFrame, from: nil)
                if keyboard.width >= bounds.width / 2, keyboard.maxY >= bounds.maxY {
                    visible.size.height = max(0, min(bounds.height, keyboard.minY))
                }
            }
            stroke.path =
                UIBezierPath(
                    roundedRect: visible.insetBy(dx: 1, dy: 1), cornerRadius: radius
                ).cgPath
        }
    }
}
