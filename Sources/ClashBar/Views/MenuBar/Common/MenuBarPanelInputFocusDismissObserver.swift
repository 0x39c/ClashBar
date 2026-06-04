@preconcurrency import AppKit
import SwiftUI

struct MenuBarPanelInputFocusDismissObserver: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        InputFocusDismissObserverView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class InputFocusDismissObserverView: NSView {
        private var eventMonitor: EventMonitorToken?

        deinit {
            self.eventMonitor?.remove()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            self.removeEventMonitor()
            guard self.window != nil else { return }
            self.eventMonitor = EventMonitorToken { [weak self] event in
                self?.handleMouseDown(location: event.locationInWindow, windowNumber: event.windowNumber)
                return event
            }
        }

        private func removeEventMonitor() {
            self.eventMonitor?.remove()
            self.eventMonitor = nil
        }

        private func handleMouseDown(location: NSPoint, windowNumber: Int) {
            guard let window = self.window, window.windowNumber == windowNumber else { return }
            let contentView = window.contentView
            let targetPoint = contentView?.convert(location, from: nil) ?? location
            let targetView = contentView?.hitTest(targetPoint)
            guard !Self.isInsideTextInput(targetView) else { return }
            window.makeFirstResponder(contentView)
        }

        private static func isInsideTextInput(_ view: NSView?) -> Bool {
            var current = view
            while let candidate = current {
                if candidate is NSTextField || candidate is NSTextView {
                    return true
                }
                current = candidate.superview
            }
            return false
        }
    }

    private final class EventMonitorToken: @unchecked Sendable {
        private var token: Any?

        init(handler: @escaping (NSEvent) -> NSEvent?) {
            self.token = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: handler)
        }

        deinit {
            self.remove()
        }

        func remove() {
            guard let token else { return }
            NSEvent.removeMonitor(token)
            self.token = nil
        }
    }
}

extension View {
    func menuBarDismissInputFocusOnOutsideClick() -> some View {
        self.background {
            MenuBarPanelInputFocusDismissObserver()
        }
    }
}
