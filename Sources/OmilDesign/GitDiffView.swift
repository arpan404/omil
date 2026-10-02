import SwiftUI
import OmilCore

/// The Changes view, shown the way git shows a diff: the original line marked
/// "−" on a red tint and the cleaned line marked "+" on a green tint, with the
/// exact words that changed highlighted inside each line.
public struct GitDiffView: View {
    private let lines: TranscriptDiff.Lines
    private let removed: Color
    private let added: Color
    private let font: Font

    public init(raw: String, cleaned: String, removed: Color, added: Color, font: Font = .system(.body, design: .monospaced)) {
        self.lines = TranscriptDiff.lines(raw: raw, cleaned: cleaned)
        self.removed = removed
        self.added = added
        self.font = font
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            DiffLine(sign: "−", tokens: lines.original, changed: .removed, tint: removed, font: font)
                .accessibilityLabel("Original: \(Self.plain(lines.original))")
            DiffLine(sign: "+", tokens: lines.cleaned, changed: .added, tint: added, font: font)
                .accessibilityLabel("Cleaned: \(Self.plain(lines.cleaned))")
        }
    }

    static func plain(_ tokens: [TranscriptDiff.Token]) -> String {
        var out = ""
        for (i, token) in tokens.enumerated() {
            if i > 0 && !TranscriptDiff.attachesToPrevious(token.text) { out += " " }
            out += token.text
        }
        return out
    }
}

private struct DiffLine: View {
    let sign: String
    let tokens: [TranscriptDiff.Token]
    let changed: TranscriptDiff.Kind
    let tint: Color
    let font: Font

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(sign)
                .fontWeight(.semibold)
                .foregroundStyle(tint)
                .frame(width: 12)
            Text(attributed)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(font)
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityElement(children: .ignore)
    }

    /// Unchanged words stay plain; changed words get a stronger tint, like a word diff on GitHub.
    private var attributed: AttributedString {
        var result = AttributedString()
        for (index, token) in tokens.enumerated() {
            if index > 0 && !TranscriptDiff.attachesToPrevious(token.text) {
                result += AttributedString(" ")
            }
            var piece = AttributedString(token.text)
            if token.kind == changed {
                piece.backgroundColor = tint.opacity(0.24)
            }
            result += piece
        }
        return result
    }
}
