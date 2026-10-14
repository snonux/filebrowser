/// Naming of text shared from other apps, which is saved as a `.md` or `.txt`
/// file.
library;

// Markup that is rare in plain text: a heading, a fenced code block, a
// link, a table row, bold text or a task list item.
final _strong = <RegExp>[
  RegExp(r'^#{1,6}\s+\S', multiLine: true),
  RegExp(r'^\s*(```|~~~)', multiLine: true),
  RegExp(r'\[[^\]\n]+\]\([^)\s]+\)'),
  RegExp(r'^\s*\|.+\|\s*$', multiLine: true),
  RegExp(r'(\*\*|__)\S[^\n]*?\S\1'),
  RegExp(r'^\s*[-*+]\s+\[[ xX]\]\s', multiLine: true),
];

// Markup that plain notes use too: a bullet or numbered list, a quote, a
// rule, or inline code.
final _weak = <RegExp>[
  RegExp(r'^\s*[-*+]\s+\S', multiLine: true),
  RegExp(r'^\s*\d+[.)]\s+\S', multiLine: true),
  RegExp(r'^>\s?\S', multiLine: true),
  RegExp(r'^\s*([-*_])(\s*\1){2,}\s*$', multiLine: true),
  RegExp(r'`[^`\n]+`'),
];

/// Whether [text] reads as Markdown: one sign that plain text rarely has, or
/// two that notes share with Markdown.
bool looksLikeMarkdown(String text) {
  if (_strong.any((r) => r.hasMatch(text))) return true;
  return _weak.where((r) => r.hasMatch(text)).length >= 2;
}

/// File extension for shared [text]: `.md` or `.txt`.
String textExtension(String text) => looksLikeMarkdown(text) ? '.md' : '.txt';

/// A file name for shared [text] without its extension: the sender's
/// [subject], else the first line, else a timestamp.
String textBaseName(String text, {String? subject, DateTime? now}) {
  String clean(String s) {
    var name = s
        // A Markdown heading's marks and other markup are not part of a name.
        .replaceFirst(RegExp(r'^\s*#+\s*'), '')
        .replaceAll(RegExp(r'[\\/:*?"<>|`#\[\]\(\)]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (name.length > 60) {
      name = name.substring(0, 60);
      final space = name.lastIndexOf(' ');
      if (space > 20) name = name.substring(0, space);
    }
    // Leading dots would hide the file; trailing ones confuse extensions.
    return name.replaceAll(RegExp(r'^\.+|\.+$'), '').trim();
  }

  final fromSubject = clean(subject ?? '');
  if (fromSubject.isNotEmpty) return fromSubject;
  final firstLine = text
      .split('\n')
      .map((l) => l.trim())
      .firstWhere((l) => l.isNotEmpty, orElse: () => '');
  // A bare link makes a poor name.
  if (!RegExp(r'^\w+://\S+$').hasMatch(firstLine)) {
    final fromText = clean(firstLine);
    if (fromText.isNotEmpty) return fromText;
  }
  final t = (now ?? DateTime.now()).toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return 'Shared ${t.year}-${two(t.month)}-${two(t.day)} '
      '${two(t.hour)}${two(t.minute)}${two(t.second)}';
}
