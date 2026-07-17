import SwiftUI

struct ColorPresetSelector: View {
    let title: String
    @Binding var selectedColor: Color
    let presets: [Color]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
            HStack(spacing: 8) {
                ForEach(presets, id: \.self) { color in
                    Circle()
                        .fill(color)
                        .frame(width: 18, height: 18)
                        .overlay(
                            Circle()
                                .stroke(Color.accentColor, lineWidth: selectedColor == color ? 2 : 0)
                                .padding(-3)
                        )
                        .onTapGesture {
                            selectedColor = color
                        }
                }
            }
        }
    }
}
