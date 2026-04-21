import Foundation

func makeLogTimestamp(_ date: Date = Date()) -> String {
    ISO8601DateFormatter.string(
        from: date,
        timeZone: TimeZone(secondsFromGMT: 0)!,
        formatOptions: [.withInternetDateTime, .withFractionalSeconds]
    )
}

func estimateWallClockDate(
    fromSystemUptime sensorTime: TimeInterval,
    now: Date = Date(),
    currentSystemUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
) -> Date {
    now.addingTimeInterval(sensorTime - currentSystemUptime)
}
