import SwiftUI
import AppKit

// MARK: - Custom Tab Button Component

struct TabButton: View {
    let iconName: String
    let isSelected: Bool
    let helpText: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: iconName)
                .font(.system(size: 22, weight: .regular)) // Adjusted to 22pt
                .foregroundColor(isSelected ? .accentColor : .secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(isSelected ? Color(NSColor.selectedContentBackgroundColor).opacity(0.25) : Color.clear)
                .cornerRadius(5)
        }
        .buttonStyle(.plain)
        .help(helpText)
    }
}
