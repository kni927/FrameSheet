import SwiftUI

// Classic transparency checkerboard, drawn behind the preview when the
// contact-sheet background has alpha < 1.
struct CheckerboardBackground: View {
    var squareSize: CGFloat = 8

    var body: some View {
        Canvas { context, size in
            let cols = Int(ceil(size.width / squareSize))
            let rows = Int(ceil(size.height / squareSize))
            for row in 0..<rows {
                for col in 0..<cols where (row + col) % 2 == 0 {
                    let rect = CGRect(x: CGFloat(col) * squareSize,
                                      y: CGFloat(row) * squareSize,
                                      width: squareSize, height: squareSize)
                    context.fill(Path(rect), with: .color(Color(white: 0.75)))
                }
            }
        }
        .background(Color(white: 0.55))
    }
}
