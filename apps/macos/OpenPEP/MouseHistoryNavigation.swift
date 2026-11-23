// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import SwiftUI

enum MouseHistoryDirection: Equatable {
    case back
    case forward

    init?(buttonNumber: Int) {
        switch buttonNumber {
        case 3: self = .back
        case 4: self = .forward
        default: return nil
        }
    }
}

struct MouseHistoryNavigation: NSViewRepresentable {
    let canGoBack: Bool
    let canGoForward: Bool
    let onBack: () -> Void
    let onForward: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = WindowTrackingView(frame: .zero)
        view.onWindowChange = { [weak coordinator = context.coordinator] number in
            coordinator?.windowNumber = number
        }
        context.coordinator.install(for: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.canGoBack = canGoBack
        context.coordinator.canGoForward = canGoForward
        context.coordinator.onBack = onBack
        context.coordinator.onForward = onForward
        context.coordinator.install(for: nsView)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    final class Coordinator {
        nonisolated(unsafe) var windowNumber: Int?
        var canGoBack = false
        var canGoForward = false
        var onBack: () -> Void = {}
        var onForward: () -> Void = {}
        private var monitor: Any?

        @MainActor
        func install(for view: NSView) {
            windowNumber = view.window?.windowNumber
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
                guard let self, event.windowNumber == self.windowNumber,
                      let direction = MouseHistoryDirection(buttonNumber: event.buttonNumber) else {
                    return event
                }
                switch direction {
                case .back where self.canGoBack: self.onBack(); return nil
                case .forward where self.canGoForward: self.onForward(); return nil
                default: return event
                }
            }
        }

        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit { removeMonitor() }
    }
}

private final class WindowTrackingView: NSView {
    var onWindowChange: (Int?) -> Void = { _ in }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange(window?.windowNumber)
    }
}
