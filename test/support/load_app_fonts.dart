import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Loads the bundled UI fonts into the test engine.
///
/// Without this, `flutter test` draws every glyph as a full em square. That is
/// harmless for a golden that only has to stay equal to itself, but it is not
/// harmless for a layout that *measures* text: "Confirm" comes out 105 px wide
/// instead of ~60, and a footer that fits one row in the app stacks in the
/// test. Any test whose layout depends on text width must call this.
Future<void> loadAppFonts() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final (family, files) in const [
    ('Outfit', [
      'Outfit-Regular.ttf',
      'Outfit-Medium.ttf',
      'Outfit-SemiBold.ttf',
      'Outfit-Bold.ttf',
    ]),
    ('Manrope', [
      'Manrope-Medium.ttf',
      'Manrope-SemiBold.ttf',
      'Manrope-Bold.ttf',
    ]),
  ]) {
    final loader = FontLoader(family);
    for (final file in files) {
      final path = 'assets/fonts/${family.toLowerCase()}/$file';
      loader.addFont(
        File(path).readAsBytes().then((b) => ByteData.sublistView(b)),
      );
    }
    await loader.load();
  }
}
