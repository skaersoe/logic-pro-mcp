@preconcurrency import ApplicationServices
import Foundation

/// Track selection on Logic 13.0, where the `AXSelectedChildren` write is acknowledged and ignored.
///
/// Measured 2026-11-15 on Logic 13.0, en-US, macOS 27.0.1, three-track project:
///
/// - Setting `AXSelectedChildren` on the `Tracks header` group returns success; every header's
///   `AXSelected` is unchanged 600 ms later. `AXSelected` on a header is read-only as an attribute
///   claim, a write to it is acknowledged and ignored, and so are `AXPress` on the header's
///   `Has Focus` radio button and on its name field, and `AXFocused` on the header.
/// - `AXShowMenu` on a header opens the header's context menu and, as a secondary click does,
///   moves the selection to that header alone. The call returns `cannotComplete` after about 1.5 s
///   with the menu open. The menu is then exactly one `AXMenu` direct child of the header
///   container, and `AXCancel` on it closes it. The selection stays on the header.
///
/// A header that is already part of a multiple selection keeps that selection when its context
/// menu opens, as in the Logic interface. To end on the target alone, the context menu of a
/// header outside the selection is opened and cancelled first.
///
/// Nothing in the menu is pressed. The only project state that changes is the track selection.
enum TrackHeaderContextMenuSelection {
    /// The selection write is ignored at once on Logic 13.0; on Logic 12 the header read selected
    /// within the callers' existing 100 ms polls. Six reads 50 ms apart cover both.
    static let writeSettleReads = 6
    static let writeSettleInterval: TimeInterval = 0.05
    /// AXShowMenu returned after 1.5 s with the menu already attached.
    static let menuAppearanceTimeout: TimeInterval = 2.0
    static let menuClosureTimeout: TimeInterval = 1.0
    static let selectionTimeout: TimeInterval = 1.0
    static let pollInterval: TimeInterval = 0.05

    enum Outcome: Equatable, Sendable {
        /// The earlier write took effect, or this surface cannot be judged; nothing was done.
        case notApplicable
        /// The target header now reads selected and no other header does.
        case selected
        /// A context menu was opened and the target is not the sole selection, or a step could
        /// not be settled. The reason names the step.
        case failed(String)
    }

    /// Call after an acknowledged selection write. Acts only when every header's selection reads
    /// as a strict Boolean, the target is not the sole selection after the settle reads, and the
    /// headers advertise `AXShowMenu`.
    static func selectIfWriteWasIgnored(
        target: AXUIElement, headers: [AXUIElement], container: AXUIElement,
        runtime: AXHelpers.Runtime,
        permitted: () -> Bool = { true }, willWrite: () -> Void = {}
    ) -> Outcome {
        guard headers.contains(where: { CFEqual($0, target) }) else { return .notApplicable }
        var states: [Bool]?
        for attempt in 0..<writeSettleReads {
            states = selectionStates(headers, runtime: runtime)
            guard let observed = states else { return .notApplicable }
            if isSoleSelection(target, headers: headers, states: observed) { return .notApplicable }
            if attempt < writeSettleReads - 1 { Thread.sleep(forTimeInterval: writeSettleInterval) }
        }
        guard let observed = states, advertisesShowMenu(target, runtime: runtime) else {
            return .notApplicable
        }
        guard menus(under: container, runtime: runtime)?.isEmpty == true else {
            return .failed("context_menu_already_open")
        }

        let targetIndex = headers.firstIndex(where: { CFEqual($0, target) })!
        if observed[targetIndex] {
            // The target is selected together with others. Its own context menu would keep them.
            guard let decoy = zip(headers, observed).first(where: { !$0.1 })?.0,
                  advertisesShowMenu(decoy, runtime: runtime) else {
                return .failed("no_header_outside_the_selection")
            }
            guard permitted() else { return .failed("write_not_permitted") }
            willWrite()
            if let failure = openAndCancelContextMenu(of: decoy, container: container, runtime: runtime) {
                return .failed(failure)
            }
        }
        guard permitted() else { return .failed("write_not_permitted") }
        willWrite()
        if let failure = openAndCancelContextMenu(of: target, container: container, runtime: runtime) {
            return .failed(failure)
        }

        let deadline = Date().addingTimeInterval(selectionTimeout)
        repeat {
            if let now = selectionStates(headers, runtime: runtime),
               isSoleSelection(target, headers: headers, states: now) {
                return .selected
            }
            Thread.sleep(forTimeInterval: pollInterval)
        } while Date() < deadline
        return .failed("selection_not_moved")
    }

    /// Opens `header`'s context menu and cancels it. Returns the failed step, or nil.
    private static func openAndCancelContextMenu(
        of header: AXUIElement, container: AXUIElement, runtime: AXHelpers.Runtime
    ) -> String? {
        // The acknowledgement is not evidence either way: Logic 13.0 answers cannotComplete
        // while the menu it opened is up.
        _ = AXHelpers.performAction(header, kAXShowMenuAction as String, runtime: runtime)
        guard let menu = waitForSingleMenu(under: container, runtime: runtime) else {
            return menus(under: container, runtime: runtime)?.isEmpty == true
                ? "context_menu_not_opened" : "context_menu_state_unverified"
        }
        guard case .success(let actions) = AXHelpers.getActionNamesResult(menu, runtime: runtime),
              actions.contains(kAXCancelAction as String) else {
            return "context_menu_not_cancellable"
        }
        _ = AXHelpers.performAction(menu, kAXCancelAction as String, runtime: runtime)
        let deadline = Date().addingTimeInterval(menuClosureTimeout)
        repeat {
            if menus(under: container, runtime: runtime)?.isEmpty == true { return nil }
            Thread.sleep(forTimeInterval: pollInterval)
        } while Date() < deadline
        return "context_menu_not_closed"
    }

    private static func waitForSingleMenu(
        under container: AXUIElement, runtime: AXHelpers.Runtime
    ) -> AXUIElement? {
        let deadline = Date().addingTimeInterval(menuAppearanceTimeout)
        repeat {
            if let observed = menus(under: container, runtime: runtime), observed.count == 1 {
                return observed[0]
            }
            Thread.sleep(forTimeInterval: pollInterval)
        } while Date() < deadline
        return nil
    }

    /// The `AXMenu` direct children of the header container; nil when a read failed.
    private static func menus(under container: AXUIElement, runtime: AXHelpers.Runtime) -> [AXUIElement]? {
        ControlBarMenuHost.menus(under: [container], runtime: runtime)
    }

    /// Every header's selection as a strict Boolean, or nil when any one is not readable as such.
    private static func selectionStates(_ headers: [AXUIElement], runtime: AXHelpers.Runtime) -> [Bool]? {
        var states: [Bool] = []
        for header in headers {
            let reading: Result<AnyObject?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(
                header, kAXSelectedAttribute as String, runtime: runtime)
            guard case .success(.some(let raw)) = reading,
                  CFGetTypeID(raw) == CFBooleanGetTypeID(), let value = raw as? Bool else { return nil }
            states.append(value)
        }
        return states
    }

    private static func isSoleSelection(
        _ target: AXUIElement, headers: [AXUIElement], states: [Bool]
    ) -> Bool {
        zip(headers, states).allSatisfy { CFEqual($0.0, target) == $0.1 }
    }

    private static func advertisesShowMenu(_ header: AXUIElement, runtime: AXHelpers.Runtime) -> Bool {
        guard case .success(let actions) = AXHelpers.getActionNamesResult(header, runtime: runtime) else {
            return false
        }
        return actions.contains(kAXShowMenuAction as String)
    }
}
