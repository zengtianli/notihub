import SwiftUI

struct WideLayoutKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var wideLayout: Bool {
        get { self[WideLayoutKey.self] }
        set { self[WideLayoutKey.self] = newValue }
    }
}

extension View {
    func readableWidth(_ maxWidth: CGFloat) -> some View {
        modifier(ReadableWidth(maxWidth: maxWidth))
    }

    func boardCard() -> some View {
        #if os(visionOS)
        self.padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        #else
        self.padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        #endif
    }

    @ViewBuilder
    func boardBackground() -> some View {
        #if os(visionOS)
        self
        #else
        self.background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        #endif
    }
}

private struct ReadableWidth: ViewModifier {
    let maxWidth: CGFloat
    @State private var frame = Frame()

    struct Frame: Equatable {
        var width: CGFloat = 0
        var leading: CGFloat = 0
        var trailing: CGFloat = 0
    }

    private var margin: CGFloat { max(20, (frame.width - maxWidth) / 2) }

    func body(content: Content) -> some View {
        content
            .contentMargins(.leading, frame.leading + margin, for: .scrollContent)
            .contentMargins(.trailing, frame.trailing + margin, for: .scrollContent)
            .onGeometryChange(for: Frame.self) { proxy in
                Frame(width: proxy.size.width, leading: proxy.safeAreaInsets.leading,
                      trailing: proxy.safeAreaInsets.trailing)
            } action: { frame = $0 }
    }
}
