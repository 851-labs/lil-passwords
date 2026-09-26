import AppKit
import LilPasswordsKit
import PDFKit
import UniformTypeIdentifiers

/// Step one of `RecoveryKitSheetController`: shows the generated recovery kit PDF (key, QR code,
/// instructions) in a live preview and offers Save PDF…/Print…/Copy Key before the user moves on
/// to proving they saved it.
@MainActor
final class RecoveryKitRevealViewController: NSViewController {
  /// Called when the user taps "Continue" after saving/printing/copying the key.
  var onContinue: (() -> Void)?

  private let appName: String
  private let recoveryKey: VaultCrypto.RecoveryKey
  private let pdfData: Data

  init(appName: String, recoveryKey: VaultCrypto.RecoveryKey, pdfData: Data) {
    self.appName = appName
    self.recoveryKey = recoveryKey
    self.pdfData = pdfData
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override func loadView() {
    let titleField = NSTextField(labelWithString: String(localized: "Save Your Recovery Key"))
    titleField.font = .boldSystemFont(ofSize: 15)

    let subtitleField = NSTextField(
      wrappingLabelWithString: String(
        localized: """
          This key is the only way to restore your \(appName) vault on a new Mac, or if this Mac's \
          Keychain is ever lost. It's shown once, right now — save the PDF, print it, or copy the \
          key below before you continue.
          """
      )
    )
    subtitleField.font = .systemFont(ofSize: 12)
    subtitleField.textColor = .secondaryLabelColor

    let pdfView = PDFView()
    pdfView.document = PDFDocument(data: pdfData)
    pdfView.autoScales = true
    pdfView.displayMode = .singlePage
    pdfView.displaysPageBreaks = false
    pdfView.wantsLayer = true
    pdfView.layer?.borderColor = NSColor.separatorColor.cgColor
    pdfView.layer?.borderWidth = 1
    pdfView.layer?.cornerRadius = 6

    let saveButton = NSButton(title: String(localized: "Save PDF…"), target: self, action: #selector(savePDF))
    let printButton = NSButton(title: String(localized: "Print…"), target: self, action: #selector(printPDF))
    let copyButton = NSButton(title: String(localized: "Copy Key"), target: self, action: #selector(copyKey))
    let buttonRow = NSStackView(views: [saveButton, printButton, copyButton])
    buttonRow.orientation = .horizontal
    buttonRow.spacing = 8

    let continueButton = NSButton(
      title: String(localized: "Continue…"), target: self, action: #selector(continueTapped)
    )
    continueButton.keyEquivalent = "\r"
    continueButton.bezelStyle = .rounded
    // Same fix as `ImportPreviewViewController.importButton` (851-2426 tophat visual audit):
    // `keyEquivalent = "\r"` alone doesn't reliably paint this blue in a custom sheet.
    continueButton.bezelColor = .controlAccentColor

    let spacer = NSView()
    spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
    let footerRow = NSStackView(views: [buttonRow, spacer, continueButton])
    footerRow.orientation = .horizontal

    let stack = NSStackView(views: [titleField, subtitleField, pdfView, footerRow])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 14
    stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
    stack.translatesAutoresizingMaskIntoConstraints = false

    let container = NSView()
    container.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      stack.topAnchor.constraint(equalTo: container.topAnchor),
      stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      subtitleField.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
      footerRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
      pdfView.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
      pdfView.heightAnchor.constraint(equalToConstant: 380),
    ])

    view = container
    preferredContentSize = NSSize(width: 520, height: 580)
  }

  @objc
  private func savePDF() {
    guard let window = view.window else { return }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = String(localized: "\(appName) Recovery Kit.pdf")
    panel.allowedContentTypes = [.pdf]
    panel.beginSheetModal(for: window) { [pdfData] response in
      guard response == .OK, let url = panel.url else { return }
      try? pdfData.write(to: url)
    }
  }

  @objc
  private func printPDF() {
    guard let window = view.window, let document = PDFDocument(data: pdfData) else { return }

    let printInfo = NSPrintInfo.shared
    printInfo.horizontalPagination = .fit
    printInfo.verticalPagination = .fit

    guard
      let operation = document.printOperation(for: printInfo, scalingMode: .pageScaleDownToFit, autoRotate: true)
    else {
      return
    }
    operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
  }

  @objc
  private func copyKey() {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(recoveryKey.displayString, forType: .string)
  }

  @objc
  private func continueTapped() {
    onContinue?()
  }
}
