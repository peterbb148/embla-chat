# Chat presentation polish (#18)

## Rendering and Copy

Assistant messages use Foundation's native Markdown parser and presentation intents.
Paragraphs, headings, inline emphasis/code/links, ordered/unordered lists and quotes are
rendered with native selectable SwiftUI text. Fenced code has a separate monospaced,
horizontally scrolling card; its language is shown when supplied. The parser retains
indentation, blank lines and code content without interpreting it as prose Markdown.
This is basic Markdown support, without syntax highlighting or a dedicated table layout.
A parser error is displayed explicitly; it does not report successful formatting.

Copy message copies the complete original message text, including Markdown markup.
Copy code copies only that block's code, preserving whitespace and line breaks. Both
provide Copied feedback and accessible labels. User messages stay literal, selectable
text. No clipboard content is read to implement copying.

Completed message rows compare their message values before rendering again, so a new
token does not require re-parsing every unchanged row. The current streaming message
continues to update, including an incomplete fence parsed by the native Markdown grammar.

## Scrolling and keyboard

The transcript follows text/reasoning growth while the reader is near the bottom.
Only reader-initiated scrolling updates the follow preference; growing content no longer
looks like a request to stop following. Scrolling up exposes Jump to latest. Sending a
new user message, restoring another conversation or clearing a chat returns to the latest
turn. Code cards scroll horizontally within the vertical transcript.

The accepted single-card composer, Send/Stop and native keyboard hide control are retained.
Controls retain basic spoken labels and native text/control behavior. A dedicated
accessibility audit and large-text validation are outside the requested scope. Existing
UI tests cover keyboard-safe Send position, Settings access and retained drafts.

Existing production status transitions distinguish downloading/verifying, model loading,
thinking, answering, compacting and stopping. Settings displays local save status and
optional cloud sync/error state independently. Model download/local storage sizes use the
manifest and measured stored bytes. Delete model requires confirmation and remains
separate from New Chat; existing controller tests verify deletion leaves chat data intact.

## Validation

Focused native-parser tests cover structured blocks, inline attributes, code whitespace,
literal Markdown in code, ordered list numbering and unfinished streaming fences.
The complete local package suite passes 94 cases, including nested list/code/heading, continuation paragraph and scroll-intent regressions. The application always uses its real
runtime path; saved visual fixtures are not generated answers and do not prove inference.

Simulator UI and visual observations are recorded with the final implementation commit
in the issue/PR evidence. Existing physical inference/compaction/iCloud observations stay
in their commit-specific documents. Simulator rendering is not proof of real cloud
transfers, VoiceOver behavior on hardware, or arbitrary large-input memory stability.
The earlier unexplained exit during remotely injected large input has no diagnosed cause
or claimed fix in this presentation change; final device hardening remains #7.

Apple references: [Markdown presentation intents](https://developer.apple.com/documentation/foundation/presentationintent),
[scroll phases](https://developer.apple.com/documentation/swiftui/view/onscrollphasechange(_:)),
and [text selection](https://developer.apple.com/documentation/swiftui/view/textselection(_:)).
