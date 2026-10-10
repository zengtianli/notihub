
import SwiftUI

#if os(macOS)
import AppKit
import AVFoundation

public enum UIKeyboardType { case `default`, decimalPad, numberPad, numbersAndPunctuation, emailAddress, URL, phonePad, asciiCapable, webSearch }

public enum NavigationBarItem { public enum TitleDisplayMode { case automatic, inline, large } }

public struct TextInputAutocapitalization {
    public static let never = TextInputAutocapitalization()
    public static let words = TextInputAutocapitalization()
    public static let sentences = TextInputAutocapitalization()
    public static let characters = TextInputAutocapitalization()
}

public extension View {
    func keyboardType(_ t: UIKeyboardType) -> Self { self }
    func navigationBarTitleDisplayMode(_ m: NavigationBarItem.TitleDisplayMode) -> Self { self }
    func textInputAutocapitalization(_ t: TextInputAutocapitalization?) -> Self { self }
    func fullScreenCover<Content: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil,
                                        @ViewBuilder content: @escaping () -> Content) -> some View {
        sheet(isPresented: isPresented, onDismiss: onDismiss, content: content)
    }
    func fullScreenCover<Item: Identifiable, Content: View>(item: Binding<Item?>, onDismiss: (() -> Void)? = nil,
                                                            @ViewBuilder content: @escaping (Item) -> Content) -> some View {
        sheet(item: item, onDismiss: onDismiss, content: content)
    }
}

public extension ToolbarItemPlacement {
    static var topBarLeading: ToolbarItemPlacement { .navigation }
    static var topBarTrailing: ToolbarItemPlacement { .primaryAction }
}
public extension PickerStyle where Self == MenuPickerStyle {
    static var navigationLink: MenuPickerStyle { MenuPickerStyle() }
}
public extension ToolbarPlacement {
    static var navigationBar: ToolbarPlacement { .automatic }
    static var tabBar: ToolbarPlacement { .automatic }
}

public typealias UIImage = NSImage
public typealias UIColor = NSColor

public extension NSImage {
    var cgImage: CGImage? { cgImage(forProposedRect: nil, context: nil, hints: nil) }
    func jpegData(compressionQuality q: CGFloat) -> Data? {
        guard let cg = cgImage else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: q])
    }
    func pngData() -> Data? {
        guard let cg = cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }
}

public extension Image {
    init(uiImage: NSImage) { self.init(nsImage: uiImage) }
}

public extension NSColor {
    static var systemBackground: NSColor { .windowBackgroundColor }
    static var secondarySystemBackground: NSColor { .controlBackgroundColor }
    static var tertiarySystemBackground: NSColor { .underPageBackgroundColor }
    static var systemGroupedBackground: NSColor { .windowBackgroundColor }
    static var secondarySystemGroupedBackground: NSColor { .controlBackgroundColor }
    static var tertiarySystemGroupedBackground: NSColor { .underPageBackgroundColor }
    static var label: NSColor { .labelColor }
    static var secondaryLabel: NSColor { .secondaryLabelColor }
    static var tertiaryLabel: NSColor { .tertiaryLabelColor }
    static var quaternaryLabel: NSColor { .quaternaryLabelColor }
    static var separator: NSColor { .separatorColor }
    static var placeholderText: NSColor { .placeholderTextColor }
    static var systemGray2: NSColor { .systemGray.withAlphaComponent(0.85) }
    static var systemGray3: NSColor { .systemGray.withAlphaComponent(0.65) }
    static var systemGray4: NSColor { .systemGray.withAlphaComponent(0.45) }
    static var systemGray5: NSColor { .systemGray.withAlphaComponent(0.30) }
    static var systemGray6: NSColor { .systemGray.withAlphaComponent(0.18) }
}

public extension Color {
    init(uiColor: NSColor) { self.init(nsColor: uiColor) }
}

public final class UIGraphicsImageRendererFormat {
    public var scale: CGFloat = 1
    public var opaque = false
    public init() {}
    public static func `default`() -> UIGraphicsImageRendererFormat { UIGraphicsImageRendererFormat() }
}

public final class UIGraphicsImageRendererContext {
    public let cgContext: CGContext
    init(_ c: CGContext) { cgContext = c }
    public func fill(_ rect: CGRect) { cgContext.fill(rect) }
}

public final class UIGraphicsImageRenderer {
    let size: CGSize
    let format: UIGraphicsImageRendererFormat
    public init(size: CGSize, format: UIGraphicsImageRendererFormat = .init()) { self.size = size; self.format = format }
    public func image(actions: (UIGraphicsImageRendererContext) -> Void) -> NSImage {
        let scale = format.scale > 0 ? format.scale : 1
        let pw = max(1, Int(size.width * scale)), ph = max(1, Int(size.height * scale))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let bmp = NSGraphicsContext(bitmapImageRep: rep)
        else { return NSImage(size: size) }
        rep.size = size
        let cg = bmp.cgContext
        cg.translateBy(x: 0, y: CGFloat(ph)); cg.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        actions(UIGraphicsImageRendererContext(cg))
        NSGraphicsContext.restoreGraphicsState()
        let img = NSImage(size: size)
        img.addRepresentation(rep)
        return img
    }
}

public protocol UIViewRepresentable: NSViewRepresentable where NSViewType == UIViewType {
    associatedtype UIViewType: NSView
    func makeUIView(context: Context) -> UIViewType
    func updateUIView(_ uiView: UIViewType, context: Context)
}
public extension UIViewRepresentable {
    func makeNSView(context: Context) -> UIViewType { makeUIView(context: context) }
    func updateNSView(_ nsView: UIViewType, context: Context) { updateUIView(nsView, context: context) }
}

public protocol UIViewControllerRepresentable: NSViewControllerRepresentable where NSViewControllerType == UIViewControllerType {
    associatedtype UIViewControllerType: NSViewController
    func makeUIViewController(context: Context) -> UIViewControllerType
    func updateUIViewController(_ vc: UIViewControllerType, context: Context)
}
public extension UIViewControllerRepresentable {
    func makeNSViewController(context: Context) -> UIViewControllerType { makeUIViewController(context: context) }
    func updateNSViewController(_ vc: UIViewControllerType, context: Context) { updateUIViewController(vc, context: context) }
}

public enum UIApplication {
    public static let willResignActiveNotification = NSApplication.willResignActiveNotification
    public static let didBecomeActiveNotification = NSApplication.didBecomeActiveNotification
    public static let didEnterBackgroundNotification = NSApplication.didHideNotification
    public static let willEnterForegroundNotification = NSApplication.willUnhideNotification
}

public final class UIPasteboard {
    public static let general = UIPasteboard()
    public var string: String? {
        get { NSPasteboard.general.string(forType: .string) }
        set {
            NSPasteboard.general.clearContents()
            if let s = newValue { NSPasteboard.general.setString(s, forType: .string) }
        }
    }
}

public final class UINotificationFeedbackGenerator {
    public enum FeedbackType { case success, warning, error }
    public init() {}
    public func notificationOccurred(_ t: FeedbackType) {}
    public func prepare() {}
}
public final class UIImpactFeedbackGenerator {
    public enum FeedbackStyle { case light, medium, heavy, soft, rigid }
    public init(style: FeedbackStyle = .medium) {}
    public func impactOccurred() {}
    public func impactOccurred(intensity: CGFloat) {}
    public func prepare() {}
}

public final class AVAudioSession {
    public struct Category { public static let playback = Category(); public static let record = Category(); public static let playAndRecord = Category(); public static let ambient = Category() }
    public struct Mode { public static let `default` = Mode(); public static let spokenAudio = Mode(); public static let measurement = Mode() }
    public struct CategoryOptions: OptionSet {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let duckOthers = CategoryOptions(rawValue: 1)
        public static let mixWithOthers = CategoryOptions(rawValue: 2)
        public static let defaultToSpeaker = CategoryOptions(rawValue: 4)
    }
    public struct SetActiveOptions: OptionSet {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let notifyOthersOnDeactivation = SetActiveOptions(rawValue: 1)
    }
    private static let shared = AVAudioSession()
    public static func sharedInstance() -> AVAudioSession { shared }
    public func setCategory(_ c: Category, mode: Mode = .default, options: CategoryOptions = []) throws {}
    public func setActive(_ on: Bool, options: SetActiveOptions = []) throws {}
}

#endif

#if os(visionOS)
public final class UINotificationFeedbackGenerator {
    public enum FeedbackType { case success, warning, error }
    public init() {}
    public func notificationOccurred(_ t: FeedbackType) {}
    public func prepare() {}
}
public final class UIImpactFeedbackGenerator {
    public enum FeedbackStyle { case light, medium, heavy, soft, rigid }
    public init(style: FeedbackStyle = .medium) {}
    public func impactOccurred() {}
    public func impactOccurred(intensity: CGFloat) {}
    public func prepare() {}
}
#endif

#if os(watchOS)
import WatchKit
public enum UIKeyboardType { case `default`, decimalPad, numberPad, numbersAndPunctuation, emailAddress, URL, phonePad, asciiCapable, webSearch }
public extension View {
    func keyboardType(_ t: UIKeyboardType) -> Self { self }
}
public final class UINotificationFeedbackGenerator {
    public enum FeedbackType { case success, warning, error }
    public init() {}
    public func notificationOccurred(_ t: FeedbackType) {
        let kind: WKHapticType
        switch t {
        case .success: kind = .success
        case .warning: kind = .retry
        case .error: kind = .failure
        }
        WKInterfaceDevice.current().play(kind)
    }
    public func prepare() {}
}
public final class UIImpactFeedbackGenerator {
    public enum FeedbackStyle { case light, medium, heavy, soft, rigid }
    public init(style: FeedbackStyle = .medium) {}
    public func impactOccurred() { WKInterfaceDevice.current().play(.click) }
    public func impactOccurred(intensity: CGFloat) { WKInterfaceDevice.current().play(.click) }
    public func prepare() {}
}
#endif
