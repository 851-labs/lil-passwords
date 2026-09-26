import AppKit

/// The leading toolbar item over the detail column (851-2463): an "Edit" capsule button that
/// becomes Cancel/Done while editing. Moved here from `DetailIdentityView`'s own button cluster,
/// which used to live inline above the detail cards; `DetailViewController` wires the three
/// closures below the same way it used to wire `DetailIdentityView.onEditTapped`/etc.
@MainActor
final class DetailEditToolbarView: NSView {
  var onEditTapped: (() -> Void)?
  var onCancelTapped: (() -> Void)?
  var onDoneTapped: (() -> Void)?

  /// Disabled while nothing is selected (no item to edit) or multiple items are selected.
  var isEnabled: Bool = true {
    didSet { editButton.isEnabled = isEnabled }
  }

  private let editButton = NSButton(title: "Edit", target: nil, action: nil)
  private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
  private let doneButton = NSButton(title: "Done", target: nil, action: nil)

  init() {
    super.init(frame: .zero)
    configureSubviews()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  private func configureSubviews() {
    translatesAutoresizingMaskIntoConstraints = false

    editButton.bezelStyle = .rounded
    editButton.controlSize = .regular
    editButton.target = self
    editButton.action = #selector(editTapped)
    editButton.translatesAutoresizingMaskIntoConstraints = false

    cancelButton.bezelStyle = .rounded
    cancelButton.controlSize = .regular
    cancelButton.target = self
    cancelButton.action = #selector(cancelTapped)
    cancelButton.keyEquivalent = "\u{1b}"
    cancelButton.isHidden = true
    cancelButton.translatesAutoresizingMaskIntoConstraints = false

    doneButton.bezelStyle = .rounded
    doneButton.controlSize = .regular
    doneButton.keyEquivalent = "\r"
    doneButton.target = self
    doneButton.action = #selector(doneTapped)
    doneButton.isHidden = true
    doneButton.translatesAutoresizingMaskIntoConstraints = false

    let stack = NSStackView(views: [cancelButton, doneButton, editButton])
    stack.orientation = .horizontal
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = false

    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  /// Toggles between showing "Edit" and showing "Cancel"/"Done", called by `DetailViewController`
  /// on every edit-mode transition (entering, canceling, saving).
  func setEditing(_ editing: Bool) {
    editButton.isHidden = editing
    cancelButton.isHidden = !editing
    doneButton.isHidden = !editing
  }

  @objc
  private func editTapped() {
    onEditTapped?()
  }

  @objc
  private func cancelTapped() {
    onCancelTapped?()
  }

  @objc
  private func doneTapped() {
    onDoneTapped?()
  }
}
