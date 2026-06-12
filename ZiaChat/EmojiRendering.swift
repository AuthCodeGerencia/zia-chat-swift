import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

// MARK: - Twemoji (simulator fallback)

enum TwemojiLoader {
    private static let cache = NSCache<NSString, UIImage>()

    static func image(for emoji: String, pointSize: CGFloat) async -> UIImage? {
        let key = "\(emoji)|\(Int(pointSize))" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let url = twemojiURL(for: emoji) else { return nil }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let source = UIImage(data: data) else { return nil }
            let side = max(pointSize * 1.15, 14)
            let sized = source.resized(to: CGSize(width: side, height: side))
            cache.setObject(sized, forKey: key)
            return sized
        } catch {
            return nil
        }
    }

    private static func twemojiURL(for emoji: String) -> URL? {
        let codepoints = emoji.unicodeScalars
            .filter { $0.value != 0xFE0F }
            .map { String(format: "%x", $0.value) }
            .joined(separator: "-")
        guard !codepoints.isEmpty else { return nil }
        return URL(string: "https://cdn.jsdelivr.net/gh/twitter/twemoji@14.0.2/assets/72x72/\(codepoints).png")
    }
}

private struct TwemojiImage: View {
    let emoji: String
    let size: CGFloat

    @State private var image: UIImage?
    @State private var finishedLoading = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else if finishedLoading {
                Image(systemName: "face.smiling")
                    .font(.system(size: size * 0.8))
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .controlSize(.mini)
            }
        }
        .frame(width: size, height: size)
        .task(id: "\(emoji)-\(size)") {
            finishedLoading = false
            image = await TwemojiLoader.image(for: emoji, pointSize: size)
            finishedLoading = true
        }
    }
}

// MARK: - Shared views

struct EmojiGlyph: View {
    let value: String
    let size: CGFloat

    init(_ value: String, size: CGFloat) {
        self.value = value
        self.size = size
    }

    var body: some View {
        #if targetEnvironment(simulator)
        TwemojiImage(emoji: value, size: size)
        #else
        Text(verbatim: value)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .scaleEffect(size / 20)
            .frame(width: size, height: size)
        #endif
    }
}

struct EmojiAwareText: View {
    let value: String
    let font: Font
    let color: Color
    let mentionableUsers: [CoreUserLite]
    let currentUserName: String?
    let onMentionTap: ((CoreUserLite) -> Void)?

    init(
        _ value: String,
        font: Font,
        color: Color,
        mentionableUsers: [CoreUserLite] = [],
        currentUserName: String? = nil,
        onMentionTap: ((CoreUserLite) -> Void)? = nil
    ) {
        self.value = value
        self.font = font
        self.color = color
        self.mentionableUsers = mentionableUsers
        self.currentUserName = currentUserName
        self.onMentionTap = onMentionTap
    }

    var body: some View {
        #if targetEnvironment(simulator)
        if needsInteractiveRendering {
            Text(attributedValue)
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.openURL, mentionOpenURLAction)
        } else {
            SimulatorEmojiText(value: value, font: font, color: color)
        }
        #else
        Text(attributedValue)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.openURL, mentionOpenURLAction)
        #endif
    }

    private var mentionOpenURLAction: OpenURLAction {
        OpenURLAction { url in
            guard url.scheme == "zia-mention",
                  let userId = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?
                    .first(where: { $0.name == "user" })?
                    .value,
                  let user = mentionableUsers.first(where: { $0.id == userId }),
                  let onMentionTap else {
                return .systemAction
            }
            onMentionTap(user)
            return .handled
        }
    }

    private var needsInteractiveRendering: Bool {
        if value.range(of: #"(?i)(https?://|www\.)\S+"#, options: .regularExpression) != nil {
            return true
        }
        return mentionableUsers.contains {
            value.localizedCaseInsensitiveContains("@\($0.displayName)")
        }
    }

    private var attributedValue: AttributedString {
        #if canImport(UIKit)
        let baseColor = color == .white ? UIColor.white : UIColor.label
        let result = NSMutableAttributedString(
            string: value,
            attributes: [
                .font: UIFont.preferredFont(forTextStyle: .body),
                .foregroundColor: baseColor
            ]
        )
        let fullRange = NSRange(location: 0, length: result.length)

        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            detector.enumerateMatches(in: value, range: fullRange) { match, _, _ in
                guard let match, let rawURL = match.url else { return }
                let url: URL?
                if rawURL.scheme == nil, rawURL.absoluteString.hasPrefix("www.") {
                    url = URL(string: "https://\(rawURL.absoluteString)")
                } else {
                    url = rawURL
                }
                guard let url else { return }
                result.addAttributes(
                    [
                        .link: url,
                        .foregroundColor: UIColor.systemBlue,
                        .underlineStyle: NSUnderlineStyle.single.rawValue
                    ],
                    range: match.range
                )
            }
        }

        let names = Set(
            mentionableUsers
                .map(\.displayName)
                .filter { !$0.isEmpty }
        )
        .sorted { $0.count > $1.count }

        if !names.isEmpty {
            let pattern = "@(\(names.map(NSRegularExpression.escapedPattern).joined(separator: "|")))(?=$|[\\s.,!?;:)])"
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                regex.enumerateMatches(in: value, range: fullRange) { match, _, _ in
                    guard let match else { return }
                    let token = (value as NSString).substring(with: match.range)
                    let mentionedName = String(token.dropFirst())
                    let isCurrentUser = mentionedName.caseInsensitiveCompare(currentUserName ?? "") == .orderedSame
                    var attributes: [NSAttributedString.Key: Any] = [
                        .font: UIFont.preferredFont(forTextStyle: .headline),
                        .foregroundColor: isCurrentUser ? UIColor.white : UIColor.systemBlue,
                        .backgroundColor: isCurrentUser
                            ? UIColor.systemBlue
                            : UIColor.systemBlue.withAlphaComponent(0.12)
                    ]
                    if let user = mentionableUsers.first(where: {
                        $0.displayName.caseInsensitiveCompare(mentionedName) == .orderedSame
                    }) {
                        var components = URLComponents()
                        components.scheme = "zia-mention"
                        components.host = "user"
                        components.queryItems = [URLQueryItem(name: "user", value: user.id)]
                        if let url = components.url {
                            attributes[.link] = url
                        }
                    }
                    result.addAttributes(attributes, range: match.range)
                }
            }
        }

        return (try? AttributedString(result, including: \.uiKit)) ?? AttributedString(value)
        #else
        return AttributedString(value)
        #endif
    }
}

#if canImport(UIKit) && targetEnvironment(simulator)
private struct SimulatorEmojiText: UIViewRepresentable {
    let value: String
    let font: Font
    let color: Color

    func makeUIView(context: Context) -> TwemojiTextLabel {
        let label = TwemojiTextLabel()
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    func updateUIView(_ label: TwemojiTextLabel, context: Context) {
        let uiFont = UIFont.preferredFont(forTextStyle: .body)
        let uiColor = color == .white ? UIColor.white : UIColor.label
        label.apply(value: value, font: uiFont, color: uiColor)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: TwemojiTextLabel, context: Context) -> CGSize? {
        let width = proposal.width ?? UIScreen.main.bounds.width * 0.7
        return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    }
}

private final class TwemojiTextLabel: UILabel {
    private var renderToken = UUID()

    func apply(value: String, font: UIFont, color: UIColor) {
        let token = UUID()
        renderToken = token
        attributedText = Self.plainAttributedString(value, font: font, color: color)

        Task { @MainActor in
            let rendered = await Self.twemojiAttributedString(value, font: font, color: color)
            guard self.renderToken == token else { return }
            self.attributedText = rendered
            self.invalidateIntrinsicContentSize()
        }
    }

    private static func plainAttributedString(_ text: String, font: UIFont, color: UIColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
    }

    private static func twemojiAttributedString(_ text: String, font: UIFont, color: UIColor) async -> NSAttributedString {
        let result = NSMutableAttributedString()

        for character in text {
            let string = String(character)
            if character.isEmojiCharacter {
                if let image = await TwemojiLoader.image(for: string, pointSize: font.pointSize) {
                    let attachment = NSTextAttachment()
                    attachment.image = image
                    let side = max(font.pointSize * 1.15, 14)
                    attachment.bounds = CGRect(x: 0, y: font.descender, width: side, height: side)
                    result.append(NSAttributedString(attachment: attachment))
                    continue
                }
            }
            result.append(NSAttributedString(
                string: string,
                attributes: [.font: font, .foregroundColor: color]
            ))
        }

        return result
    }
}
#endif

private extension Character {
    var isEmojiCharacter: Bool {
        unicodeScalars.contains { scalar in
            scalar.properties.isEmojiPresentation || scalar.properties.isEmoji
        }
    }
}

#if canImport(UIKit)
private extension UIImage {
    func resized(to size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = UIScreen.main.scale
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
#endif
