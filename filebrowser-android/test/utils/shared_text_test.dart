import 'package:filebrowser_android/utils/shared_text.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('looksLikeMarkdown', () {
    for (final text in [
      '# Shopping\n\nmilk',
      'See [the docs](https://example.org) first.',
      'Run this:\n```\nls -l\n```',
      '| a | b |\n|---|---|\n| 1 | 2 |',
      'This is **important**.',
      '- [ ] call Bob\n- [x] buy milk',
      '- one\n- two\n\n> quoted',
    ]) {
      test('Markdown: ${text.split('\n').first}', () {
        expect(looksLikeMarkdown(text), isTrue);
        expect(textExtension(text), '.md');
      });
    }
    for (final text in [
      'Meet at 5pm, bring the keys.',
      'https://example.org/some/page',
      'Shopping:\n- milk\n- eggs',
      'Price is 5 * 3 = 15, and 2 * 2 = 4',
      '1. first thing to remember',
      '#hashtag and email me',
    ]) {
      test('plain: ${text.split('\n').first}', () {
        expect(looksLikeMarkdown(text), isFalse);
        expect(textExtension(text), '.txt');
      });
    }
  });

  group('textBaseName', () {
    final now = DateTime(2026, 10, 14, 9, 5, 7);
    test('prefers the subject', () {
      expect(textBaseName('body', subject: 'Trip: plan/notes', now: now),
          'Trip plan notes');
    });
    test('uses the first line without heading marks', () {
      expect(textBaseName('\n\n# My notes\nmore', now: now), 'My notes');
    });
    test('shortens long lines at a word', () {
      final name = textBaseName('word ' * 30, now: now);
      expect(name.length, lessThanOrEqualTo(60));
      expect(name.endsWith('word'), isTrue);
    });
    test('does not start with a dot', () {
      expect(textBaseName('...hidden', now: now), 'hidden');
    });
    test('falls back to a timestamp for a bare link or empty text', () {
      expect(textBaseName('https://example.org/x', now: now),
          'Shared 2026-10-14 090507');
      expect(textBaseName('  ', subject: ' ', now: now),
          'Shared 2026-10-14 090507');
    });
  });
}
