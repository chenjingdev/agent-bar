import Foundation

enum TokenFormatters {
    private static func makeRelativeFormatter() -> RelativeDateTimeFormatter {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }

    static func compactTokenString(_ value: Int) -> String {
        let absolute = Double(abs(value))
        let sign = value < 0 ? "-" : ""

        switch absolute {
        case 1_000_000_000...:
            return "\(sign)\(String(format: "%.1f", absolute / 1_000_000_000))B"
        case 1_000_000...:
            return "\(sign)\(String(format: "%.1f", absolute / 1_000_000))M"
        case 1_000...:
            return "\(sign)\(String(format: "%.1f", absolute / 1_000))k"
        default:
            return "\(value)"
        }
    }

    static func percentageString(for utilization: Double?) -> String {
        guard let utilization else { return "--" }
        return "\(Int((utilization * 100).rounded()))%"
    }

    static func resetString(from now: Date = .now, resetAt: Date?) -> String {
        guard let resetAt else { return "리셋 시간 없음" }
        if resetAt <= now {
            return "곧 리셋"
        }
        return makeRelativeFormatter().localizedString(for: resetAt, relativeTo: now)
    }

    static func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func dateTimeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func relativeUpdateString(from now: Date = .now, updatedAt: Date) -> String {
        let interval = abs(now.timeIntervalSince(updatedAt))
        if interval < 5 {
            return "방금 전"
        }
        return makeRelativeFormatter().localizedString(for: updatedAt, relativeTo: now)
    }
}
