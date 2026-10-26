import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 비디오 플레이어 화면 회전 및 방향 모드
enum PlayerOrientationMode {
  /// 가로 화면 고정 (Landscape)
  landscape('가로 고정'),

  /// 세로 화면 고정 (Portrait)
  portrait('세로 고정'),

  /// 기기 센서 회전에 따라 자동 가변 (Auto / Sensor)
  sensor('센서 자동 가변');

  final String label;
  const PlayerOrientationMode(this.label);

  static const String prefKey = 'player_orientation_mode';

  /// SharedPreferences 저장 값으로부터 복원
  static PlayerOrientationMode fromString(String? value) {
    switch (value) {
      case 'portrait':
        return PlayerOrientationMode.portrait;
      case 'sensor':
      case 'auto':
        return PlayerOrientationMode.sensor;
      case 'landscape':
      default:
        return PlayerOrientationMode.landscape;
    }
  }

  /// 방향 모드에 대응하는 DeviceOrientation 리스트 반환
  List<DeviceOrientation> get deviceOrientations {
    switch (this) {
      case PlayerOrientationMode.landscape:
        return const [
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ];
      case PlayerOrientationMode.portrait:
        return const [
          DeviceOrientation.portraitUp,
          DeviceOrientation.portraitDown,
        ];
      case PlayerOrientationMode.sensor:
        return const [
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
          DeviceOrientation.portraitUp,
          DeviceOrientation.portraitDown,
        ];
    }
  }

  /// 설정 저장
  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(prefKey, name);
  }

  /// 저장된 설정 로드 (기본값: landscape)
  static Future<PlayerOrientationMode> load() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(prefKey);
    return fromString(value);
  }
}
