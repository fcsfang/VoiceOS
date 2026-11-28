import SwiftUI
import VoiceOSCore

enum MaterialRowIconKind {
    case recording, externalAudio, video, document, delivery

    init(_ source: SourceRecord) {
        switch source.kind {
        case "audio": self = source.origin == "external" ? .externalAudio : .recording
        case "video": self = .video
        default: self = source.origin == "ai" ? .delivery : .document
        }
    }
}

struct MaterialRowIcon: View {
    @Environment(\.workspacePalette) private var palette
    @Environment(\.colorSchemeContrast) private var contrast
    let kind: MaterialRowIconKind
    var size: CGFloat = 30
    private static let waveformHeights: [CGFloat] = [6, 11, 16, 12, 7]

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        glyph
            .foregroundStyle(ink)
            .frame(width: size, height: size)
            .background {
                shape.fill(LinearGradient(colors: [ink.opacity(0.055), ink.opacity(0.12)],
                                          startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            .overlay { shape.strokeBorder(ink.opacity(contrast == .increased ? 0.45 : 0.19), lineWidth: 0.75) }
            .accessibilityHidden(true)
    }

    private var ink: Color {
        switch kind {
        case .recording, .externalAudio: palette.materialAudio
        case .video: palette.action
        case .document: palette.secondaryText
        case .delivery: palette.outcome
        }
    }

    @ViewBuilder private var glyph: some View {
        switch kind {
        case .recording:
            let scale = size / 30
            HStack(spacing: 1.45 * scale) {
                ForEach(Self.waveformHeights, id: \.self) { height in
                    Capsule().frame(width: 1.9 * scale, height: height * scale)
                }
            }
        case .externalAudio:
            symbol("headphones")
        case .video:
            symbol("play.rectangle")
        case .document:
            symbol("text.document")
        case .delivery:
            symbol("sparkle.text.clipboard")
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .symbolRenderingMode(.monochrome)
            .font(.system(size: size * 0.52, weight: .medium))
    }
}
