import AppKit
import LilPasswordsKit

/// Shown instead of the preview table when the chosen file isn't a CSV this app recognizes (an
/// unsupported format, or a parse failure) — and doubles as the "how do I even get a CSV" help
/// screen, since the most common reason someone lands here on a Mac is they haven't exported one
/// yet. Walks through exporting from Apple's own Passwords app, since that's the format
/// ``CSVExporter``/``CSVImporter`` round-trip natively.
@MainActor
final class ImportHelpViewController: NSViewController {
  private let message: String

  var onChooseDifferentFile: (() -> Void)?
  var onCancel: (() -> Void)?

  init(message: String) {
    self.message = message
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override func loadView() {
    view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 400))
    configureSubviews()
  }

  private func configureSubviews() {
    let emptyState = EmptyStateView()
    emptyState.translatesAutoresizingMaskIntoConstraints = false
    emptyState.configure(
      symbolName: "exclamationmark.triangle",
      title: String(localized: "Couldn't Read That File"),
      message: message
    )

    let stepsTitle = NSTextField(
      labelWithString: String(localized: "To export your passwords from Apple Passwords:")
    )
    stepsTitle.translatesAutoresizingMaskIntoConstraints = false
    stepsTitle.font = .systemFont(ofSize: 12, weight: .semibold)

    let steps = NSTextField(
      wrappingLabelWithString: String(
        localized: """
          1. Open the Passwords app.
          2. Choose File → Export All Passwords…
          3. Authenticate, then choose where to save the CSV file.
          4. Select that file here to import it.
          """
      )
    )
    steps.translatesAutoresizingMaskIntoConstraints = false
    steps.font = .systemFont(ofSize: 12)
    steps.textColor = .secondaryLabelColor

    let chooseButton = NSButton(
      title: String(localized: "Choose a Different File…"), target: self, action: #selector(chooseTapped)
    )
    chooseButton.translatesAutoresizingMaskIntoConstraints = false
    chooseButton.bezelStyle = .rounded
    chooseButton.keyEquivalent = "\r"
    // Same fix as `ImportPreviewViewController.importButton` (851-2426 tophat visual audit):
    // `keyEquivalent = "\r"` alone doesn't reliably paint this blue in a custom sheet.
    chooseButton.bezelColor = .controlAccentColor

    let cancelButton = NSButton(title: String(localized: "Cancel"), target: self, action: #selector(cancelTapped))
    cancelButton.translatesAutoresizingMaskIntoConstraints = false
    cancelButton.bezelStyle = .rounded
    cancelButton.keyEquivalent = "\u{1b}"

    let buttonRow = NSStackView(views: [cancelButton, NSView(), chooseButton])
    buttonRow.translatesAutoresizingMaskIntoConstraints = false
    buttonRow.orientation = .horizontal
    buttonRow.distribution = .fill

    view.addSubview(emptyState)
    view.addSubview(stepsTitle)
    view.addSubview(steps)
    view.addSubview(buttonRow)

    NSLayoutConstraint.activate([
      emptyState.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
      emptyState.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      emptyState.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      emptyState.heightAnchor.constraint(equalToConstant: 130),

      stepsTitle.topAnchor.constraint(equalTo: emptyState.bottomAnchor, constant: 8),
      stepsTitle.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
      stepsTitle.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

      steps.topAnchor.constraint(equalTo: stepsTitle.bottomAnchor, constant: 8),
      steps.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
      steps.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

      buttonRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
      buttonRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
      buttonRow.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
    ])
  }

  @objc private func chooseTapped() {
    onChooseDifferentFile?()
  }

  @objc private func cancelTapped() {
    onCancel?()
  }
}
