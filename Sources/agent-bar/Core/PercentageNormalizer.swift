import Foundation

enum PercentageNormalizer {
    static func normalize(_ rawValue: Double?) -> Int {
        guard let rawValue, rawValue.isFinite else { return 0 }

        let scaledValue: Double
        // Claude can return either fractional utilization (0.27 => 27%)
        // or whole-number percentages encoded as doubles (1.0 => 1%).
        if rawValue >= 0, rawValue < 1 {
            scaledValue = rawValue * 100
        } else {
            scaledValue = rawValue
        }

        return Int(min(max(scaledValue, 0), 100).rounded())
    }
}
