import Foundation

enum ClockStyle: String, CaseIterable {
    case digital, analog, binary
    var title: String { rawValue.capitalized }
}

struct ClockTime {
    let hour: Int
    let minute: Int
    let second: Int

    func binaryDigits(use24HourTime: Bool, showSeconds: Bool) -> [Int] {
        let hour = use24HourTime ? hour : (hour % 12 == 0 ? 12 : hour % 12)
        var digits = [hour / 10, hour % 10, minute / 10, minute % 10]
        if showSeconds { digits += [second / 10, second % 10] }
        return digits
    }

    static func bitIsSet(_ digit: Int, row: Int) -> Bool { digit & (1 << (3 - row)) != 0 }
}
