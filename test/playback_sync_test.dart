import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cloud_media_player/models/media_item.dart';
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

    test('getRecord and getSavedPosition work seamlessly across different accountIds', () async {
      final service = PlaybackHistoryService.instance;

      // 기기 A(acc_device_A)에서 시청한 기록
      final recordDeviceA = PlaybackRecord(
        itemId: 'video_shared_123',
        accountId: 'acc_device_A',
        fileName: 'great_movie.mp4',
        positionMillis: 75000,
        durationMillis: 120000,
        lastUpdated: 5000,
        subtitleType: 'cloud',
        subtitleId: 'sub_shared_456',
        subtitleName: 'great_movie.ko.smi',
        subtitleLanguage: 'ko',
      );

      // 클라우드 동기화로 기기 B에 병합됨
      await service.mergeWithRemote([recordDeviceA]);

      // 기기 B(acc_device_B)에서 동일 미디어 항목 재생 시도
      final mediaItemOnDeviceB = MediaItem(
        id: 'video_shared_123',
        name: 'great_movie.mp4',
        isFolder: false,
      );

      final record = await service.getRecord(
        accountId: 'acc_device_B',
        item: mediaItemOnDeviceB,
      );

      expect(record, isNotNull);
      expect(record!.positionMillis, 75000);
      expect(record.subtitleType, 'cloud');
      expect(record.subtitleId, 'sub_shared_456');
      expect(record.subtitleName, 'great_movie.ko.smi');
      expect(record.subtitleLanguage, 'ko');

      final pos = await service.getSavedPosition(
        accountId: 'acc_device_B',
        item: mediaItemOnDeviceB,
      );
      expect(pos, const Duration(milliseconds: 75000));
    });

    test('removeRecord records tombstone and prevents zombie record resurrection', () async {
      final service = PlaybackHistoryService.instance;

      final testRecord = PlaybackRecord(
        itemId: 'video_to_delete',
        accountId: 'acc_1',
        fileName: 'zombie_candidate.mp4',
        positionMillis: 50000,
        durationMillis: 100000,
        lastUpdated: 1000,
      );

      // 1. 처음엔 로컬에 저장
      await service.mergeWithRemote([testRecord]);
      var all = await service.getAllRecords();
      expect(all.any((r) => r.itemId == 'video_to_delete'), isTrue);

      // 2. 사용자가 삭제 (Tombstone 생성)
      await service.removeRecord(
        accountId: 'acc_1',
        itemId: 'video_to_delete',
        fileName: 'zombie_candidate.mp4',
      );
      all = await service.getAllRecords();
      expect(all.any((r) => r.itemId == 'video_to_delete'), isFalse);

      final deleted = await service.getDeletedRecords();
      expect(deleted.containsKey('video_to_delete'), isTrue);

      // 3. 클라우드에서 이전 원격 레코드(lastUpdated: 1000)가 다시 동기화 시도되어도 부활하지 않아야 함
      await service.mergeWithRemote([testRecord]);
      all = await service.getAllRecords();
      expect(all.any((r) => r.itemId == 'video_to_delete'), isFalse); // 좀비 부활 방지 성공!
    });

    test('remote deletion syncs to local device and removes local record', () async {
      final service = PlaybackHistoryService.instance;

      final localRecord = PlaybackRecord(
        itemId: 'video_device_b',
        accountId: 'acc_device_b',
        fileName: 'remote_deleted_movie.mp4',
        positionMillis: 20000,
        durationMillis: 80000,
        lastUpdated: 1000,
      );

      // 기기 B 로컬에 존재
      await service.mergeWithRemote([localRecord]);
      var all = await service.getAllRecords();
      expect(all.any((r) => r.itemId == 'video_device_b'), isTrue);

      // 타 기기(기기 A)에서 방금 삭제되었다는 tombstone 정보 수신 (deletedAt: now > lastUpdated: 1000)
      final now = DateTime.now().millisecondsSinceEpoch;
      await service.mergeWithRemote(
        [],
        remoteDeletedRecords: {'video_device_b': now},
      );

      all = await service.getAllRecords();
      expect(all.any((r) => r.itemId == 'video_device_b'), isFalse); // 기기 B에서도 정상 삭제됨!
    });
  });
}
