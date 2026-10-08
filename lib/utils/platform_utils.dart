import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class PlatformUtils {
  static bool _initialized = false;
  static bool _isAndroidEmulator = false;

  static bool get isAndroidEmulator => _isAndroidEmulator;

  static Future<void> initialize() async {
    if (_initialized) return;
    if (Platform.isAndroid) {
      try {
        const channel = MethodChannel('com.alexmercerind/media_kit_video');
        final result = await channel.invokeMethod<bool>('Utils.IsEmulator');
        _isAndroidEmulator = result ?? false;
        debugPrint('[PlatformUtils] isAndroidEmulator: $_isAndroidEmulator');
      } catch (e) {
        debugPrint('[PlatformUtils] Failed to detect emulator: $e');
        _isAndroidEmulator = false;
      }
    }
    _initialized = true;
  }
}
