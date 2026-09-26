import AppKit

/// The read-mode "Password" row: masked dots by default, revealed while the mouse hovers the
/// row, and revealed (pinned, until clicked again) by clicking the masked value — plus a copy
/// button that always copies the real password regardless of whether it's currently shown.
@MainActor
final class PasswordRowView: NSView {
  var onCopy: (() -> Void)?

  private let row = DetailValueRowView()
  private var password = ""
  private var isPinnedRevealed = false
  private var isHovering = false

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    translatesAutoresizingMaskIntoConstraints = false

    row.translatesAutoresizingMaskIntoConstraints = false
    row.onCopy = { [weak self] in self?.onCopy?() }
    row.onHoverChange = { [weak self] hovering in
      self?.isHovering = hovering
      self?.updateDisplayedValue()
    }
    row.onClickValue = { [weak self] in
      guard let self else { return }
      isPinnedRevealed.toggle()
      updateDisplayedValue()
    }

    addSubview(row)
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: leadingAnchor),
      row.trailingAnchor.constraint(equalTo: trailingAnchor),
      row.topAnchor.constraint(equalTo: topAnchor),
      row.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  func configure(password: String) {
    self.password = password
    row.configure(label: "Password", value: "")
    updateDisplayedValue()
  }

  private func updateDisplayedValue() {
    let isRevealed = isHovering || isPinnedRevealed
    row.valueField.stringValue = isRevealed ? password : String(repeating: "•", count: max(password.count, 8))
  }
}
