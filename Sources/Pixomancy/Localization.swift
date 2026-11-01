import AppKit

// English is the key; uk.lproj/Localizable.strings translates it when macOS runs in Ukrainian.
func L(_ english: String) -> String {
    Bundle.main.localizedString(forKey: english, value: english, table: nil)
}

extension NSMenuItem {
    convenience init(_ english: String, _ action: Selector?, symbol: String? = nil, key: String = "", modifiers: NSEvent.ModifierFlags = .command) {
        self.init(title: L(english), action: action, keyEquivalent: key)
        keyEquivalentModifierMask = modifiers
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }

    func tagged(_ value: Int) -> NSMenuItem {
        tag = value
        return self
    }

    // Shown instead of the item above it while ⌥ is held.
    func alternate() -> NSMenuItem {
        isAlternate = true
        keyEquivalentModifierMask.insert(.option)
        return self
    }
}
