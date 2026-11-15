@preconcurrency import ApplicationServices
import Foundation

/// Where Logic attaches the `AXMenu` that a control-bar popup opens.
///
/// Logic 12 attaches it as a child of the `AXPopUpButton`. Logic 13.0 (measured 2026-11-15, en-US,
/// macOS 27.0.1) does that for ordinary popups (`Snap type`, `Drag Mode`) but not for the popups
/// in the control bar's display (`Display Mode`, `Key Signature`). Their path is
///
///     AXWindow > AXToolbar "Control Bar" > AXGroup (toolbar item) > AXGroup "Transport Display" > AXPopUpButton
///
/// and after `AXShowMenu` the `AXMenu` is a child of the toolbar-item `AXGroup`, a sibling of
/// `Transport Display`. The popup keeps zero children. `Transport Display` reports no `AXParent`
/// and the popup reports no `AXWindow`, so the host is reachable only downward from the window.
///
/// The same seventeen items, the same single checkmark and `AXCancel` on the menu were observed
/// there; only the attachment point differs.
enum ControlBarMenuHost {
    /// The measured path has three levels below the toolbar. One spare level is allowed.
    static let maxToolbarPathDepth = 4

    /// The elements whose direct children can hold the menu `popup` opens: the popup itself, then
    /// every element on the path from an `AXToolbar` child of `window` down to the popup's parent.
    /// When the popup is not under a toolbar of this window (the Logic 12 layout), only the popup.
    /// `nil` when a read needed to decide that failed; an unread branch may hold the popup.
    static func menuParents(
        of popup: AXUIElement, in window: AXUIElement, runtime: AXHelpers.Runtime
    ) -> [AXUIElement]? {
        guard let windowChildren = children(of: window, runtime: runtime) else { return nil }
        var paths: [[AXUIElement]] = []
        for child in windowChildren {
            guard let role = role(of: child, runtime: runtime) else { return nil }
            guard role == kAXToolbarRole as String else { continue }
            switch path(from: child, to: popup, remainingDepth: maxToolbarPathDepth, runtime: runtime) {
            case .found(let found): paths.append(found)
            case .absent: continue
            case .unreadable: return nil
            }
        }
        // Two toolbars both claiming the popup would make the host ambiguous.
        guard paths.count <= 1 else { return nil }
        return [popup] + (paths.first ?? [])
    }

    /// The `AXMenu` elements currently attached at any of `parents`. `nil` when a children or role
    /// read failed, so an unread element is never counted as "no menu".
    static func menus(under parents: [AXUIElement], runtime: AXHelpers.Runtime) -> [AXUIElement]? {
        var menus: [AXUIElement] = []
        for parent in parents {
            guard let observed = children(of: parent, runtime: runtime) else { return nil }
            for child in observed {
                guard let role = role(of: child, runtime: runtime) else { return nil }
                if role == kAXMenuRole as String { menus.append(child) }
            }
        }
        return menus
    }

    private enum PathSearch {
        /// The elements from the search root down to the target's parent, in that order.
        case found([AXUIElement])
        case absent
        case unreadable
    }

    private static func path(
        from element: AXUIElement, to target: AXUIElement, remainingDepth: Int,
        runtime: AXHelpers.Runtime
    ) -> PathSearch {
        guard remainingDepth > 0 else { return .absent }
        guard let observed = children(of: element, runtime: runtime) else { return .unreadable }
        if observed.contains(where: { CFEqual($0, target) }) { return .found([element]) }
        var sawUnreadable = false
        for child in observed {
            switch path(from: child, to: target, remainingDepth: remainingDepth - 1, runtime: runtime) {
            case .found(let rest): return .found([element] + rest)
            case .absent: continue
            case .unreadable: sawUnreadable = true
            }
        }
        return sawUnreadable ? .unreadable : .absent
    }

    /// An element that vends no children attribute, or has none, has no children.
    private static func children(of element: AXUIElement, runtime: AXHelpers.Runtime) -> [AXUIElement]? {
        switch AXHelpers.childrenResult(element, runtime: runtime) {
        case .success(let observed): return observed
        case .failure(let error) where error.isDefinitiveAbsence: return []
        case .failure: return nil
        }
    }

    private static func role(of element: AXUIElement, runtime: AXHelpers.Runtime) -> String? {
        let reading: Result<String?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(
            element, kAXRoleAttribute as String, runtime: runtime)
        guard case .success(.some(let value)) = reading else { return nil }
        return value
    }
}
