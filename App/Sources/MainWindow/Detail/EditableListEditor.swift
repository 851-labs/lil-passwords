import AppKit

/// Drives an editable, reorderable list of strings — used in edit mode for both usernames and
/// websites, which need the same add/remove/reorder behavior over different underlying fields.
///
/// Hands its rendered rows to `onRowsChange` rather than writing straight into a
/// `DetailSectionContainerView` itself (851-2463): the detail pane's primary card now combines
/// identity, username, password, verification, website, and "Created" rows into one shared card
/// (matching Apple Passwords), so `DetailViewController` owns the single `setRows` call that
/// assembles all of those together instead of each piece managing its own section.
@MainActor
final class EditableListEditor {
  private var values: [String]
  private let placeholder: String
  private let addButtonTitle: String
  private let onChange: ([String]) -> Void
  private let onRowsChange: ([NSView]) -> Void

  init(
    values: [String],
    placeholder: String,
    addButtonTitle: String,
    onChange: @escaping ([String]) -> Void,
    onRowsChange: @escaping ([NSView]) -> Void
  ) {
    self.values = values
    self.placeholder = placeholder
    self.addButtonTitle = addButtonTitle
    self.onChange = onChange
    self.onRowsChange = onRowsChange
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
    onRowsChange(rows)
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
