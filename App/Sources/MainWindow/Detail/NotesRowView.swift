import AppKit

/// The "Notes" row: a wrapping read-only label in read mode, or a small editable text view in
/// edit mode.
@MainActor
final class NotesRowView: NSView {
  var onValueChange: ((String) -> Void)?

  private let readLabel = NSTextField(wrappingLabelWithString: "")
  private let textView = NSTextView()
  private let editScrollView = NSScrollView()

  init(notes: String, isEditing: Bool) {
    super.init(frame: .zero)
    configureSubviews(notes: notes, isEditing: isEditing)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  private func configureSubviews(notes: String, isEditing: Bool) {
    translatesAutoresizingMaskIntoConstraints = false

    readLabel.font = .systemFont(ofSize: 13)
    readLabel.textColor = .secondaryLabelColor
    readLabel.stringValue = notes.isEmpty ? "No notes." : notes
    readLabel.translatesAutoresizingMaskIntoConstraints = false

    textView.string = notes
    textView.font = .systemFont(ofSize: 13)
    textView.isRichText = false
    textView.delegate = self
    textView.textContainerInset = NSSize(width: 0, height: 4)
    textView.drawsBackground = false

    editScrollView.documentView = textView
    editScrollView.hasVerticalScroller = true
    editScrollView.drawsBackground = false
    editScrollView.translatesAutoresizingMaskIntoConstraints = false

    addSubview(readLabel)
    addSubview(editScrollView)

    NSLayoutConstraint.activate([
      readLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      readLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
      readLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
      readLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

      editScrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      editScrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      editScrollView.topAnchor.constraint(equalTo: topAnchor, constant: 4),
      editScrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
      editScrollView.heightAnchor.constraint(equalToConstant: 80),
    ])

    readLabel.isHidden = isEditing
    editScrollView.isHidden = !isEditing
  }
}

extension NotesRowView: NSTextViewDelegate {
  func textDidChange(_ notification: Notification) {
    onValueChange?(textView.string)
  }
}
