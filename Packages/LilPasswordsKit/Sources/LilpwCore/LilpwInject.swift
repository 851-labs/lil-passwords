import Foundation
import LilPasswordsKit

/// `lilpw inject -i template -o out`: replaces every `{{ lilpw://item/field }}` placeholder in a
/// template's text with its resolved secret value.
public enum LilpwInject {
  /// Matches `{{ lilpw://... }}`, capturing the reference (group 1) with its surrounding
  /// whitespace trimmed. `\S+?` (non-greedy) stops at the first `}}` rather than swallowing past a
  /// second placeholder on the same line.
  private static let referencePattern = try! NSRegularExpression(pattern: #"\{\{\s*(lilpw://\S+?)\s*\}\}"#)

  /// Replaces every placeholder in `template` and returns the substituted text.
  ///
  /// Resolves every placeholder before substituting any of them: if the *last* placeholder in a
  /// large template fails to resolve (locked, not found, ambiguous, malformed), nothing is
  /// substituted — a partially-filled-in template, with some secrets present and others still
  /// showing raw `{{ lilpw://... }}` text, is worse than no output at all. The CLI only writes
  /// `-o`'s file after this returns successfully.
  public static func inject(template: String, client: AgentClient) async throws -> String {
    let fullRange = NSRange(template.startIndex..<template.endIndex, in: template)
    let matches = referencePattern.matches(in: template, range: fullRange)

    var replacements: [(range: Range<String.Index>, value: String)] = []
    for match in matches {
      guard let matchRange = Range(match.range, in: template),
        let referenceRange = Range(match.range(at: 1), in: template)
      else { continue }

      let referenceString = String(template[referenceRange])
      guard let reference = SecretReference(string: referenceString) else {
        throw LilpwError(exitCode: .usage, message: "not a valid lilpw:// reference: \"\(referenceString)\"")
      }
      let item = try await LilpwCommands.resolveItem(reference.item, client: client)
      let value = try await SecretResolver.value(for: reference.field, in: item, client: client)
      replacements.append((matchRange, value))
    }

    var result = template
    for (range, value) in replacements.reversed() {
      result.replaceSubrange(range, with: value)
    }
    return result
  }
}
