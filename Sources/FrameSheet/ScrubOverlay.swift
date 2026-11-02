import FrameSheetCore
import SwiftUI

/// The scrub overlay over the main area (§7): Cancel bar on top, then the
/// low neighbour, the live frame with its CHANGE TO / ADD … label, and the
/// high neighbour. Placement comes from `ScrubLayout`, so the frames line up
/// with the pointer mapping in `AppModel`.
struct ScrubOverlay: View {
    @Environment(AppModel.self) private var model
    let session: ScrubSession
    let file: MovieFile

    var body: some View {
        let layout = model.scrubLayout(for: file)
        ZStack(alignment: .topLeading) {
            Theme.crust.opacity(0.92)
            CancelBar(highlighted: session.overCancel, keyboard: session.keyboard, sticky: session.sticky)
                .frame(height: ScrubLayout.cancelBarHeight)
                .frame(maxWidth: .infinity)
            neighbour(session.lowFrame, in: layout.left)
            neighbour(session.highFrame, in: layout.right)
            live(in: layout.live)
        }
        // While dragging, the drag that started the scrub tracks the pointer.
        // A sticky scrub follows the pointer itself and confirms on a click;
        // a keyboard scrub takes clicks on the Cancel bar.
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .named(MainArea.space)) { phase in
            guard session.sticky, case .active(let point) = phase else { return }
            model.scrubMoved(x: point.x, y: point.y, modifiers: ScrubModifiers(NSEvent.modifierFlags))
        }
        .onTapGesture {
            if session.sticky { model.endScrub() }
        }
        .allowsHitTesting(session.keyboard || session.sticky)
    }

    private func neighbour(_ frame: Int, in rect: CGRect) -> some View {
        VStack(spacing: Theme.space1) {
            FrameImage(image: model.image(file: file.id, frame: frame, width: AppModel.thumbWidth))
                .frame(width: rect.width, height: rect.height)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSm))
                .opacity(0.6)
            Text(FrameInfoText.text(.frames, frame: frame, fps: file.fps) ?? "")
                .font(Theme.mono(12))
                .foregroundStyle(Theme.textMuted)
        }
        .frame(width: rect.width)
        .offset(x: rect.minX, y: rect.minY)
    }

    private func live(in rect: CGRect) -> some View {
        VStack(spacing: Theme.space1) {
            HStack(spacing: Theme.space2) {
                Text(session.action.label)
                    .font(Theme.sans(13, medium: true))
                    .foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, Theme.space2)
                    .padding(.vertical, 2)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.radiusSm))
                Text("\(FrameInfoText.text(.frames, frame: session.frame, fps: file.fps) ?? "")  \(Timecode.string(frames: session.frame, fps: file.fps))")
                    .font(Theme.mono(13, medium: true))
                    .foregroundStyle(Theme.text)
            }
            .frame(height: ScrubLayout.labelHeight - Theme.space1)
            FrameImage(image: model.scrubImage)
                .frame(width: rect.width, height: rect.height)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSm))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusSm).strokeBorder(Theme.accent, lineWidth: 2))
            if session.sticky {
                Text("Move to scrub  ·  click to confirm  ·  Esc cancels")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textMuted)
            } else if session.keyboard {
                Text("← → step  ·  ⇧ ×10  ·  Return confirms  ·  Esc cancels")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .frame(width: rect.width)
        .offset(x: rect.minX, y: rect.minY - ScrubLayout.labelHeight)
    }
}

private struct FrameImage: View {
    let image: CGImage?

    var body: some View {
        if let image {
            Image(decorative: image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            Theme.surface
        }
    }
}

private struct CancelBar: View {
    @Environment(AppModel.self) private var model
    let highlighted: Bool
    let keyboard: Bool
    let sticky: Bool

    var body: some View {
        Button {
            model.cancelScrub()
        } label: {
            Text(keyboard || sticky ? "Cancel (Esc)" : "Release here to cancel")
                .font(Theme.sans(13, medium: true))
                .foregroundStyle(highlighted ? Theme.onAccent : Theme.text)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(highlighted ? Theme.danger : Theme.mantle)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
