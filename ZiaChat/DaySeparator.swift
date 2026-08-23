import SwiftUI

/// Píldora "Hoy / Ayer / lunes / 12 de mayo" entre mensajes de días distintos.
struct DaySeparator: View {
    let date: Date

    var body: some View {
        Text(Self.title(for: date))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.9))
            .clipShape(Capsule())
            .overlay {
                Capsule().stroke(Color.black.opacity(0.06), lineWidth: 1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .accessibilityAddTraits(.isHeader)
    }

    static func title(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Hoy" }
        if calendar.isDateInYesterday(date) { return "Ayer" }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: Date())).day,
           days < 7 {
            return date.formatted(.dateTime.weekday(.wide)).capitalized
        }
        if calendar.isDate(date, equalTo: Date(), toGranularity: .year) {
            return date.formatted(.dateTime.day().month(.wide))
        }
        return date.formatted(date: .long, time: .omitted)
    }
}
