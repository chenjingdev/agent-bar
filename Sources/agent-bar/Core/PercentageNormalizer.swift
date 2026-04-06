import Foundation

enum PercentageNormalizer {
    static func normalize(_ rawValue: Double?) -> Int {
        guard let rawValue, rawValue.isFinite else { return 0 }

        let scaledValue: Double
        if rawValue <= 1 {
            scaledValue = rawValue * 100
        } else {
            scaledValue = rawValue
        }

        return Int(min(max(scaledValue, 0), 100).rounded())
    }
}
