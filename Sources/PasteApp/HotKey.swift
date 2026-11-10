import Carbon.HIToolbox
import Foundation

struct HotKeyError: Error, LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
        status == OSStatus(eventHotKeyExistsErr)
            ? "That shortcut is already used by the system or another app."
            : "That shortcut couldn't be registered (error \(status))."
    }
}

/// Global hotkey via Carbon RegisterEventHotKey. Several can coexist; each has a unique `id`
/// and the shared event handler dispatches by the pressed hotkey's ID.
final class HotKey {
    static let defaultKeyCode: UInt32 = 9
    static let defaultModifiers: UInt32 = UInt32(shiftKey | cmdKey)

    private static let signature = OSType(0x5043_4C50) // 'PCLP'
    /// Main-thread only (registered and dispatched on the main thread).
    nonisolated(unsafe) private static var handlers: [UInt32: (token: UUID, run: @MainActor () -> Void)] = [:]
    nonisolated(unsafe) private static var handlerRef: EventHandlerRef?

    private var ref: EventHotKeyRef?
    private let id: UInt32
    private let token = UUID()
    /// Status of the most recent registration attempt (noErr when registered).
    private(set) var registrationStatus: OSStatus = noErr

    init(id: UInt32 = 1, keyCode: UInt32 = HotKey.defaultKeyCode, modifiers: UInt32 = HotKey.defaultModifiers,
         handler: @escaping @MainActor () -> Void) {
        self.id = id
        Self.installHandlerIfNeeded()
        Self.handlers[id] = (token, handler)
        registrationStatus = register(keyCode: keyCode, modifiers: modifiers)
    }

    private var current: (keyCode: UInt32, modifiers: UInt32)?

    private func register(keyCode: UInt32, modifiers: UInt32) -> OSStatus {
        var newRef: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: Self.signature, id: id),
                                         GetApplicationEventTarget(), 0, &newRef)
        current = (keyCode, modifiers)   // remember the intended combo even on failure, so a retry is possible
        if status == noErr { ref = newRef }
        return status
    }

    /// Temporarily releases the OS registration (keeps the combination) so a recorder can capture it.
    func suspend() {
        if let r = ref { UnregisterEventHotKey(r); ref = nil }
    }

    /// Re-registers the combination released by `suspend()`.
    /// Returns the status (noErr when registered). Safe to call repeatedly: it is also the retry path.
    @discardableResult
    func resume() -> OSStatus {
        guard ref == nil, let c = current else { return registrationStatus }
        registrationStatus = register(keyCode: c.keyCode, modifiers: c.modifiers)
        return registrationStatus
    }

    /// The combination this hotkey is meant to have (registered or not).
    var combination: (keyCode: UInt32, modifiers: UInt32)? { current }

    /// Re-registers with a new combination. On failure the previous combination stays active and this throws.
    func update(keyCode: UInt32, modifiers: UInt32) throws {
        let previous = current
        // The same app can't register the same combination twice, so release the old one first.
        if let r = ref { UnregisterEventHotKey(r); ref = nil }
        let status = register(keyCode: keyCode, modifiers: modifiers)
        if status != noErr {
            // Put the previous combo back (and keep it as the intended one, even if re-registering fails).
            if let previous { registrationStatus = register(keyCode: previous.keyCode, modifiers: previous.modifiers) }
            throw HotKeyError(status: status)
        }
        registrationStatus = noErr
    }

    private static func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hkID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            guard status == noErr, hkID.signature == HotKey.signature else { return OSStatus(eventNotHandledErr) }
            let id = hkID.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated { HotKey.handlers[id]?.run() }
            }
            return noErr
        }, 1, &spec, nil, &handlerRef)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        let id = id, token = token
        DispatchQueue.main.async { if HotKey.handlers[id]?.token == token { HotKey.handlers[id] = nil } }
    }
}
