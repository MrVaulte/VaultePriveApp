import Foundation

struct VerifiedOtpConsumedRange: Codable, Equatable, Sendable {
    var start: Int
    var endExclusive: Int

    var length: Int {
        max(0, endExclusive - start)
    }

    func intersects(start otherStart: Int, endExclusive otherEnd: Int) -> Bool {
        max(start, otherStart) < min(endExclusive, otherEnd)
    }
}

enum VerifiedOtpRangeTracker {
    static func decode(_ json: String) -> [VerifiedOtpConsumedRange] {
        guard let data = json.data(using: .utf8),
              let ranges = try? JSONDecoder().decode([VerifiedOtpConsumedRange].self, from: data)
        else { return [] }
        return normalize(ranges)
    }

    static func encode(_ ranges: [VerifiedOtpConsumedRange]) -> String {
        let normalized = normalize(ranges)
        guard let data = try? JSONEncoder().encode(normalized),
              let json = String(data: data, encoding: .utf8)
        else { return "[]" }
        return json
    }

    static func normalize(_ ranges: [VerifiedOtpConsumedRange]) -> [VerifiedOtpConsumedRange] {
        let sorted = ranges
            .filter { $0.endExclusive > $0.start }
            .sorted {
                if $0.start != $1.start { return $0.start < $1.start }
                return $0.endExclusive < $1.endExclusive
            }
        guard var current = sorted.first else { return [] }
        var result: [VerifiedOtpConsumedRange] = []
        for next in sorted.dropFirst() {
            if next.start <= current.endExclusive {
                current.endExclusive = max(current.endExclusive, next.endExclusive)
            } else {
                result.append(current)
                current = next
            }
        }
        result.append(current)
        return result
    }

    static func containsReplay(
        rangesJSON: String,
        start: Int,
        length: Int
    ) -> Bool {
        guard length > 0 else { return true }
        let endExclusive = start + length
        return decode(rangesJSON).contains { $0.intersects(start: start, endExclusive: endExclusive) }
    }

    static func appending(
        rangesJSON: String,
        start: Int,
        length: Int
    ) -> String {
        guard length > 0 else { return rangesJSON }
        var ranges = decode(rangesJSON)
        ranges.append(.init(start: start, endExclusive: start + length))
        return encode(ranges)
    }
}
