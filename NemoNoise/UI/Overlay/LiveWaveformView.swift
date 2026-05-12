import SwiftUI

struct LiveWaveformView: View {
    let micLevel: Float
    let isRecording: Bool
    
    private let barCount = 16
    private let barSpacing: CGFloat = 3
    
    var body: some View {
        HStack(alignment: .center, spacing: barSpacing) {
            ForEach(0..<barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(barGradient(index: index))
                    .frame(width: 3, height: barHeight(index: index))
            }
        }
        .frame(height: 24)
    }
    
    private func barHeight(index: Int) -> CGFloat {
        if !isRecording { return 3 }
        
        // Use a simple sine wave overlay on top of mic level for a "live" feel
        let time = Date().timeIntervalSince1970 * 5
        let sine = sin(time + Double(index) * 0.5) * 0.2
        let level = CGFloat(micLevel) + CGFloat(sine)
        
        // Randomize slightly per bar for more organic look
        let randomFactor = 0.8 + 0.4 * sin(Double(index) * 1.5)
        let height = max(3, 24 * level * randomFactor)
        return min(24, height)
    }
    
    private func barGradient(index: Int) -> LinearGradient {
        let colors: [Color]
        if isRecording {
            colors = [.green, .cyan]
        } else {
            colors = [.secondary.opacity(0.3), .secondary.opacity(0.5)]
        }
        
        return LinearGradient(
            colors: colors,
            startPoint: .bottom,
            endPoint: .top
        )
    }
}
