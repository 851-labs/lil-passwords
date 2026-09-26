import AppKit
import LilPasswordsKit

/// A lightweight, non-editable rendering of a `PasswordItem`: title, first website, first
/// username, password (masked, with reveal/copy), and notes.
///
/// This is explicitly interim — the real detail view (view mode, edit mode, TOTP, multiple
/// usernames/websites, etc.) is 851-2415's job. This exists only so 851-2416's "select the new
/// item after saving" requirement has somewhere real to show it, without waiting on that other
/// ticket's PR to merge first.
@MainActor
final class ItemPreviewView: NSView {
  private let titleField = NSTextField(labelWithString: "")
  private let websiteField = NSTextField(labelWithString: "")
  private let usernameField = NSTextField(labelWithString: "")
  private let passwordField = NSTextField(labelWithString: "")
  private let notesField = NSTextField(wrappingLabelWithString: "")
  private let revealButton = NSButton(
    image: NSImage(systemSymbolName: "eye", accessibilityDescription: String(localized: "Reveal Password"))
      ?? NSImage(),
    target: nil,
    action: nil
  )
  private let copyButton = NSButton(
    image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: String(localized: "Copy Password"))
      ?? NSImage(),
    target: nil,
    action: nil
  )

  private var password = ""
  private var isRevealed = false

  init() {
    super.init(frame: .zero)
    configureSubviews()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  private func configureSubviews() {
    titleField.font = .boldSystemFont(ofSize: 18)
    websiteField.font = .systemFont(ofSize: 13)
    websiteField.textColor = .secondaryLabelColor
    usernameField.font = .systemFont(ofSize: 13)
    passwordField.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
    notesField.font = .systemFont(ofSize: 12)
    notesField.textColor = .secondaryLabelColor
    notesField.maximumNumberOfLines = 6

    revealButton.bezelStyle = .texturedRounded
    revealButton.isBordered = false
    revealButton.target = self
    revealButton.action = #selector(toggleRevealTapped)

    copyButton.bezelStyle = .texturedRounded
    copyButton.isBordered = false
    copyButton.target = self
    copyButton.action = #selector(copyPasswordTapped)

    let passwordRow = NSStackView(views: [passwordField, revealButton, copyButton])
    passwordRow.orientation = .horizontal
    passwordRow.spacing = 6

    let stack = NSStackView(views: [titleField, websiteField, usernameField, passwordRow, notesField])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 10
    stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
    stack.translatesAutoresizingMaskIntoConstraints = false

    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
      notesField.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
    ])
  }

  func configure(item: PasswordItem) {
    titleField.stringValue = item.title
    websiteField.stringValue = item.websites.first?.absoluteString ?? ""
    websiteField.isHidden = item.websites.isEmpty
    usernameField.stringValue = item.usernames.first ?? ""
    usernameField.isHidden = item.usernames.isEmpty
    password = item.password
    isRevealed = false
    updatePasswordDisplay()
    notesField.stringValue = item.notes
    notesField.isHidden = item.notes.isEmpty
  }

  @objc
  private func toggleRevealTapped() {
    isRevealed.toggle()
    updatePasswordDisplay()
  }

  @objc
  private func copyPasswordTapped() {
    Pasteboard.copySecret(password)
  }

  private func updatePasswordDisplay() {
    passwordField.stringValue = isRevealed ? password : String(repeating: "•", count: max(password.count, 8))
    revealButton.image = NSImage(
      systemSymbolName: isRevealed ? "eye.slash" : "eye",
      accessibilityDescription: isRevealed
        ? String(localized: "Hide Password") : String(localized: "Reveal Password")
    )
  }
}
