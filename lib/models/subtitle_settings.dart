import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum SubtitlePosition {
  bottom,
  center,
  top;

  String get label {
    switch (this) {
      case SubtitlePosition.bottom:
        return '하단';
      case SubtitlePosition.center:
        return '중앙';
      case SubtitlePosition.top:
        return '상단';
    }
  }

  Alignment get alignment {
    switch (this) {
      case SubtitlePosition.bottom:
        return Alignment.bottomCenter;
      case SubtitlePosition.center:
        return Alignment.center;
      case SubtitlePosition.top:
        return Alignment.topCenter;
    }
  }

  static SubtitlePosition fromString(String? val) {
    switch (val) {
      case 'top':
        return SubtitlePosition.top;
      case 'center':
        return SubtitlePosition.center;
      case 'bottom':
      default:
        return SubtitlePosition.bottom;
    }
  }
}

class SubtitleSettings {
  final double fontSize;
  final double bottomOffset;
  final SubtitlePosition position;
  final Color textColor;
  final Color backgroundColor;
  final double backgroundOpacity; // 0.0 (완전 투명) ~ 1.0 (완전 불투명)

  const SubtitleSettings({
    this.fontSize = 24.0,
    this.bottomOffset = 36.0,
    this.position = SubtitlePosition.bottom,
    this.textColor = Colors.white,
    this.backgroundColor = Colors.black,
    this.backgroundOpacity = 0.5,
  });

  SubtitleSettings copyWith({
    double? fontSize,
    double? bottomOffset,
    SubtitlePosition? position,
    Color? textColor,
    Color? backgroundColor,
    double? backgroundOpacity,
  }) {
    return SubtitleSettings(
      fontSize: fontSize ?? this.fontSize,
      bottomOffset: bottomOffset ?? this.bottomOffset,
      position: position ?? this.position,
      textColor: textColor ?? this.textColor,
      backgroundColor: backgroundColor ?? this.backgroundColor,
      backgroundOpacity: backgroundOpacity ?? this.backgroundOpacity,
    );
  }

  static const String _keyFontSize = 'subtitle_font_size';
  static const String _keyBottomOffset = 'subtitle_bottom_offset';
  static const String _keyPosition = 'subtitle_position';
  static const String _keyTextColor = 'subtitle_text_color';
  static const String _keyBgColor = 'subtitle_bg_color';
  static const String _keyBgOpacity = 'subtitle_bg_opacity';

  static Future<SubtitleSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final fontSize = prefs.getDouble(_keyFontSize) ?? 24.0;
    final bottomOffset = prefs.getDouble(_keyBottomOffset) ?? 36.0;
    final posStr = prefs.getString(_keyPosition);
    final position = SubtitlePosition.fromString(posStr);
    final textColorValue = prefs.getInt(_keyTextColor) ?? Colors.white.toARGB32();
    final bgColorValue = prefs.getInt(_keyBgColor) ?? Colors.black.toARGB32();
    final bgOpacity = prefs.getDouble(_keyBgOpacity) ?? 0.5;

    return SubtitleSettings(
      fontSize: fontSize.clamp(14.0, 48.0),
      bottomOffset: bottomOffset.clamp(8.0, 150.0),
      position: position,
      textColor: Color(textColorValue),
      backgroundColor: Color(bgColorValue),
      backgroundOpacity: bgOpacity.clamp(0.0, 1.0),
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyFontSize, fontSize);
    await prefs.setDouble(_keyBottomOffset, bottomOffset);
    await prefs.setString(_keyPosition, position.name);
    await prefs.setInt(_keyTextColor, textColor.toARGB32());
    await prefs.setInt(_keyBgColor, backgroundColor.toARGB32());
    await prefs.setDouble(_keyBgOpacity, backgroundOpacity);
  }
}
