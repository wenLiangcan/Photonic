import AppKit

/// Observes pointer activity without consuming AppKit's button tracking events.
/// Only the keyboard branch may read characters or key codes from an NSEvent.
@MainActor
enum ViewerInputRouter {
    static func route(
        _ event: NSEvent,
        interactionBegan: () -> Void,
        pointerActivity: @escaping @MainActor () -> Void,
        deferActivity: (@escaping @MainActor () -> Void) -> Void = { action in
            DispatchQueue.main.async { action() }
        },
        leftMouseDown: (NSEvent) -> NSEvent?,
        scrollWheel: (NSEvent) -> NSEvent?,
        keyDown: (NSEvent) -> NSEvent?
    ) -> NSEvent? {
        switch event.type {
        case .leftMouseDown, .leftMouseDragged, .rightMouseDown,
             .rightMouseDragged, .otherMouseDown, .otherMouseDragged:
            interactionBegan()
        case .mouseMoved, .scrollWheel, .leftMouseUp, .rightMouseUp, .otherMouseUp:
            // Finish mouse-up dispatch before updating SwiftUI visibility.
            deferActivity(pointerActivity)
        default:
            break
        }

        switch event.type {
        case .leftMouseDown: return leftMouseDown(event)
        case .scrollWheel: return scrollWheel(event)
        case .keyDown: return keyDown(event)
        default: return event
        }
    }
}
