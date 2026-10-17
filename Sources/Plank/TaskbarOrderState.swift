import Foundation

/// WindowServer does not expose creation timestamps. Windows first seen in the
/// same snapshot share a rank; the caller breaks those ties by application name.
struct TaskbarOrderState {
    struct Window: Hashable {
        let id: UInt32
        let pid: Int32
    }

    private var ranks: [Window: UInt64] = [:]
    private var sequence: UInt64 = 0

    mutating func observe(_ windows: Set<Window>) {
        ranks = ranks.filter { windows.contains($0.key) }
        for window in windows where ranks[window] == nil { ranks[window] = sequence }
        sequence += 1
    }

    func rank(for pid: Int32) -> UInt64? {
        ranks.lazy.filter { $0.key.pid == pid }.map(\.value).min()
    }
}
