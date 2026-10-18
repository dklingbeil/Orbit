import AppKit

/// Small modal prompts for operations that need a value.
@MainActor
enum Prompts {
    static func text(title: String, message: String, placeholder: String, initial: String) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: initial)
        field.placeholderString = placeholder
        field.frame = CGRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func password(title: String, message: String, confirm: Bool) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        while true {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            let stack = NSStackView()
            stack.orientation = .vertical
            stack.spacing = 8
            let first = NSSecureTextField(frame: CGRect(x: 0, y: 0, width: 260, height: 24))
            first.placeholderString = "Password"
            stack.addArrangedSubview(first)
            let second = NSSecureTextField(frame: CGRect(x: 0, y: 0, width: 260, height: 24))
            second.placeholderString = "Verify password"
            if confirm { stack.addArrangedSubview(second) }
            stack.frame = CGRect(x: 0, y: 0, width: 260, height: confirm ? 56 : 24)
            alert.accessoryView = stack
            alert.window.initialFirstResponder = first
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            if first.stringValue.isEmpty { continue }
            if confirm && first.stringValue != second.stringValue {
                let mismatch = NSAlert()
                mismatch.messageText = "The passwords don't match."
                mismatch.runModal()
                continue
            }
            return first.stringValue
        }
    }
}
