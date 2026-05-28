import SwiftUI

struct EditorialTextField: View {
    /// Build 40 — was `String`, which silently picked SwiftUI's
    /// `TextField(_ titleKey: String, ...)` verbatim overload and
    /// bypassed the catalog. Changing to `LocalizedStringResource`
    /// forces every literal call site through the catalog
    /// (literals coerce via `ExpressibleByStringLiteral`), so
    /// existing `EditorialTextField(placeholder: "Email")` calls
    /// render Turkish when the locale is `tr` once the matching
    /// catalog keys are present. Same migration that
    /// `PrimaryButton.title` got in Build 27.
    let placeholder: LocalizedStringResource
    @Binding var text: String
    var isSecure: Bool = false
    var validationMessage: String?
    var keyboardType: UIKeyboardType = .default
    var textContentType: UITextContentType?

    var body: some View {
        // SwiftUI's TextField/SecureField initializers don't have a
        // direct `LocalizedStringResource` overload (only
        // `LocalizedStringKey` or `StringProtocol`), so resolve the
        // resource to a String once via the catalog and hand that to
        // the system widget. `String(localized:)` performs the
        // lookup against the catalog, honouring the device locale.
        let resolvedPlaceholder = String(localized: placeholder)
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Group {
                if isSecure {
                    SecureField(resolvedPlaceholder, text: $text)
                        .textContentType(textContentType)
                } else {
                    TextField(resolvedPlaceholder, text: $text)
                        .keyboardType(keyboardType)
                        .textContentType(textContentType)
                        .autocorrectionDisabled()
                }
            }
            .font(Theme.Fonts.body)
            .padding(.horizontal, Theme.Spacing.md)
            .frame(height: 48)
            .background(Color(Theme.Colors.surface))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.button))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.button)
                    .stroke(
                        validationMessage != nil ? Color(Theme.Colors.destructive) : Color(Theme.Colors.border),
                        lineWidth: 1
                    )
            )

            if let message = validationMessage {
                Text(message)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Color(Theme.Colors.destructive))
                    .padding(.leading, Theme.Spacing.xs)
            }
        }
    }
}

#Preview {
    VStack(spacing: 16) {
        EditorialTextField(placeholder: "Email", text: .constant(""))
        EditorialTextField(placeholder: "Password", text: .constant("abc"), isSecure: true, validationMessage: "Too short")
    }
    .padding()
}
