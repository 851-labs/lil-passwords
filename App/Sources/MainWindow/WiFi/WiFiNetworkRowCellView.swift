import AppKit
import LilPasswordsKit

/// One row in ``WiFiListViewController``'s table: the network name, its security type (when
/// known), and a "Current" badge for whichever network this Mac is presently associated with —
/// matching Apple Passwords' own Wi-Fi list. Same rounded-inset-selection/hairline-separator
/// metrics as ``ItemRowCellView`` (851-2444's rework to match 851-2463's Apple-parity chrome).
final class WiFiNetworkRowCellView: NSTableCellView {
  static let reuseIdentifier = NSUserInterfaceItemIdentifier("WiFiNetworkRow")

  private let iconView = NSImageView()
  private let ssidField = NSTextField(labelWithString: "")
  private let securityField = NSTextField(labelWithString: "")
  private let currentBadge = NSTextField(labelWithString: String(localized: "Current"))
  private let separator = NSBox()

  static func dequeue(from tableView: NSTableView, owner: Any?) -> WiFiNetworkRowCellView {
    if let existing = tableView.makeView(withIdentifier: reuseIdentifier, owner: owner) as? WiFiNetworkRowCellView {
      return existing
    }
    return WiFiNetworkRowCellView()
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    identifier = Self.reuseIdentifier
    configureSubviews()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  private func configureSubviews() {
    iconView.translatesAutoresizingMaskIntoConstraints = false
    iconView.image = NSImage(systemSymbolName: "wifi", accessibilityDescription: nil)
    iconView.contentTintColor = .secondaryLabelColor
    iconView.setAccessibilityElement(false)

    ssidField.translatesAutoresizingMaskIntoConstraints = false
    ssidField.font = .systemFont(ofSize: 13)
    ssidField.lineBreakMode = .byTruncatingTail

    securityField.translatesAutoresizingMaskIntoConstraints = false
    securityField.font = .systemFont(ofSize: 11)
    securityField.textColor = .secondaryLabelColor

    currentBadge.translatesAutoresizingMaskIntoConstraints = false
    currentBadge.font = .systemFont(ofSize: 10, weight: .semibold)
    currentBadge.textColor = .white
    currentBadge.backgroundColor = .controlAccentColor
    currentBadge.drawsBackground = true
    currentBadge.wantsLayer = true
    currentBadge.layer?.cornerRadius = 6
    currentBadge.layer?.masksToBounds = true
    currentBadge.alignment = .center

    let textStack = NSStackView(views: [ssidField, securityField])
    textStack.orientation = .vertical
    textStack.alignment = .leading
    textStack.spacing = 2
    textStack.translatesAutoresizingMaskIntoConstraints = false

    separator.boxType = .separator
    separator.translatesAutoresizingMaskIntoConstraints = false

    addSubview(iconView)
    addSubview(textStack)
    addSubview(currentBadge)
    addSubview(separator)

    NSLayoutConstraint.activate([
      iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
      iconView.widthAnchor.constraint(equalToConstant: 20),
      iconView.heightAnchor.constraint(equalToConstant: 20),

      textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
      textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
      textStack.trailingAnchor.constraint(lessThanOrEqualTo: currentBadge.leadingAnchor, constant: -8),

      currentBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
      currentBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
      currentBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 52),
      currentBadge.heightAnchor.constraint(equalToConstant: 16),

      // Inset to start at the text, not under the icon, matching `ItemRowCellView` (851-2463).
      separator.leadingAnchor.constraint(equalTo: textStack.leadingAnchor),
      separator.trailingAnchor.constraint(equalTo: trailingAnchor),
      separator.bottomAnchor.constraint(equalTo: bottomAnchor),
      separator.heightAnchor.constraint(equalToConstant: 1),
    ])
  }

  /// - Parameter hidesSeparator: Whether this row's bottom hairline should be hidden — true when
  ///   this row, or the row immediately below it, is selected, so no hairline ever cuts through a
  ///   rounded selection highlight (851-2463, mirroring `ItemRowCellView`). Kept in sync after the
  ///   initial `configure` call by `setSeparatorHidden(_:)`, since selection changes don't
  ///   re-invoke `configure`.
  func configure(with network: WiFiNetwork, hidesSeparator: Bool) {
    ssidField.stringValue = network.ssid
    securityField.stringValue = network.security?.displayName ?? String(localized: "Unknown Security")
    currentBadge.isHidden = !network.isCurrentNetwork
    separator.isHidden = hidesSeparator

    setAccessibilityElement(true)
    setAccessibilityLabel(
      network.isCurrentNetwork
        ? String(localized: "\(network.ssid), \(securityField.stringValue), current network")
        : String(localized: "\(network.ssid), \(securityField.stringValue)")
    )
  }

  func setSeparatorHidden(_ hidden: Bool) {
    separator.isHidden = hidden
  }
}
