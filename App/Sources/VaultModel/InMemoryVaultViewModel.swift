import Combine
import Foundation
import LilPasswordsKit

/// The `VaultViewModel` backing the UI until `VaultStore` (851-2404) and the XPC helper
/// (851-2427) land. Holds everything in memory — nothing here survives quitting the app — which
/// is fine for UI work that only needs a plausible, mutable list of items to build and test
/// against.
@MainActor
final class InMemoryVaultViewModel: VaultViewModel {
  private let subject: CurrentValueSubject<[PasswordItem], Never>

  var items: [PasswordItem] { subject.value }

  var itemsPublisher: AnyPublisher<[PasswordItem], Never> {
    subject.eraseToAnyPublisher()
  }

  init(items: [PasswordItem] = []) {
    subject = CurrentValueSubject(items)
  }

  func save(_ item: PasswordItem) {
    var item = item
    item.modifiedAt = Date()

    var current = subject.value
    if let index = current.firstIndex(where: { $0.id == item.id }) {
      current[index] = item
    } else {
      current.append(item)
    }
    subject.value = current
  }

  func delete(_ id: UUID) {
    subject.value.removeAll { $0.id == id }
  }
}
