import AppKit
import Carbon.HIToolbox

/// Global shortcuts use Carbon so they work without Accessibility access.
@MainActor
final class HotKey {
    static let shared = HotKey()

    private let signature = OSType(0x5754_5050) // "WTPP"
    private var popoverRef: EventHotKeyRef?
    private var screenshotRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var screenshotProcess: Process?

    var isScreenshotRegistered: Bool { screenshotRef != nil }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            if popoverRef == nil {
                popoverRef = register(key: UInt32(kVK_ANSI_P), modifiers: UInt32(cmdKey | optionKey), id: 1)
            }
        } else {
            if let popoverRef { UnregisterEventHotKey(popoverRef) }
            popoverRef = nil
            removeHandlerIfUnused()
        }
    }

    @discardableResult
    func setScreenshotEnabled(_ enabled: Bool) -> Bool {
        if enabled {
            if screenshotRef == nil {
                screenshotRef = register(key: UInt32(kVK_ANSI_X), modifiers: UInt32(cmdKey), id: 2,
                                         options: OptionBits(kEventHotKeyExclusive))
            }
        } else {
            if let screenshotRef { UnregisterEventHotKey(screenshotRef) }
            screenshotRef = nil
            removeHandlerIfUnused()
        }
        return !enabled || screenshotRef != nil
    }

    private func register(key: UInt32, modifiers: UInt32, id: UInt32, options: OptionBits = 0) -> EventHotKeyRef? {
        guard installHandler() else { return nil }
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        guard RegisterEventHotKey(key, modifiers, hotKeyID, GetApplicationEventTarget(), options, &ref) == noErr else {
            removeHandlerIfUnused()
            return nil
        }
        return ref
    }

    private func installHandler() -> Bool {
        guard handlerRef == nil else { return true }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard result == noErr, hotKeyID.signature == OSType(0x5754_5050) else { return OSStatus(eventNotHandledErr) }
            let id = hotKeyID.id
            DispatchQueue.main.async {
                switch id {
                case 1:
                    Usage.record(.shortcut)
                    StatusItemOpener.open()
                case 2:
                    HotKey.shared.captureSelection()
                default:
                    break
                }
            }
            return noErr
        }, 1, &eventType, nil, &handlerRef)
        return status == noErr
    }

    private func removeHandlerIfUnused() {
        guard popoverRef == nil, screenshotRef == nil, let handlerRef else { return }
        RemoveEventHandler(handlerRef)
        self.handlerRef = nil
    }

    private func captureSelection() {
        guard screenshotProcess == nil else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-d", "-i", "-s", "-c"]
        process.terminationHandler = { _ in
            DispatchQueue.main.async { HotKey.shared.screenshotProcess = nil }
        }
        screenshotProcess = process
        do {
            try process.run()
        } catch {
            screenshotProcess = nil
            let alert = NSAlert()
            alert.messageText = L10n.text("Couldn’t start screenshot")
            alert.informativeText = error.localizedDescription
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}
