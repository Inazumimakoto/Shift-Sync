import WidgetKit
import SwiftUI
import AppIntents

struct ShiftWidgetEntry: TimelineEntry {
    let date: Date
    let shifts: [Shift]
    let lastSyncDate: Date?
}

struct ShiftWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> ShiftWidgetEntry {
        ShiftWidgetEntry(
            date: Date(),
            shifts: sampleShifts(),
            lastSyncDate: Date()
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (ShiftWidgetEntry) -> Void) {
        completion(makeEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ShiftWidgetEntry>) -> Void) {
        let entry = makeEntry()
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
    }

    private func makeEntry() -> ShiftWidgetEntry {
        let allShifts = SharedStorage.loadShifts()
        let upcoming = allShifts
            .filter { $0.end > Date() }
            .sorted { $0.start < $1.start }
        return ShiftWidgetEntry(
            date: Date(),
            shifts: Array(upcoming.prefix(2)),
            lastSyncDate: SharedStorage.loadLastSyncDate()
        )
    }

    private func sampleShifts() -> [Shift] {
        let calendar = Calendar.current
        let now = Date()
        let firstStart = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: now) ?? now
        let firstEnd = calendar.date(byAdding: .hour, value: 5, to: firstStart) ?? firstStart.addingTimeInterval(5 * 3600)
        let secondStart = calendar.date(byAdding: .day, value: 1, to: firstStart) ?? firstStart.addingTimeInterval(24 * 3600)
        let secondEnd = calendar.date(byAdding: .hour, value: 4, to: secondStart) ?? secondStart.addingTimeInterval(4 * 3600)

        return [
            Shift(start: firstStart, end: firstEnd, location: "渋谷店"),
            Shift(start: secondStart, end: secondEnd, location: "新宿店")
        ]
    }
}

struct ShiftSyncSmallWidget: Widget {
    static let kindID = "ShiftSyncSmallWidget"
    let kind = Self.kindID

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ShiftWidgetProvider()) { entry in
            ShiftSyncSmallWidgetView(entry: entry)
        }
        .configurationDisplayName("シフト同期")
        .description("次のシフトと同期ボタンを表示します。")
        .supportedFamilies([.systemSmall])
        .contentMarginsDisabled()
    }
}

struct ShiftSyncSmallWidgetView: View {
    let entry: ShiftWidgetEntry

    var body: some View {
        VStack(spacing: 6) {
            if let lastSyncDate = entry.lastSyncDate {
                Text("最終同期 \(Self.syncTimeFormatter.string(from: lastSyncDate))")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            if entry.shifts.isEmpty {
                Text("次のシフトはありません")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                VStack(spacing: 6) {
                    ForEach(entry.shifts) { shift in
                        ShiftHomeStyleRow(shift: shift)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }

            Color.clear
                .frame(height: 3)

            Button(intent: WidgetSyncIntent()) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("同期")
                        .fontWeight(.semibold)
                }
                .font(.system(size: 14))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(Color.blue)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .containerBackground(.background, for: .widget)
    }

    private static let syncTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        formatter.locale = Locale(identifier: "ja_JP")
        return formatter
    }()
}

private struct ShiftHomeStyleRow: View {
    let shift: Shift

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .center, spacing: 0) {
                Text(shift.dateString)
                    .font(.system(size: 16, weight: .bold))
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(shift.dayOfWeek)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 42)

            VStack(alignment: .leading, spacing: 1) {
                Text(compactTimeRange)
                    .font(.system(size: 13, weight: .semibold))
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                HStack(spacing: 3) {
                    Image(systemName: "mappin.circle.fill")
                        .font(.system(size: 9, weight: .regular))
                        .foregroundStyle(.red)
                    Text(shift.location)
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                }
            }
            .frame(width: 92, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var compactTimeRange: String {
        "\(Self.timeFormatter.string(from: shift.start))-\(Self.timeFormatter.string(from: shift.end))"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.locale = Locale(identifier: "ja_JP")
        return formatter
    }()
}

#Preview(as: .systemSmall) {
    ShiftSyncSmallWidget()
} timeline: {
    ShiftWidgetEntry(date: Date(), shifts: [], lastSyncDate: nil)
    ShiftWidgetEntry(date: Date(), shifts: [
        Shift(start: Date(), end: Date().addingTimeInterval(4 * 3600), location: "池袋店"),
        Shift(start: Date().addingTimeInterval(24 * 3600), end: Date().addingTimeInterval(29 * 3600), location: "新宿店")
    ], lastSyncDate: Date())
}
