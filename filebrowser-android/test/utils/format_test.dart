import 'package:filebrowser_android/utils/format.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('formatDuration shows hours only when needed', () {
    expect(formatDuration(Duration.zero), '0:00');
    expect(formatDuration(const Duration(seconds: 187)), '3:07');
    expect(formatDuration(const Duration(hours: 1, minutes: 2, seconds: 3)),
        '1:02:03');
  });
}
