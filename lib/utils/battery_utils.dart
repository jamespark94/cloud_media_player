import 'dart:io';
import 'package:flutter/services.dart';

class BatteryUtils {
  static const MethodChannel _channel = MethodChannel('com.example.cloud_media_player/battery');

  /// 기기가 현재 절전 모드(Power Save Mode)인지 여부 반환
  static Future<bool> isPowerSaveMode() async {
    if (!Platform.isAndroid) return false;
    try {
      final res = await _channel.invokeMethod<bool>('isPowerSaveMode');
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 앱이 배터리 최적화 예외(제한 없음)로 설정되어 있는지 여부 반환
  static Future<bool> isIgnoringBatteryOptimizations() async {
    if (!Platform.isAndroid) return true;
    try {
      final res = await _channel.invokeMethod<bool>('isIgnoringBatteryOptimizations');
      return res ?? false;
    } catch (_) {
      return true;
    }
  }

  /// 배터리 사용량 제한 없음(최적화 제외) 시스템 대화상자 요청
  static Future<bool> requestIgnoreBatteryOptimizations() async {
    if (!Platform.isAndroid) return false;
    try {
      final res = await _channel.invokeMethod<bool>('requestIgnoreBatteryOptimizations');
      return res ?? false;
    } catch (_) {
      return false;
    }
  }
}
