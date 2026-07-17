import SwiftUI

struct DependencyRow: View {
    let title: String
    let path: String

    var body: some View {
        HStack {
            Text(title)
                .fontWeight(.bold)
            Spacer()
            Text(path)
                .foregroundColor(path == "Missing" || path.isEmpty ? .red : .gray)
        }
        .font(.system(size: 9, design: .monospaced))
        .padding(.vertical, 3)
    }
}
