import SwiftUI

extension Binding {
    /// Native controls can retain a binding after SwiftUI removes or reorders its row.
    /// Resolve by identity on every access; a removed row must never edit its successor.
    func element<Element: Identifiable>(_ snapshot: Element) -> Binding<Element> where Value == [Element] {
        Binding<Element>(
            get: { wrappedValue.first { $0.id == snapshot.id } ?? snapshot },
            set: { updated in
                guard let index = wrappedValue.firstIndex(where: { $0.id == snapshot.id }) else { return }
                wrappedValue[index] = updated
            }
        )
    }
}
