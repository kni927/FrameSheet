import FrameSheetCore
import SwiftUI

/// Movie menu → Edit Rotation, Cropping and Aspect Ratio (§4): MoviePrint's
/// "Set rotation, cropping and aspect ratio" modal
/// (app/components/EditTransformModal.js, MIT,
/// docs/licenses/MoviePrint-LICENSE). Rotation, a crop preset or the crop
/// per edge in the rotated frame's pixels, and an aspect ratio (a preset or
/// custom); the preview shows the rotated poster frame with the crop and the
/// result at the aspect ratio. Update applies it as one undo step.
struct TransformDialog: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let file: MovieFile

    @State private var transform = MovieTransform()
    @State private var aspectChoice = TransformDialog.ownRatio
    @State private var customWidth = 2.0
    @State private var customHeight = 1.0
    @State private var preview: CGImage?
    @State private var loaded = false

    static let ownRatio = "own"
    static let customRatio = "custom"

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space4) {
            Text("Set rotation, cropping and aspect ratio")
                .font(Theme.sectionTitle)
            HStack(alignment: .top, spacing: Theme.space6) {
                controls.frame(width: 280)
                previews.frame(minWidth: 420, maxWidth: .infinity, minHeight: 420, maxHeight: .infinity)
            }
            footer
        }
        .padding(Theme.space6)
        .frame(minWidth: 780, idealWidth: 860, minHeight: 560, idealHeight: 600)
        .background(Theme.base)
        .foregroundStyle(Theme.text)
        .font(Theme.bodySm)
        .onAppear(perform: load)
        .onChange(of: customWidth) { if aspectChoice == Self.customRatio { applyCustomRatio() } }
        .onChange(of: customHeight) { if aspectChoice == Self.customRatio { applyCustomRatio() } }
        .task {
            preview = await model.untransformedFrame(of: file, frame: file.posterFrame, width: 960)
        }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: Theme.space3) {
            Text("Rotation").font(Theme.label)
            Picker("Rotation", selection: rotationBinding) {
                ForEach(TransformOptions.rotations, id: \.degrees) { Text($0.label).tag($0.degrees) }
            }
            .labelsHidden()
            .help("Turn the frames before cropping")

            Text("Crop").font(Theme.label).padding(.top, Theme.space2)
            Menu("Crop presets") {
                Button("Reset") { transform = transform.croppedTo(ratioInv: nil, width: file.width, height: file.height) }
                Divider()
                ForEach(TransformOptions.cropPresets, id: \.label) { preset in
                    Button(preset.label) {
                        transform = transform.croppedTo(ratioInv: preset.ratioInv, width: file.width, height: file.height)
                    }
                }
            }
            .help("Crop top and bottom, or left and right, to a frame ratio")
            Grid(alignment: .leading, horizontalSpacing: Theme.space3, verticalSpacing: Theme.space2) {
                GridRow {
                    cropField("From top", \.cropTop)
                    cropField("From bottom", \.cropBottom)
                }
                GridRow {
                    cropField("From left", \.cropLeft)
                    cropField("From right", \.cropRight)
                }
            }

            Text("Aspect ratio").font(Theme.label).padding(.top, Theme.space2)
            Picker("Aspect ratio", selection: aspectBinding) {
                Text("Frame's own").tag(Self.ownRatio)
                ForEach(TransformOptions.aspectRatios, id: \.label) { Text($0.label).tag($0.label) }
                Text("Custom").tag(Self.customRatio)
            }
            .labelsHidden()
            .help("Width to height the thumbs are shown and saved at; the frames are stretched to it")
            if aspectChoice == Self.customRatio {
                HStack(spacing: Theme.space2) {
                    TextField("Width", value: $customWidth, format: .number.precision(.fractionLength(0...3)))
                        .frame(width: 70)
                        .help("Width part of the ratio")
                    Text(":")
                    TextField("Height", value: $customHeight, format: .number.precision(.fractionLength(0...3)))
                        .frame(width: 70)
                        .help("Height part of the ratio")
                }
            }

            let size = transform.outputSize(width: file.width, height: file.height)
            Text("Frame \(file.width) × \(file.height) → \(size.width) × \(size.height) px")
                .font(Theme.panelCaption)
                .foregroundStyle(Theme.textMuted)
                .padding(.top, Theme.space2)
            Spacer(minLength: 0)
        }
    }

    private func cropField(_ title: String, _ edge: WritableKeyPath<MovieTransform, Int>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(Theme.panelCaption).foregroundStyle(Theme.textMuted)
            HStack(spacing: Theme.space1) {
                TextField(title, value: cropBinding(edge), format: .number)
                    .frame(width: 70)
                    .help("Pixels cropped \(title.lowercased()) of the rotated frame")
                Stepper(title, value: cropBinding(edge), in: 0...100_000)
                    .labelsHidden()
                    .help("Pixels cropped \(title.lowercased()) of the rotated frame")
            }
        }
    }

    // MARK: - Previews

    private var previews: some View {
        VStack(spacing: Theme.space3) {
            GeometryReader { proxy in
                rotatedPreview(in: proxy.size)
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .background(Theme.crust, in: RoundedRectangle(cornerRadius: Theme.radiusSm))
            HStack(alignment: .bottom, spacing: Theme.space3) {
                Text("Result").font(Theme.panelCaption).foregroundStyle(Theme.textMuted)
                resultPreview
            }
        }
    }

    /// The rotated poster frame fitted into `size`, the part cropped away
    /// dimmed and the crop outlined.
    @ViewBuilder
    private func rotatedPreview(in size: CGSize) -> some View {
        let (rw, rh) = transform.rotatedSize(width: max(1, file.width), height: max(1, file.height))
        let scale = min(size.width / Double(rw), size.height / Double(rh))
        let shown = CGSize(width: Double(rw) * scale, height: Double(rh) * scale)
        let crop = transform.cropRect(width: file.width, height: file.height)
        let cropRect = CGRect(
            x: Double(crop.x) * scale, y: Double(crop.y) * scale,
            width: Double(crop.width) * scale, height: Double(crop.height) * scale)
        ZStack(alignment: .topLeading) {
            if let image = rotatedImage {
                Image(decorative: image, scale: 1).resizable()
            } else {
                Theme.mantle
                ProgressView().controlSize(.small).frame(width: shown.width, height: shown.height)
            }
            Path { path in
                path.addRect(CGRect(origin: .zero, size: shown))
                path.addRect(cropRect)
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            Rectangle()
                .stroke(Theme.success, lineWidth: 2)
                .frame(width: cropRect.width, height: cropRect.height)
                .offset(x: cropRect.minX, y: cropRect.minY)
        }
        .frame(width: shown.width, height: shown.height)
        .accessibilityLabel("Preview of the rotated frame with the crop")
    }

    /// The transformed frame at the aspect ratio, as thumbs show it.
    private var resultPreview: some View {
        let ratio = transform.displayAspectRatioInv(width: file.width, height: file.height)
        let width = min(220, 160 / ratio)
        return Group {
            if let image = preview.flatMap({ transform.apply(to: $0, width: file.width, height: file.height) }) {
                Image(decorative: image, scale: 1).resizable()
            } else {
                Theme.mantle
            }
        }
        .frame(width: width, height: width * ratio)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSm))
        .accessibilityLabel("Preview of the result")
    }

    private var rotatedImage: CGImage? {
        guard let preview else { return nil }
        var turn = MovieTransform()
        turn.rotation = transform.rotation
        return turn.apply(to: preview, width: file.width, height: file.height)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: Theme.space3) {
            VStack(alignment: .leading, spacing: 2) {
                Text("All thumbs of this movie will be updated.")
                if changesImage, model.transformClearsScans(file.id) {
                    Text("Its stored shot and face scans will be cleared; scan again to use the new frames.")
                        .foregroundStyle(Theme.warning)
                }
            }
            .font(Theme.panelCaption)
            .foregroundStyle(Theme.textMuted)
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .help("Close without changing the movie")
            Button("Update Transform") {
                model.setTransform(transform, of: file.id)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .help("Apply the rotation, crop and aspect ratio to this movie (undoable)")
        }
    }

    private var changesImage: Bool {
        transform.rotation != file.transform.rotation || transform.cropTop != file.transform.cropTop
            || transform.cropBottom != file.transform.cropBottom || transform.cropLeft != file.transform.cropLeft
            || transform.cropRight != file.transform.cropRight
    }

    // MARK: - State

    private func load() {
        guard !loaded else { return }
        loaded = true
        transform = file.transform
        guard let ratio = file.transform.aspectRatioInv, ratio > 0 else { aspectChoice = Self.ownRatio; return }
        if let preset = TransformOptions.aspectRatios.first(where: { abs($0.ratioInv - ratio) < 0.0005 }) {
            aspectChoice = preset.label
        } else {
            aspectChoice = Self.customRatio
            customWidth = (1 / ratio * 1000).rounded() / 1000
            customHeight = 1
        }
    }

    private var rotationBinding: Binding<Int> {
        Binding(
            get: { transform.rotation },
            set: { degrees in
                // The crop edges are in the rotated frame: they are kept as
                // numbers and clamped to the new size (MoviePrint keeps them).
                var t = transform
                t.rotation = degrees
                transform = t.clamped(width: file.width, height: file.height)
            })
    }

    private func cropBinding(_ edge: WritableKeyPath<MovieTransform, Int>) -> Binding<Int> {
        Binding(
            get: { transform[keyPath: edge] },
            set: { value in
                var t = transform
                t[keyPath: edge] = max(0, value)
                transform = t.clamped(width: file.width, height: file.height)
            })
    }

    private var aspectBinding: Binding<String> {
        Binding(
            get: { aspectChoice },
            set: { choice in
                aspectChoice = choice
                switch choice {
                case Self.ownRatio: transform.aspectRatioInv = nil
                case Self.customRatio: applyCustomRatio()
                default: transform.aspectRatioInv = TransformOptions.aspectRatios.first { $0.label == choice }?.ratioInv
                }
            })
    }

    private func applyCustomRatio() {
        guard customWidth > 0, customHeight > 0 else { return }
        transform.aspectRatioInv = customHeight / customWidth
    }
}
