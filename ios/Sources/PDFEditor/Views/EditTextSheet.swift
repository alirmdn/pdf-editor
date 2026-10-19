import SwiftUI

/// Editing one paragraph with the system keyboard. iOS handles Arabic natively here: right-to-left
/// typing, the caret, selection handles and copy/paste; the engine then draws the result on the
/// page with properly joined letters.
struct EditTextSheet: View {
    let paragraph: Paragraph
    let apply: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @FocusState private var focused: Bool

    init(paragraph: Paragraph, apply: @escaping (String) -> Void) {
        self.paragraph = paragraph
        self.apply = apply
        _text = State(initialValue: paragraph.text)
    }

    private var rightToLeft: Bool {
        text.unicodeScalars.first { CharacterSet.letters.contains($0) }.map { (0x0590...0x08FF).contains($0.value) || (0xFB1D...0xFEFC).contains($0.value) }
            ?? paragraph.isRightToLeft
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                TextEditor(text: $text)
                    .focused($focused)
                    .font(.system(size: 17))
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.accent.opacity(0.5)))
                    .multilineTextAlignment(rightToLeft ? .trailing : .leading)
                    .environment(\.layoutDirection, rightToLeft ? .rightToLeft : .leftToRight)
                Text("The text keeps this paragraph's position, size and colour. Arabic is drawn right-aligned with joined letters.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .navigationTitle("Edit Text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { apply(text) }
                        .bold()
                        .disabled(text == paragraph.text)
                }
            }
            .onAppear { focused = true }
        }
    }
}
