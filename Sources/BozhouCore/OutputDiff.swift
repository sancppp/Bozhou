import Foundation

public struct DiffLine: Equatable, Sendable {
    public enum Kind: Sendable { case equal, removed, added, gap }
    public var number: Int?
    public var text: String
    public var kind: Kind
}

public struct OutputDiff: Sendable {
    public var left: [DiffLine]
    public var right: [DiffLine]
    public var added: Int { right.filter { $0.kind == .added }.count }
    public var removed: Int { left.filter { $0.kind == .removed }.count }

    public init(_ before: String, _ after: String) {
        let old = before.components(separatedBy: "\n"), new = after.components(separatedBy: "\n")
        var deletions = Set<Int>(), insertions = Set<Int>()
        // Bound worst-case diff work. Large outputs still display every line with positional highlighting.
        if old.count + new.count <= 4000 {
            for change in new.difference(from: old) {
                switch change {
                case .remove(let offset, _, _): deletions.insert(offset)
                case .insert(let offset, _, _): insertions.insert(offset)
                }
            }
        } else {
            for i in 0..<max(old.count, new.count) where i >= old.count || i >= new.count || old[i] != new[i] {
                if i < old.count { deletions.insert(i) }
                if i < new.count { insertions.insert(i) }
            }
        }
        left = []; right = []
        let gap = DiffLine(number: nil, text: "", kind: .gap)
        var a = 0, b = 0
        while a < old.count || b < new.count {
            if deletions.contains(a) || insertions.contains(b) {
                if a < old.count, deletions.contains(a) {
                    left.append(DiffLine(number: a + 1, text: old[a], kind: .removed)); a += 1
                } else { left.append(gap) }
                if b < new.count, insertions.contains(b) {
                    right.append(DiffLine(number: b + 1, text: new[b], kind: .added)); b += 1
                } else { right.append(gap) }
            } else {
                if a < old.count { left.append(DiffLine(number: a + 1, text: old[a], kind: .equal)); a += 1 }
                else { left.append(gap) }
                if b < new.count { right.append(DiffLine(number: b + 1, text: new[b], kind: .equal)); b += 1 }
                else { right.append(gap) }
            }
        }
    }
}
