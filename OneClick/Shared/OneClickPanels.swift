import SwiftUI

struct OneClickPanel<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12)
        content()
            .background(.background, in: shape)
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(.secondary.opacity(0.18))
                    .allowsHitTesting(false)
            }
    }
}

struct OneClickHeaderIcon: View {
    let symbol: String
    let color: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 19, weight: .medium))
            .foregroundStyle(color)
            .frame(width: 42, height: 42)
            .background(color.opacity(0.13), in: RoundedRectangle(cornerRadius: 11))
            .accessibilityHidden(true)
    }
}
