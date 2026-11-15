@preconcurrency import ApplicationServices
import Foundation

/// Mute, solo and record-enable through the inspector's channel strip.
///
/// The track header's Mute, Solo and Record Enable checkboxes accept `AXPress` and do not change
/// (Logic 12.3 per `trackMuteKeyCode`; measured again 2026-11-15 on Logic 13.0, en-US: Solo read
/// 0 for a second after the press, with Logic frontmost and not). The key-command rung that
/// follows needs Logic frontmost and a safe keyboard focus, and types into whatever holds that
/// focus. On 2026-11-15 it was refused while another application was in front.
///
/// The inspector shows the channel strip of the selected track. Its `mute`, `solo` and `record`
/// buttons (`AXButton`, subrole `AXSwitch`) do change the track on `AXPress`: Solo went from
/// `off` to `on` within 250 ms with another application frontmost. No key is posted.
///
/// The rung presses only after the target is the sole selected track and the inspector strip
/// carries the target's name. When either is not established it presses nothing and the ladder
/// goes on to the key-command rung, as before.
///
/// The rung is used on Logic 13 and later, where it was measured. On earlier versions, and when
/// the version cannot be read, the ladder is unchanged.
extension AccessibilityChannel {
    static let inspectorStripSettleAttempts = 12
    static let inspectorStripMinimumLogicMajorVersion = 13

    /// The inspector-strip rung when the running Logic is version 13 or later; otherwise none.
    static func inspectorStripRungs(
        buttonName: String,
        index: Int,
        desired: Bool,
        readValue: @escaping () -> Bool?,
        runtime: AXLogicProElements.Runtime,
        processRuntime: ProcessUtils.Runtime
    ) -> [TrackToggleRung] {
        guard let version = ProcessUtils.logicProVersion(runtime: processRuntime),
              let major = Int(version.split(separator: ".").first ?? ""),
              major >= inspectorStripMinimumLogicMajorVersion else { return [] }
        return [inspectorStripRung(
            buttonName: buttonName, index: index, desired: desired, readValue: readValue, runtime: runtime)]
    }

    static func inspectorStripRung(
        buttonName: String,
        index: Int,
        desired: Bool,
        readValue: @escaping () -> Bool?,
        runtime: AXLogicProElements.Runtime
    ) -> TrackToggleRung {
        ("inspector-strip", 600, { _ in
            if readValue() == desired { return .alreadyLanded }
            guard let button = inspectorStripButton(buttonName: buttonName, index: index, runtime: runtime) else {
                return .actuated   // Nothing pressed; the halt barrier and the next rung decide.
            }
            // Same halt barrier as the key rung: never press a toggle that already landed.
            if readValue() == desired { return .alreadyLanded }
            guard selectionIsExclusive(index: index, runtime: runtime) else { return .actuated }
            _ = AXHelpers.performAction(button, kAXPressAction as String, runtime: runtime.ax)
            return .actuated
        })
    }

    /// The inspector strip's button for `buttonName` ("Mute", "Solo" or "Record") once the track
    /// at `index` is the sole selection and the inspector strip carries its name; else nil.
    static func inspectorStripButton(
        buttonName: String, index: Int, runtime: AXLogicProElements.Runtime
    ) -> AXUIElement? {
        let labels: AXLocalePolicy.LabelSet
        switch buttonName {
        case "Mute": labels = AXLocalePolicy.trackMuteButton
        case "Solo": labels = AXLocalePolicy.trackSoloButton
        case "Record": labels = AXLocalePolicy.trackRecordButton
        default: return nil
        }
        guard let name = AXLogicProElements.trackName(at: index, runtime: runtime), !name.isEmpty,
              confirmExclusiveSelection(index: index, runtime: runtime),
              let window = AXLogicProElements.mainWindow(runtime: runtime),
              let strip = AXLogicProElements.inspectorChannelStrip(
                  named: name, in: window, settleAttempts: inspectorStripSettleAttempts,
                  runtime: runtime.ax) else { return nil }
        let wanted = Set(labels.labels.map { $0.lowercased() })
        let buttons = AXHelpers.getChildren(strip, runtime: runtime.ax).filter { child in
            guard AXHelpers.getRole(child, runtime: runtime.ax) == kAXButtonRole as String,
                  let description = AXHelpers.getDescription(child, runtime: runtime.ax) else { return false }
            return wanted.contains(description.lowercased())
        }
        // Exactly one, or no answer.
        return buttons.count == 1 ? buttons[0] : nil
    }
}
