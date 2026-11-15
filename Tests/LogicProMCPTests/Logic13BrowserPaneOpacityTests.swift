@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

// Logic 13.0's Browser pane (AXGroup "Browser", a direct child of the arrange window) held 33,150
// elements on 2026-11-15. The production runtime reads it as an element without children.
@Suite(.serialized) struct Logic13BrowserPaneOpacityTests {
    private func tree() -> (FakeAXRuntimeBuilder, window: AXUIElement, pane: AXUIElement, other: AXUIElement) {
        let b = FakeAXRuntimeBuilder()
        let window = b.element(413_000), pane = b.element(413_001), other = b.element(413_002)
        let nested = b.element(413_003), button = b.element(413_004)
        b.setRole(window, kAXWindowRole as String)
        b.setRole(pane, kAXGroupRole as String)
        b.setAttribute(pane, kAXDescriptionAttribute as String, "Browser")
        b.setRole(other, kAXGroupRole as String)
        b.setAttribute(other, kAXDescriptionAttribute as String, "Inspector")
        // Not a direct child of the window, and not a group: neither is the pane.
        b.setRole(nested, kAXGroupRole as String)
        b.setAttribute(nested, kAXDescriptionAttribute as String, "Browser")
        b.setRole(button, kAXCheckBoxRole as String)
        b.setAttribute(button, kAXDescriptionAttribute as String, "Browser")
        b.setChildren(other, [nested])
        b.setChildren(window, [pane, other, button])
        return (b, window, pane, other)
    }

    @Test func findsOnlyTheTopLevelGroupCalledBrowser() {
        let (b, window, pane, _) = tree()
        let found = BrowserPaneOpacity.panes(
            inWindows: [window],
            children: { b.makeAXRuntime().children($0) },
            string: { b.attributeValue($0, $1) as? String })
        #expect(found.count == 1)
        #expect(found.first.map { CFEqual($0, pane) } == true)
    }

    @Test func aKnownPaneReadsAsChildlessThroughEveryNativeChildRead() {
        let (_, _, pane, other) = tree()
        BrowserPaneOpacity.setPanesForTesting([pane])
        defer { BrowserPaneOpacity.setPanesForTesting([]) }
        let production = AXHelpers.Runtime.production
        #expect(BrowserPaneOpacity.hidesChildren(of: pane))
        #expect(!BrowserPaneOpacity.hidesChildren(of: other))
        #expect(production.children(pane).isEmpty)
        #expect(production.childCount(pane) == 0)
        #expect((production.attributeValue(pane, kAXChildrenAttribute as String) as? [AnyObject])?.isEmpty == true)
        guard case .success(let viaResult) = AXHelpers.childrenResult(pane, runtime: production) else {
            Issue.record("The pane's children read must answer, not fail")
            return
        }
        #expect(viaResult.isEmpty)
    }

    @Test func thePaneIsReadableInsideAnExplicitScope() {
        let (_, _, pane, _) = tree()
        BrowserPaneOpacity.setPanesForTesting([pane])
        defer { BrowserPaneOpacity.setPanesForTesting([]) }
        #expect(BrowserPaneOpacity.hidesChildren(of: pane))
        BrowserPaneOpacity.withPaneReadable {
            #expect(!BrowserPaneOpacity.hidesChildren(of: pane))
        }
    }
}
