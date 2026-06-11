import SwiftUI

struct WhatsAppEmojiPicker: View {
    let onSelect: (String) -> Void
    let onDelete: () -> Void

    @State private var selectedCategory = EmojiCatalog.categories[1].id
    @State private var searchText = ""
    @State private var recentEmojis = EmojiRecentsStore.load()

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 6),
        count: 8
    )

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search emojis", text: $searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(Color(.tertiarySystemFill))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            ScrollView {
                LazyVGrid(columns: columns, spacing: 9) {
                    ForEach(displayedEmojis, id: \.value) { item in
                        Button {
                            select(item.value)
                        } label: {
                            EmojiGlyph(item.value, size: 27)
                                .frame(maxWidth: .infinity)
                                .frame(height: 34)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(item.name)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .frame(height: 210)

            Divider()

            HStack(spacing: 0) {
                ForEach(EmojiCatalog.categories) { category in
                    Button {
                        selectedCategory = category.id
                        searchText = ""
                    } label: {
                        Image(systemName: category.symbol)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(selectedCategory == category.id ? Color.accentColor : .secondary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 42)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(category.name)
                }

                Button(action: onDelete) {
                    Image(systemName: "delete.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete")
            }
        }
        .background(.bar)
    }

    @MainActor
    private var displayedEmojis: [EmojiItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !query.isEmpty {
            return EmojiCatalog.all.filter {
                $0.name.localizedCaseInsensitiveContains(query) ||
                $0.keywords.contains { $0.localizedCaseInsensitiveContains(query) }
            }
        }

        if selectedCategory == EmojiCatalog.recentCategoryID {
            let items = recentEmojis.compactMap(EmojiCatalog.item(for:))
            return items.isEmpty ? EmojiCatalog.categories[1].items : items
        }

        return EmojiCatalog.categories.first { $0.id == selectedCategory }?.items ?? []
    }

    private func select(_ emoji: String) {
        onSelect(emoji)
        recentEmojis.removeAll { $0 == emoji }
        recentEmojis.insert(emoji, at: 0)
        recentEmojis = Array(recentEmojis.prefix(32))
        EmojiRecentsStore.save(recentEmojis)
    }
}

private struct EmojiCategory: Identifiable {
    let id: String
    let name: String
    let symbol: String
    let items: [EmojiItem]
}

private struct EmojiItem: Hashable {
    let value: String
    let name: String
    let keywords: [String]

    init(_ value: String, _ name: String, _ keywords: String = "") {
        self.value = value
        self.name = name
        self.keywords = keywords.split(separator: " ").map(String.init)
    }
}

private enum EmojiCatalog {
    static let recentCategoryID = "recent"

    static let categories: [EmojiCategory] = [
        EmojiCategory(id: recentCategoryID, name: "Recent", symbol: "clock", items: []),
        EmojiCategory(id: "smileys", name: "Smileys", symbol: "face.smiling", items: [
            .init("😀", "grinning face", "happy smile"),
            .init("😃", "smiling face", "happy"),
            .init("😄", "smiling eyes", "happy laugh"),
            .init("😁", "beaming face", "happy teeth"),
            .init("😆", "laughing face", "happy"),
            .init("😅", "sweat smile", "relief"),
            .init("😂", "tears of joy", "laugh funny"),
            .init("🤣", "rolling laughing", "funny"),
            .init("😊", "smiling face", "happy blush"),
            .init("😇", "angel face", "halo"),
            .init("🙂", "slightly smiling", "happy"),
            .init("🙃", "upside down face", "silly"),
            .init("😉", "winking face", "wink"),
            .init("😌", "relieved face", "calm"),
            .init("😍", "heart eyes", "love"),
            .init("🥰", "smiling hearts", "love"),
            .init("😘", "kiss face", "love"),
            .init("😋", "yummy face", "food"),
            .init("😜", "winking tongue", "silly"),
            .init("🤪", "zany face", "crazy"),
            .init("🤨", "raised eyebrow", "doubt"),
            .init("🧐", "monocle face", "thinking"),
            .init("🤓", "nerd face", "glasses"),
            .init("😎", "sunglasses face", "cool"),
            .init("🥳", "party face", "celebrate"),
            .init("😏", "smirking face", "smirk"),
            .init("😒", "unamused face", "annoyed"),
            .init("😔", "pensive face", "sad"),
            .init("😢", "crying face", "sad tear"),
            .init("😭", "loudly crying", "sad"),
            .init("😤", "steam face", "angry"),
            .init("😡", "angry face", "mad"),
            .init("🤯", "exploding head", "shocked"),
            .init("😱", "screaming face", "fear"),
            .init("🥶", "cold face", "freeze"),
            .init("🤢", "nauseated face", "sick"),
            .init("🤮", "vomiting face", "sick"),
            .init("🤔", "thinking face", "question"),
            .init("🤫", "shushing face", "quiet"),
            .init("🤭", "hand over mouth", "oops"),
            .init("🫠", "melting face", "hot"),
            .init("🫡", "saluting face", "respect"),
            .init("🫣", "peeking face", "look"),
            .init("🥱", "yawning face", "tired"),
            .init("😴", "sleeping face", "tired"),
            .init("🤡", "clown face", "funny"),
            .init("👻", "ghost", "halloween"),
            .init("💩", "poop", "funny")
        ]),
        EmojiCategory(id: "people", name: "People", symbol: "hand.raised", items: [
            .init("👋", "waving hand", "hello bye"),
            .init("🤚", "raised hand", "stop"),
            .init("🖐️", "hand fingers", "five"),
            .init("✋", "raised hand", "stop"),
            .init("👌", "OK hand", "good"),
            .init("🤌", "pinched fingers", "gesture"),
            .init("🤏", "pinching hand", "small"),
            .init("✌️", "victory hand", "peace"),
            .init("🤞", "crossed fingers", "luck"),
            .init("🫰", "finger heart", "love"),
            .init("🤟", "love you hand", "gesture"),
            .init("🤘", "horns hand", "rock"),
            .init("🤙", "call me hand", "phone"),
            .init("👈", "point left", "direction"),
            .init("👉", "point right", "direction"),
            .init("👆", "point up", "direction"),
            .init("👇", "point down", "direction"),
            .init("☝️", "index up", "one"),
            .init("🫵", "point at viewer", "you"),
            .init("👍", "thumbs up", "like yes"),
            .init("👎", "thumbs down", "dislike no"),
            .init("✊", "raised fist", "power"),
            .init("👊", "fist bump", "punch"),
            .init("👏", "clapping hands", "applause"),
            .init("🙌", "raising hands", "celebrate"),
            .init("🫶", "heart hands", "love"),
            .init("🤝", "handshake", "deal"),
            .init("🙏", "folded hands", "please thanks"),
            .init("💪", "flexed biceps", "strong"),
            .init("👀", "eyes", "look"),
            .init("🧠", "brain", "smart"),
            .init("🫂", "people hugging", "hug")
        ]),
        EmojiCategory(id: "animals", name: "Animals", symbol: "pawprint", items: [
            .init("🐶", "dog", "pet"),
            .init("🐱", "cat", "pet"),
            .init("🐭", "mouse"),
            .init("🐹", "hamster", "pet"),
            .init("🐰", "rabbit", "bunny"),
            .init("🦊", "fox"),
            .init("🐻", "bear"),
            .init("🐼", "panda"),
            .init("🐨", "koala"),
            .init("🐯", "tiger"),
            .init("🦁", "lion"),
            .init("🐮", "cow"),
            .init("🐷", "pig"),
            .init("🐸", "frog"),
            .init("🐵", "monkey"),
            .init("🐔", "chicken"),
            .init("🐧", "penguin"),
            .init("🐦", "bird"),
            .init("🦄", "unicorn"),
            .init("🐝", "bee"),
            .init("🦋", "butterfly"),
            .init("🐢", "turtle"),
            .init("🐍", "snake"),
            .init("🦖", "dinosaur"),
            .init("🐙", "octopus"),
            .init("🐬", "dolphin"),
            .init("🌸", "flower", "spring"),
            .init("🌻", "sunflower"),
            .init("🌵", "cactus"),
            .init("🌴", "palm tree"),
            .init("🔥", "fire", "hot"),
            .init("✨", "sparkles", "shine")
        ]),
        EmojiCategory(id: "food", name: "Food", symbol: "fork.knife", items: [
            .init("🍏", "green apple", "fruit"),
            .init("🍎", "red apple", "fruit"),
            .init("🍐", "pear", "fruit"),
            .init("🍊", "orange", "fruit"),
            .init("🍋", "lemon", "fruit"),
            .init("🍌", "banana", "fruit"),
            .init("🍉", "watermelon", "fruit"),
            .init("🍇", "grapes", "fruit"),
            .init("🍓", "strawberry", "fruit"),
            .init("🫐", "blueberries", "fruit"),
            .init("🍒", "cherries", "fruit"),
            .init("🍑", "peach", "fruit"),
            .init("🥭", "mango", "fruit"),
            .init("🍍", "pineapple", "fruit"),
            .init("🥑", "avocado", "food"),
            .init("🍕", "pizza", "food"),
            .init("🍔", "hamburger", "food"),
            .init("🍟", "fries", "food"),
            .init("🌮", "taco", "food"),
            .init("🍿", "popcorn", "movie"),
            .init("🍩", "doughnut", "sweet"),
            .init("🍪", "cookie", "sweet"),
            .init("🎂", "birthday cake", "party"),
            .init("🍫", "chocolate", "sweet"),
            .init("☕", "coffee", "drink"),
            .init("🍺", "beer", "drink"),
            .init("🍷", "wine", "drink"),
            .init("🥂", "cheers", "drink"),
            .init("🍾", "champagne", "celebrate"),
            .init("🧊", "ice", "cold"),
            .init("🍽️", "plate", "meal"),
            .init("🥤", "cup with straw", "drink")
        ]),
        EmojiCategory(id: "activity", name: "Activities", symbol: "soccerball", items: [
            .init("⚽", "soccer ball", "sport"),
            .init("🏀", "basketball", "sport"),
            .init("🏈", "football", "sport"),
            .init("⚾", "baseball", "sport"),
            .init("🎾", "tennis", "sport"),
            .init("🏐", "volleyball", "sport"),
            .init("🎱", "pool ball", "game"),
            .init("🏓", "table tennis", "sport"),
            .init("🥊", "boxing glove", "sport"),
            .init("🎮", "game controller", "gaming"),
            .init("🎲", "dice", "game"),
            .init("🧩", "puzzle", "game"),
            .init("🎯", "bullseye", "target"),
            .init("🎸", "guitar", "music"),
            .init("🎹", "piano", "music"),
            .init("🎤", "microphone", "music"),
            .init("🎧", "headphones", "music"),
            .init("🎬", "clapper board", "movie"),
            .init("🎨", "palette", "art"),
            .init("🏆", "trophy", "winner"),
            .init("🥇", "gold medal", "winner"),
            .init("🎉", "party popper", "celebrate"),
            .init("🎊", "confetti", "celebrate"),
            .init("🎁", "gift", "present")
        ]),
        EmojiCategory(id: "travel", name: "Travel", symbol: "car", items: [
            .init("🚗", "car", "vehicle"),
            .init("🚕", "taxi", "vehicle"),
            .init("🚌", "bus", "vehicle"),
            .init("🏎️", "racing car", "vehicle"),
            .init("🚓", "police car", "vehicle"),
            .init("🚑", "ambulance", "vehicle"),
            .init("🚒", "fire engine", "vehicle"),
            .init("🚲", "bicycle", "vehicle"),
            .init("✈️", "airplane", "travel"),
            .init("🚀", "rocket", "space"),
            .init("🛸", "flying saucer", "space"),
            .init("🚁", "helicopter", "vehicle"),
            .init("⛵", "sailboat", "travel"),
            .init("🏠", "house", "home"),
            .init("🏢", "office building", "work"),
            .init("🏥", "hospital"),
            .init("🏖️", "beach", "vacation"),
            .init("🏝️", "island", "vacation"),
            .init("🌋", "volcano"),
            .init("🌍", "globe", "world"),
            .init("🌙", "moon", "night"),
            .init("☀️", "sun", "weather"),
            .init("🌈", "rainbow", "weather"),
            .init("⚡", "lightning", "weather")
        ]),
        EmojiCategory(id: "objects", name: "Objects", symbol: "lightbulb", items: [
            .init("⌚", "watch", "time"),
            .init("📱", "phone", "mobile"),
            .init("💻", "laptop", "computer"),
            .init("⌨️", "keyboard", "computer"),
            .init("📷", "camera", "photo"),
            .init("💡", "light bulb", "idea"),
            .init("🔦", "flashlight"),
            .init("📚", "books", "study"),
            .init("✏️", "pencil", "write"),
            .init("📝", "memo", "write"),
            .init("📌", "pin"),
            .init("📎", "paperclip"),
            .init("🔒", "lock", "secure"),
            .init("🔑", "key"),
            .init("🔨", "hammer", "tool"),
            .init("🛠️", "tools"),
            .init("🧲", "magnet"),
            .init("💊", "pill", "medicine"),
            .init("💰", "money bag", "cash"),
            .init("💳", "credit card", "money"),
            .init("📦", "package", "box"),
            .init("🗑️", "trash", "delete"),
            .init("❤️", "red heart", "love"),
            .init("💔", "broken heart", "sad"),
            .init("💯", "hundred points", "perfect"),
            .init("✅", "check mark", "yes done"),
            .init("❌", "cross mark", "no"),
            .init("⚠️", "warning", "alert"),
            .init("❓", "question mark", "question"),
            .init("‼️", "double exclamation", "alert")
        ])
    ]

    static let all = categories.flatMap(\.items)

    static func item(for emoji: String) -> EmojiItem? {
        all.first { $0.value == emoji }
    }
}

private enum EmojiRecentsStore {
    private static let key = "zia-chat-recent-emojis"

    static func load() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func save(_ emojis: [String]) {
        UserDefaults.standard.set(emojis, forKey: key)
    }
}
