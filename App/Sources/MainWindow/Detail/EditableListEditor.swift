import AppKit

/// Drives one `DetailSectionContainerView` showing an editable, reorderable list of strings —
/// used in edit mode for both usernames and websites, which need the same add/remove/reorder
/// behavior over different underlying fields.
@MainActor
final class EditableListEditor {
  private weak var section: DetailSectionContainerView?
  private var values: [String]
  private let placeholder: String
  private let addButtonTitle: String
  private let onChange: ([String]) -> Void

  init(
    section: DetailSectionContainerView,
    values: [String],
    placeholder: String,
    addButtonTitle: String,
    onChange: @escaping ([String]) -> Void
  ) {
    self.section = section
    self.values = values
    self.placeholder = placeholder
    self.addButtonTitle = addButtonTitle
    self.onChange = onChange
    refresh()
  }

  private func refresh() {
    var rows: [NSView] = values.indices.map { makeRow(at: $0) }
    rows.append(
      AddRowView(title: addButtonTitle) { [weak self] in
        guard let self else { return }
        values.append("")
        onChange(values)
        refresh()
      }
    )
    section?.setRows(rows)
  }

  private func makeRow(at index: Int) -> NSView {
    let row = EditableListRowView(
      value: values[index],
      placeholder: placeholder,
      canMoveUp: index > 0,
      canMoveDown: index < values.count - 1
    )
    row.onValueChange = { [weak self] newValue in
      guard let self, values.indices.contains(index) else { return }
      values[index] = newValue
      onChange(values)
    }
    row.onMoveUp = { [weak self] in self?.move(index, by: -1) }
    row.onMoveDown = { [weak self] in self?.move(index, by: 1) }
    row.onRemove = { [weak self] in self?.remove(index) }
    return row
  }

  private func move(_ index: Int, by offset: Int) {
    let newIndex = index + offset
    guard values.indices.contains(index), values.indices.contains(newIndex) else { return }
    values.swapAt(index, newIndex)
    onChange(values)
    refresh()
  }

  private func remove(_ index: Int) {
    guard values.indices.contains(index) else { return }
    values.remove(at: index)
    onChange(values)
    refresh()
  }
}
