import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cloud_media_player/services/playback_history_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('PlaybackHistoryService Remote Sync Merge Tests', () {
    test('mergeWithRemote correctly resolves conflict with newest record', () async {
      final service = PlaybackHistoryService.instance;

      final localRecord = PlaybackRecord(
        itemId: 'video_1',
        accountId: 'acc_1',
        fileName: 'movie_sample.mp4',
        positionMillis: 10000,
        durationMillis: 100000,
        lastUpdated: 1000,
      );

      final remoteRecord = PlaybackRecord(
        itemId: 'video_1',
        accountId: 'acc_1',
        fileName: 'movie_sample.mp4',
        positionMillis: 45000,
        durationMillis: 100000,
        lastUpdated: 2000,
      );

      final remoteNewRecord = PlaybackRecord(
        itemId: 'video_2',
        accountId: 'acc_1',
        fileName: 'series_ep01.mkv',
        positionMillis: 30000,
        durationMillis: 60000,
        lastUpdated: 1500,
      );

      // 로컬에 하나 저장
      await service.mergeWithRemote([localRecord]);

      // 원격 레코드들과 병합
      final merged = await service.mergeWithRemote([remoteRecord, remoteNewRecord]);

      expect(merged.length, 2);

      final item1 = merged.firstWhere((r) => r.itemId == 'video_1');
      expect(item1.positionMillis, 45000);
      expect(item1.lastUpdated, 2000);

      final item2 = merged.firstWhere((r) => r.itemId == 'video_2');
      expect(item2.fileName, 'series_ep01.mkv');
      expect(item2.positionMillis, 30000);
    });
  });
}
