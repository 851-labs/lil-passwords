import AppKit

/// The final step of the import sheet: how many items were imported, plus a reminder that the CSV
/// file the user just imported from is a plaintext copy of every password in it — and a one-click
/// way to get rid of it (`FileManager.trashItem`, so it's recoverable from the Trash rather than
/// gone forever, matching how deleting it in Finder would behave).
@MainActor
final class ImportCompletionViewController: NSViewController {
  private let importedCount: Int
  private let csvURL: URL?
  private let trashButton = NSButton()
  private let trashStatusField = NSTextField(labelWithString: "")

  var onDone: (() -> Void)?

  init(importedCount: Int, csvURL: URL?) {
    self.importedCount = importedCount
    self.csvURL = csvURL
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override func loadView() {
    view = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 260))
    configureSubviews()
  }

  private func configureSubviews() {
    let emptyState = EmptyStateView()
    emptyState.translatesAutoresizingMaskIntoConstraints = false
    let itemWord = importedCount == 1 ? "Password" : "Passwords"
    emptyState.configure(
      symbolName: "checkmark.circle",
      title: "Imported \(importedCount) \(itemWord)",
      message:
        "The file you imported from contains your passwords in plain text. "
        + "For your security, delete it once you've confirmed the import."
    )

    trashButton.translatesAutoresizingMaskIntoConstraints = false
    trashButton.title = "Move CSV to Trash"
    trashButton.bezelStyle = .rounded
    trashButton.target = self
    trashButton.action = #selector(trashTapped)
    trashButton.isHidden = csvURL == nil

    trashStatusField.translatesAutoresizingMaskIntoConstraints = false
    trashStatusField.font = .systemFont(ofSize: 11)
    trashStatusField.textColor = .secondaryLabelColor
    trashStatusField.isHidden = true

    let doneButton = NSButton(title: "Done", target: self, action: #selector(doneTapped))
    doneButton.translatesAutoresizingMaskIntoConstraints = false
    doneButton.bezelStyle = .rounded
    doneButton.keyEquivalent = "\r"

    let buttonRow = NSStackView(views: [trashButton, NSView(), doneButton])
    buttonRow.translatesAutoresizingMaskIntoConstraints = false
    buttonRow.orientation = .horizontal
    buttonRow.distribution = .fill

    view.addSubview(emptyState)
    view.addSubview(trashStatusField)
    view.addSubview(buttonRow)

    NSLayoutConstraint.activate([
      emptyState.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
      emptyState.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      emptyState.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      emptyState.bottomAnchor.constraint(equalTo: trashStatusField.topAnchor, constant: -8),

      trashStatusField.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      trashStatusField.bottomAnchor.constraint(equalTo: buttonRow.topAnchor, constant: -12),

      buttonRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
      buttonRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
      buttonRow.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
    ])
  }

  @objc private func trashTapped() {
    guard let csvURL else { return }
    do {
      try FileManager.default.trashItem(at: csvURL, resultingItemURL: nil)
      trashStatusField.stringValue = "Moved to Trash."
      trashStatusField.isHidden = false
      trashButton.isEnabled = false
    } catch {
      trashStatusField.stringValue = "Couldn't move the file to the Trash: \(error.localizedDescription)"
      trashStatusField.isHidden = false
    }
  }

  @objc private func doneTapped() {
    onDone?()
  }
}
