@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

// Logic 13.0 acknowledges the AXSelectedChildren write on the `Tracks header` group and leaves
// the selection where it was. AXShowMenu on a header opens its context menu and selects that
// header alone; the menu is one AXMenu child of the group and closes on AXCancel.
// Read live on 2026-11-15 (Logic 13.0, en-US, macOS 27.0.1).
private final class SelectionActions: @unchecked Sendable {
    var calls: [(element: AXUIElement, action: String)] = []
}

private struct HeaderFixture {
    let builder = FakeAXRuntimeBuilder()
    let container: AXUIElement
    let menu: AXUIElement
    let headers: [AXUIElement]
    let actions = SelectionActions()

    /// `selected`: the indices selected at the start. `showMenu`: whether headers advertise it.
    init(count: Int = 3, selected: Set<Int> = [0], showMenu: Bool = true, booleanSelection: Bool = true) {
        container = builder.element(513_000)
        menu = builder.element(513_001)
        builder.setRole(container, kAXGroupRole as String)
        builder.setRole(menu, kAXMenuRole as String)
        builder.setActionNames(menu, [kAXCancelAction as String])
        builder.setChildren(menu, [])
        var rows: [AXUIElement] = []
        for index in 0..<count {
            let row = builder.element(513_010 + index)
            builder.setRole(row, kAXLayoutItemRole as String)
            if booleanSelection {
                builder.setAttribute(row, kAXSelectedAttribute as String, selected.contains(index))
            }
            builder.setActionNames(row, showMenu ? [kAXShowMenuAction as String] : [])
            builder.setChildren(row, [])
            rows.append(row)
        }
        headers = rows
        builder.setChildren(container, rows)
    }

    /// `contextMenuSelects`: Logic 13.0's behaviour. A header inside a multiple selection keeps it.
    func runtime(contextMenuSelects: Bool = true, cancelClosesMenu: Bool = true) -> AXHelpers.Runtime {
        let builder = builder, container = container, menu = menu, headers = headers, actions = actions
        return builder.makeAXRuntime(
            setAttributeHandler: nil,
            performActionHandler: { element, action in
                actions.calls.append((element, action))
                if action == kAXShowMenuAction as String,
                   let index = headers.firstIndex(where: { CFEqual($0, element) }) {
                    builder.setChildren(container, headers + [menu])
                    let selectedNow = headers.map {
                        builder.attributeValue($0, kAXSelectedAttribute as String) as? Bool ?? false
                    }
                    let multiple = selectedNow.filter { $0 }.count > 1
                    if contextMenuSelects, !(multiple && selectedNow[index]) {
                        for (offset, header) in headers.enumerated() {
                            builder.setAttribute(header, kAXSelectedAttribute as String, offset == index)
                        }
                    }
                    return false   // Logic 13.0 answers cannotComplete with the menu up.
                }
                if action == kAXCancelAction as String, CFEqual(element, menu) {
                    if cancelClosesMenu { builder.setChildren(container, headers) }
                    return true
                }
                return true
            })
    }

    func select(_ index: Int, _ runtime: AXHelpers.Runtime) -> TrackHeaderContextMenuSelection.Outcome {
        TrackHeaderContextMenuSelection.selectIfWriteWasIgnored(
            target: headers[index], headers: headers, container: container, runtime: runtime)
    }

    var selection: [Bool] {
        headers.map { builder.attributeValue($0, kAXSelectedAttribute as String) as? Bool ?? false }
    }
    func shown(_ index: Int) -> Int {
        actions.calls.filter { $0.action == kAXShowMenuAction as String && CFEqual($0.element, headers[index]) }.count
    }
}

@Test func testContextMenuSelectsTheTargetWhenTheWriteWasIgnored() {
    let fixture = HeaderFixture(selected: [0])
    #expect(fixture.select(2, fixture.runtime()) == .selected)
    #expect(fixture.selection == [false, false, true])
    #expect(fixture.actions.calls.map(\.action) == [kAXShowMenuAction as String, kAXCancelAction as String])
}

@Test func testNothingIsPressedWhenTheWriteTookEffect() {
    // Logic 12: the target is already the sole selection when the settle reads start.
    let fixture = HeaderFixture(selected: [1])
    #expect(fixture.select(1, fixture.runtime()) == .notApplicable)
    #expect(fixture.actions.calls.isEmpty)
}

@Test func testNothingIsPressedWithoutStrictSelectionReadsOrShowMenu() {
    let unreadable = HeaderFixture(booleanSelection: false)
    #expect(unreadable.select(1, unreadable.runtime()) == .notApplicable)
    #expect(unreadable.actions.calls.isEmpty)
    let noMenu = HeaderFixture(showMenu: false)
    #expect(noMenu.select(1, noMenu.runtime()) == .notApplicable)
    #expect(noMenu.actions.calls.isEmpty)
}

@Test func testATargetInsideAMultipleSelectionIsReachedThroughAHeaderOutsideIt() {
    let fixture = HeaderFixture(selected: [0, 1])
    #expect(fixture.select(1, fixture.runtime()) == .selected)
    #expect(fixture.selection == [false, true, false])
    #expect(fixture.shown(2) == 1)
    #expect(fixture.shown(1) == 1)
}

@Test func testEveryHeaderSelectedLeavesNoWayToTheTargetAlone() {
    let fixture = HeaderFixture(selected: [0, 1, 2])
    #expect(fixture.select(1, fixture.runtime()) == .failed("no_header_outside_the_selection"))
    #expect(fixture.actions.calls.isEmpty)
}

@Test func testAMenuThatStaysOpenIsReported() {
    let fixture = HeaderFixture(selected: [0])
    #expect(fixture.select(1, fixture.runtime(cancelClosesMenu: false)) == .failed("context_menu_not_closed"))
}

@Test func testAnIneffectiveContextMenuIsReported() {
    let fixture = HeaderFixture(selected: [0])
    #expect(fixture.select(1, fixture.runtime(contextMenuSelects: false)) == .failed("selection_not_moved"))
    #expect(fixture.selection == [true, false, false])
}

@Test func testAMenuAlreadyOpenIsNotAdopted() {
    let fixture = HeaderFixture(selected: [0])
    fixture.builder.setChildren(fixture.container, fixture.headers + [fixture.menu])
    #expect(fixture.select(1, fixture.runtime()) == .failed("context_menu_already_open"))
    #expect(fixture.actions.calls.isEmpty)
}
