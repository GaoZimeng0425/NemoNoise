import SwiftUI

struct SpectrumBarsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let spectrum: [Float]
    let isActive: Bool
    let barCount: Int
    var barColor: Color = .accentColor
    var barSpacing: CGFloat = 3
    var barWidth: CGFloat = 3
    var maxHeight: CGFloat = 24
    var minHeight: CGFloat = 3

    var body: some View {
        HStack(alignment: .center, spacing: barSpacing) {
            ForEach(0..<barCount, id: \.self) { i in
                Capsule()
                    .fill(isActive ? barColor : Color.secondary.opacity(0.3))
                    .frame(width: barWidth, height: barHeight(at: i))
            }
        }
        .frame(height: maxHeight)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: spectrum)
    }

    private func barHeight(at index: Int) -> CGFloat {
        guard isActive, !spectrum.isEmpty else { return minHeight }
        let sourceIdx = downsampleIndex(target: index)
        let v = CGFloat(spectrum[sourceIdx])
        return minHeight + v * (maxHeight - minHeight)
    }

    private func downsampleIndex(target: Int) -> Int {
        guard barCount > 0 else { return 0 }
        if spectrum.count == barCount { return target }
        let scaled = Int((Double(target) + 0.5) * Double(spectrum.count) / Double(barCount))
        return min(max(scaled, 0), spectrum.count - 1)
    }
}
