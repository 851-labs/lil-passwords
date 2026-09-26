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
      // 16pt/-16pt — see `DetailValueRowView`'s matching comment: lines this row's text up with
      // `CardView`'s divider inset and `KeyValueRow`'s own label inset.
      readLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      readLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
      readLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
      readLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

      // 12pt, not 16: `NSTextView` inside `editScrollView` has its own small internal padding
      // from `textContainerInset`, so a 16pt outer inset here would visually double up with it and
      // sit noticeably further in than `readLabel`'s text does at the same 16pt.
      editScrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      editScrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
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
