import SwiftUI

struct EditorialTextField: View {
    let placeholder: String
    @Binding var text: String
    var isSecure: Bool = false
    var validationMessage: String?
    var keyboardType: UIKeyboardType = .default
    var textContentType: UITextContentType?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Group {
                if isSecure {
                    SecureField(placeholder, text: $text)
                        .textContentType(textContentType)
                } else {
                    TextField(placeholder, text: $text)
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
