@preconcurrency import ApplicationServices
import AppKit
import Foundation

/// Logic 13.0's Browser pane is read as an element without children.
///
/// Measured 2026-11-15 on Logic 13.0, en-US, macOS 27.0.1. Creating a software instrument track
/// opens the Browser pane. The arrange window's direct children were then:
///
///     AXToolbar "Control Bar"      51 elements
///     AXGroup   "Control Bar"      12
///     AXGroup   "Inspector"        81
///     AXGroup   "Browser"      33,150   (depth 11; 4,138 leaf reads answer AXError.failure)
///     AXGroup   "Tracks"          118
///     four window buttons, one image, one static text
///
/// A complete read of the Browser pane took 98 s from a separate process. Sixty-six searches in
/// this server start at the window; the control-bar census and the mixer-area lookup were sampled
/// inside the pane while `refresh_cache` answered `operation_timeout` after 25 s and a track
/// creation timed out after its write.
///
/// The pane lists sounds. No transport, track, mixer, region or marker element is inside it, so
/// the production runtime answers "no children" for the pane itself. The pane stays in its
/// parent's children with its role and description. Code that must read the sound list can do so
/// inside `withPaneReadable`.
///
/// Limits:
/// - The pane is recognised by its en-US description. In another interface language it is not
///   recognised and is read in full, as before.
/// - The pane is looked for at most every `rescanInterval`. A search that enters the pane in the
///   interval after it opens runs into its operation deadline once.
/// - `LOGIC_MCP_BROWSER_PANE_OPAQUE=0` turns the rule off.
enum BrowserPaneOpacity {
    /// en-US. Not measured in other languages.
    static let paneDescriptions: Set<String> = ["Browser"]
    static let logicBundleIDs: Set<String> = ["com.apple.logic10", "com.apple.mobilelogic"]
    /// One scan is the window list, each window's children, and a role and a description per
    /// direct child: about 25 requests for one arrange window.
    static let rescanInterval: TimeInterval = 0.25

    static let enabled = ProcessInfo.processInfo.environment["LOGIC_MCP_BROWSER_PANE_OPAQUE"] != "0"

    @TaskLocal static var paneReadable = false

    private static let lock = NSLock()
    nonisolated(unsafe) private static var panes: [AXUIElement] = []
    nonisolated(unsafe) private static var lastScan = Date.distantPast
    nonisolated(unsafe) private static var logicPIDs: [pid_t: Bool] = [:]

    /// Runs `body` with the pane's children readable on the current task.
    static func withPaneReadable<T>(_ body: () throws -> T) rethrows -> T {
        try $paneReadable.withValue(true, operation: body)
    }

    /// Whether `element` is a Browser pane whose children are withheld.
    static func hidesChildren(of element: AXUIElement) -> Bool {
        guard enabled, !paneReadable else { return false }
        lock.lock()
        defer { lock.unlock() }
        if Date().timeIntervalSince(lastScan) >= rescanInterval {
            var pid: pid_t = 0
            if AXUIElementGetPid(element, &pid) == .success, isLogic(pid) {
                panes = scan(application: AXUIElementCreateApplication(pid))
                lastScan = Date()
            }
        }
        return panes.contains { CFEqual($0, element) }
    }

    /// The Browser panes among the direct children of `windows`: an `AXGroup` whose description
    /// is one of `paneDescriptions`. An element whose role or description cannot be read is not
    /// a pane.
    static func panes(
        inWindows windows: [AXUIElement],
        children: (AXUIElement) -> [AXUIElement],
        string: (AXUIElement, String) -> String?
    ) -> [AXUIElement] {
        var found: [AXUIElement] = []
        for window in windows {
            for child in children(window)
            where string(child, kAXRoleAttribute as String) == kAXGroupRole as String {
                if let description = string(child, kAXDescriptionAttribute as String),
                   paneDescriptions.contains(description) {
                    found.append(child)
                }
            }
        }
        return found
    }

    /// Test seam: replaces the known panes and holds off the next scan.
    static func setPanesForTesting(_ elements: [AXUIElement]) {
        lock.lock()
        panes = elements
        lastScan = elements.isEmpty ? .distantPast : .distantFuture
        lock.unlock()
    }

    private static func isLogic(_ pid: pid_t) -> Bool {
        if let known = logicPIDs[pid] { return known }
        let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        let result = bundle.map(logicBundleIDs.contains) ?? false
        logicPIDs[pid] = result
        return result
    }

    private static func scan(application: AXUIElement) -> [AXUIElement] {
        AXUIElementSetMessagingTimeout(application, 1.0)
        func raw(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
            var value: AnyObject?
            return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
                ? value : nil
        }
        func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
            raw(element, attribute).map(AXHelpers.decodeChildrenArray) ?? []
        }
        return panes(
            inWindows: elements(application, kAXWindowsAttribute as String),
            children: { elements($0, kAXChildrenAttribute as String) },
            string: { raw($0, $1) as? String })
    }
}
