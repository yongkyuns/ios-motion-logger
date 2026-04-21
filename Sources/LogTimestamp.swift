import Foundation

func makeLogTimestamp(_ date: Date = Date()) -> String {
    ISO8601DateFormatter.string(
        from: date,
        timeZone: TimeZone(secondsFromGMT: 0)!,
        formatOptions: [.withInternetDateTime, .withFractionalSeconds]
    )
}
