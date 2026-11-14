import Carbon
import Foundation

public struct GlobalHotKey: Hashable, Sendable {
    public let identifier: UInt32
    public let keyCode: UInt32
    public let modifiers: UInt32

    public init(identifier: UInt32, keyCode: UInt32, modifiers: UInt32) {
        self.identifier = identifier
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

public extension GlobalHotKey {
    static let toggleDictation = GlobalHotKey(identifier: 1, keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(cmdKey | optionKey))
    static let captureClipboard = GlobalHotKey(identifier: 2, keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | optionKey))
}

public final class GlobalHotKeyCenter {
    public static let shared = GlobalHotKeyCenter()
    private static let signature = OSType(0x564F534B)
    private var eventHandler: EventHandlerRef?
    private var registrations: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]

    private init() {}

    @discardableResult
    public func register(_ hotKey: GlobalHotKey, handler: @escaping () -> Void) -> Bool {
        unregister(hotKey.identifier)
        guard installEventHandlerIfNeeded() else { return false }
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(hotKey.keyCode, hotKey.modifiers, EventHotKeyID(signature: Self.signature, id: hotKey.identifier), GetApplicationEventTarget(), 0, &reference)
        guard status == noErr, let reference else { return false }
        registrations[hotKey.identifier] = reference
        handlers[hotKey.identifier] = handler
        return true
    }

    public func unregister(_ identifier: UInt32) {
        if let reference = registrations.removeValue(forKey: identifier) {
            UnregisterEventHotKey(reference)
        }
        handlers[identifier] = nil
    }

    func dispatch(_ identifier: UInt32) {
        DispatchQueue.main.async { [weak self] in
            guard let handler = self?.handlers[identifier] else { return }
            handler()
        }
    }

    private func installEventHandlerIfNeeded() -> Bool {
        if eventHandler != nil { return true }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), globalHotKeyEventHandler, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        return status == noErr
    }
}

private func globalHotKeyEventHandler(_ call: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var identifier = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
    guard status == noErr else { return status }
    Unmanaged<GlobalHotKeyCenter>.fromOpaque(userData).takeUnretainedValue().dispatch(identifier.id)
    return noErr
}
