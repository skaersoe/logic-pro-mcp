@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

// Logic 13.0 attaches the Display Mode popup's AXMenu to the toolbar item that holds the popup,
// not to the popup. Layout and titles read live on 2026-11-15 (Logic 13.0, en-US, macOS 27.0.1):
//
//     AXWindow > AXToolbar "Control Bar" > AXGroup > AXGroup "Transport Display" > AXPopUpButton
//
// After AXShowMenu the AXMenu is a child of the unlabelled AXGroup; the popup has no children.
private final class HostedMenuActions: @unchecked Sendable {
    var calls: [(id: Int, action: String)] = []
}

private struct Logic13DisplayModeFixture {
    let builder = FakeAXRuntimeBuilder()
    let window: AXUIElement
    let toolbar: AXUIElement
    let item: AXUIElement
    let display: AXUIElement
    let popup: AXUIElement
    let menu: AXUIElement
    let otherItem: AXUIElement
    let items: [String: AXUIElement]
    let actions = HostedMenuActions()

    static let titles = [
        "Beats & Project", "Beats & Project (Large)", "Beats & Time", "Beats & Time (Large)",
        "Beats", "Time", "Custom",
    ]

    init(current: String = "Beats & Project") {
        window = builder.element(213_000)
        toolbar = builder.element(213_001)
        item = builder.element(213_002)
        display = builder.element(213_003)
        popup = builder.element(213_004)
        menu = builder.element(213_005)
        otherItem = builder.element(213_006)
        let library = builder.element(213_007)
        builder.setRole(window, kAXWindowRole as String)
        builder.setAttribute(window, kAXTitleAttribute as String, "logic-13-shakedown - Tracks")
        builder.setAttribute(window, kAXDocumentAttribute as String, "file:///tmp/logic-13-shakedown.logicx")
        builder.setRole(toolbar, kAXToolbarRole as String)
        builder.setAttribute(toolbar, kAXDescriptionAttribute as String, "Control Bar")
        builder.setRole(item, kAXGroupRole as String)
        builder.setRole(otherItem, kAXGroupRole as String)
        builder.setRole(library, kAXCheckBoxRole as String)
        builder.setChildren(library, [])
        builder.setChildren(otherItem, [library])
        builder.setRole(display, kAXGroupRole as String)
        builder.setAttribute(display, kAXDescriptionAttribute as String, "Transport Display")
        builder.setRole(popup, kAXPopUpButtonRole as String)
        builder.setAttribute(popup, kAXDescriptionAttribute as String, "Display Mode")
        builder.setAttribute(popup, kAXValueAttribute as String, current)
        builder.setActionNames(popup, [kAXShowMenuAction as String, kAXPressAction as String])
        builder.setRole(menu, kAXMenuRole as String)
        builder.setActionNames(menu, [kAXCancelAction as String])
        var items: [String: AXUIElement] = [:]
        var ordered: [AXUIElement] = []
        for (offset, title) in Self.titles.enumerated() {
            let element = builder.element(213_010 + offset)
            builder.setRole(element, kAXMenuItemRole as String)
            builder.setAttribute(element, kAXTitleAttribute as String, title)
            builder.setAttribute(element, kAXEnabledAttribute as String, true)
            builder.setActionNames(element, [kAXPressAction as String])
            builder.setChildren(element, [])
            if title == current { builder.setAttribute(element, "AXMenuItemMarkChar", "✓") }
            items[title] = element
            ordered.append(element)
        }
        self.items = items
        builder.setChildren(menu, ordered)
        builder.setChildren(popup, [])
        builder.setChildren(display, [popup])
        builder.setChildren(item, [display])
        builder.setChildren(toolbar, [otherItem, item])
        builder.setChildren(window, [toolbar])
    }

    /// `unreadableItem`: the sibling toolbar item answers its children read with cannot-complete.
    func runtime(unreadableItem: Bool = false) -> AXHelpers.Runtime {
        let builder = builder, popup = popup, menu = menu, item = item, display = display
        let otherItem = otherItem, items = items, actions = actions
        return builder.makeAXRuntime(
            childrenResultHandler: { element in
                guard unreadableItem, CFEqual(element, otherItem) else { return nil }
                return .failure(.init(raw: AXError.cannotComplete.rawValue))
            },
            setAttributeHandler: nil,
            performActionHandler: { element, action in
                actions.calls.append((builder.elementID(element), action))
                if action == kAXShowMenuAction as String, CFEqual(element, popup) {
                    builder.setChildren(item, [display, menu])
                    return true
                }
                if action == kAXCancelAction as String, CFEqual(element, menu) {
                    builder.setChildren(item, [display])
                    return true
                }
                if action == kAXPressAction as String,
                   let title = builder.attributeValue(element, kAXTitleAttribute as String) as? String {
                    builder.setAttribute(popup, kAXValueAttribute as String, title)
                    for (candidate, element) in items {
                        if candidate == title {
                            builder.setAttribute(element, "AXMenuItemMarkChar", "✓")
                        } else {
                            builder.removeAttribute(element, "AXMenuItemMarkChar")
                        }
                    }
                    builder.setChildren(item, [display])
                }
                return true
            })
    }

    var value: String? { builder.attributeValue(popup, kAXValueAttribute as String) as? String }
    func id(_ title: String) -> Int { builder.elementID(items[title]!) }
}

@Test func testLogic13MenuParentsAreThePopupAndItsToolbarPath() {
    let fixture = Logic13DisplayModeFixture()
    let parents = ControlBarMenuHost.menuParents(
        of: fixture.popup, in: fixture.window, runtime: fixture.runtime())
    let expected = [fixture.popup, fixture.toolbar, fixture.item, fixture.display]
    #expect(parents?.count == expected.count)
    #expect(zip(parents ?? [], expected).allSatisfy { CFEqual($0, $1) })
}

@Test func testLogic12LayoutKeepsThePopupAsTheOnlyMenuParent() {
    let builder = FakeAXRuntimeBuilder()
    let window = builder.element(212_000), bar = builder.element(212_001), popup = builder.element(212_002)
    builder.setRole(window, kAXWindowRole as String)
    builder.setRole(bar, kAXGroupRole as String)
    builder.setRole(popup, kAXPopUpButtonRole as String)
    builder.setChildren(popup, [])
    builder.setChildren(bar, [popup])
    builder.setChildren(window, [bar])
    let parents = ControlBarMenuHost.menuParents(of: popup, in: window, runtime: builder.makeAXRuntime())
    #expect(parents?.count == 1)
    #expect(parents?.first.map { CFEqual($0, popup) } == true)
}

@Test func testLogic13MenuParentsRefuseAnUnreadableToolbarBranch() {
    let fixture = Logic13DisplayModeFixture()
    // The unread sibling is searched before the item that holds the popup. The popup is then
    // found, so the path is known and the unread sibling does not matter.
    #expect(ControlBarMenuHost.menuParents(
        of: fixture.popup, in: fixture.window, runtime: fixture.runtime(unreadableItem: true)) != nil)
    // A popup that is in no readable branch may be in the unread one: the host is not known.
    let stranger = fixture.builder.element(213_099)
    #expect(ControlBarMenuHost.menuParents(
        of: stranger, in: fixture.window, runtime: fixture.runtime(unreadableItem: true)) == nil)
}

@Test func testLogic13DisplayModeSwitchSelectsBeatsThroughTheHostedMenuAndRestores() {
    let fixture = Logic13DisplayModeFixture()
    let runtime = fixture.runtime()
    guard case .switched(let lease) = ControlBarDisplayMode.selectBeats(
        in: fixture.popup, window: fixture.window, runtime: runtime) else {
        Issue.record("The hosted menu must be found and Beats pressed")
        return
    }
    #expect(lease.original == "Beats & Project")
    #expect(fixture.value == "Beats")
    #expect(ControlBarDisplayMode.restore(
        lease, window: fixture.window, popup: fixture.popup, runtime: runtime) == .restored)
    #expect(fixture.value == "Beats & Project")
    let presses = fixture.actions.calls.filter { $0.action == kAXPressAction as String }.map(\.id)
    #expect(presses == [fixture.id("Beats"), fixture.id("Beats & Project")])
    #expect(ControlBarMenuHost.menus(
        under: [fixture.popup, fixture.toolbar, fixture.item, fixture.display], runtime: runtime)?.isEmpty == true)
}

@Test func testLogic13DisplayModeSwitchCancelsTheHostedMenuWhenAlreadyBeats() {
    let fixture = Logic13DisplayModeFixture(current: "Beats")
    #expect(ControlBarDisplayMode.selectBeats(
        in: fixture.popup, window: fixture.window, runtime: fixture.runtime())
        == .unavailable("display_mode_already_beats"))
    #expect(fixture.actions.calls.map(\.action) == [kAXShowMenuAction as String, kAXCancelAction as String])
}

@Test func testLogic13DisplayModeSwitchRefusesAMenuAlreadyOpenAtTheHost() {
    let fixture = Logic13DisplayModeFixture()
    fixture.builder.setChildren(fixture.item, [fixture.display, fixture.menu])
    #expect(ControlBarDisplayMode.selectBeats(
        in: fixture.popup, window: fixture.window, runtime: fixture.runtime())
        == .unsettled(nil, "display_mode_menu_already_open"))
    #expect(fixture.actions.calls.isEmpty)
}
