import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cloud_media_player/models/subtitle_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SubtitleSettings Tests', () {
    test('Default values are set properly', () {
      const settings = SubtitleSettings();
      expect(settings.fontSize, 24.0);
      expect(settings.bottomOffset, 36.0);
      expect(settings.position, SubtitlePosition.bottom);
      expect(settings.textColor, Colors.white);
      expect(settings.backgroundColor, Colors.black);
      expect(settings.backgroundOpacity, 0.5);
    });

    test('SubtitlePosition parse and alignment', () {
      expect(SubtitlePosition.fromString('top'), SubtitlePosition.top);
      expect(SubtitlePosition.fromString('center'), SubtitlePosition.center);
      expect(SubtitlePosition.fromString('bottom'), SubtitlePosition.bottom);
      expect(SubtitlePosition.fromString('invalid'), SubtitlePosition.bottom);

      expect(SubtitlePosition.bottom.alignment, Alignment.bottomCenter);
      expect(SubtitlePosition.center.alignment, Alignment.center);
      expect(SubtitlePosition.top.alignment, Alignment.topCenter);
    });

    test('Save and load from SharedPreferences', () async {
      SharedPreferences.setMockInitialValues({});

      final customSettings = const SubtitleSettings(
        fontSize: 32.0,
        bottomOffset: 48.0,
        position: SubtitlePosition.top,
        textColor: Color(0xFFFFEB3B),
        backgroundColor: Color(0xFF212121),
        backgroundOpacity: 0.8,
      );

      await customSettings.save();

      final loaded = await SubtitleSettings.load();
      expect(loaded.fontSize, 32.0);
      expect(loaded.bottomOffset, 48.0);
      expect(loaded.position, SubtitlePosition.top);
      expect(loaded.textColor.toARGB32(), const Color(0xFFFFEB3B).toARGB32());
      expect(loaded.backgroundColor.toARGB32(), const Color(0xFF212121).toARGB32());
      expect(loaded.backgroundOpacity, 0.8);
    });

    test('copyWith works as expected', () {
      const initial = SubtitleSettings();
      final updated = initial.copyWith(
        fontSize: 28.0,
        backgroundOpacity: 0.0,
        position: SubtitlePosition.center,
      );

      expect(updated.fontSize, 28.0);
      expect(updated.backgroundOpacity, 0.0);
      expect(updated.position, SubtitlePosition.center);
      expect(updated.textColor, initial.textColor);
    });
  });
}
