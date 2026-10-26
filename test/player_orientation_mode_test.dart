import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cloud_media_player/models/player_orientation_mode.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PlayerOrientationMode Tests', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('fromString parses correctly', () {
      expect(PlayerOrientationMode.fromString('landscape'), PlayerOrientationMode.landscape);
      expect(PlayerOrientationMode.fromString('portrait'), PlayerOrientationMode.portrait);
      expect(PlayerOrientationMode.fromString('sensor'), PlayerOrientationMode.sensor);
      expect(PlayerOrientationMode.fromString('auto'), PlayerOrientationMode.sensor);
      expect(PlayerOrientationMode.fromString(null), PlayerOrientationMode.landscape);
      expect(PlayerOrientationMode.fromString('invalid'), PlayerOrientationMode.landscape);
    });

    test('deviceOrientations provides appropriate orientations', () {
      expect(
        PlayerOrientationMode.landscape.deviceOrientations,
        containsAll([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]),
      );
      expect(
        PlayerOrientationMode.portrait.deviceOrientations,
        containsAll([DeviceOrientation.portraitUp, DeviceOrientation.portraitDown]),
      );
      expect(
        PlayerOrientationMode.sensor.deviceOrientations.length,
        4,
      );
    });

    test('save and load persistence', () async {
      // 초기 기본값 확인
      var mode = await PlayerOrientationMode.load();
      expect(mode, PlayerOrientationMode.landscape);

      // 세로 고정 저장 후 확인
      await PlayerOrientationMode.portrait.save();
      mode = await PlayerOrientationMode.load();
      expect(mode, PlayerOrientationMode.portrait);

      // 센서 가변 저장 후 확인
      await PlayerOrientationMode.sensor.save();
      mode = await PlayerOrientationMode.load();
      expect(mode, PlayerOrientationMode.sensor);
    });
  });
}
