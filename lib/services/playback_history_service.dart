import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/media_item.dart';

class PlaybackRecord {
  final String itemId;
  final String accountId;
  final String fileName;
  final String? parentId;
  final int? fileSize;
  final int positionMillis;
  final int durationMillis;
  final int lastUpdated;

  // 자막 파일 및 언어 설정 기억
  final String? subtitleType; // 'none', 'cloud', 'local', 'track'
  final String? subtitleId; // cloud file id, local path, or track id
  final String? subtitleName; // file name or track title
  final String? subtitleLanguage; // track language ('ko', 'en', 'krcc', ...)

  // 동영상 썸네일 (클라우드 URL 및 로컬 캡처 이미지 경로)
  final String? thumbnailUrl;
  final String? localThumbnailPath;

  PlaybackRecord({
    required this.itemId,
    required this.accountId,
    required this.fileName,
    this.parentId,
    this.fileSize,
    required this.positionMillis,
    required this.durationMillis,
    required this.lastUpdated,
    this.subtitleType,
    this.subtitleId,
    this.subtitleName,
    this.subtitleLanguage,
    this.thumbnailUrl,
    this.localThumbnailPath,
  });

  Duration get position => Duration(milliseconds: positionMillis);
  Duration get duration => Duration(milliseconds: durationMillis);

  double get progress {
    if (durationMillis <= 0) return 0.0;
    return (positionMillis / durationMillis).clamp(0.0, 1.0);
  }

  String get formattedPosition {
    final d = position;
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (hours > 0) {
      return '$hours:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }

  String get formattedDuration {
    if (durationMillis <= 0) return '--:--';
    final d = duration;
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (hours > 0) {
      return '$hours:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }

  MediaItem toMediaItem() => MediaItem(
    id: itemId,
    name: fileName,
    parentId: parentId,
    isFolder: false,
    size: fileSize,
    thumbnailUrl: thumbnailUrl,
    duration: durationMillis > 0 ? Duration(milliseconds: durationMillis) : null,
  );

  Map<String, dynamic> toJson() => {
    'itemId': itemId,
    'accountId': accountId,
    'fileName': fileName,
    'parentId': parentId,
    'fileSize': fileSize,
    'positionMillis': positionMillis,
    'durationMillis': durationMillis,
    'lastUpdated': lastUpdated,
    'subtitleType': subtitleType,
    'subtitleId': subtitleId,
    'subtitleName': subtitleName,
    'subtitleLanguage': subtitleLanguage,
    'thumbnailUrl': thumbnailUrl,
    'localThumbnailPath': localThumbnailPath,
  };

  factory PlaybackRecord.fromJson(Map<String, dynamic> json) {
    var subType = json['subtitleType'] as String?;
    final subName = json['subtitleName'] as String?;
    if (subType == 'track' && subName != null) {
      final lower = subName.toLowerCase();
      if (lower.endsWith('.smi') || lower.endsWith('.srt') || lower.endsWith('.ass') || lower.endsWith('.vtt')) {
        subType = 'cloud';
      }
    }

    return PlaybackRecord(
      itemId: json['itemId'] as String? ?? '',
      accountId: json['accountId'] as String? ?? '',
      fileName: json['fileName'] as String? ?? '',
      parentId: json['parentId'] as String?,
      fileSize: (json['fileSize'] as num?)?.toInt(),
      positionMillis: (json['positionMillis'] as num?)?.toInt() ?? 0,
      durationMillis: (json['durationMillis'] as num?)?.toInt() ?? 0,
      lastUpdated: (json['lastUpdated'] as num?)?.toInt() ?? 0,
      subtitleType: subType,
      subtitleId: json['subtitleId'] as String?,
      subtitleName: subName,
      subtitleLanguage: json['subtitleLanguage'] as String?,
      thumbnailUrl: json['thumbnailUrl'] as String?,
      localThumbnailPath: json['localThumbnailPath'] as String?,
    );
  }
}

class PlaybackHistoryService extends ChangeNotifier {
  static final PlaybackHistoryService instance = PlaybackHistoryService._internal();
  PlaybackHistoryService._internal();

  static const String _storageKey = 'cloud_media_playback_history';
  Map<String, PlaybackRecord>? _cache;

  String _generateKey(String accountId, String itemId) => '${accountId}_$itemId';

  Future<Map<String, PlaybackRecord>> _loadAll() async {
    if (_cache != null) return _cache!;
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = prefs.getString(_storageKey);
      if (jsonStr != null && jsonStr.isNotEmpty) {
        final decoded = json.decode(jsonStr) as Map<String, dynamic>;
        _cache = decoded.map((k, v) => MapEntry(k, PlaybackRecord.fromJson(v as Map<String, dynamic>)));
        return _cache!;
      }
    } catch (e) {
      debugPrint('재생 기록 불러오기 실패: $e');
    }
    _cache = {};
    return _cache!;
  }

  Future<void> _saveAll() async {
    if (_cache == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final mapToSave = _cache!.map((k, v) => MapEntry(k, v.toJson()));
      await prefs.setString(_storageKey, json.encode(mapToSave));
    } catch (e) {
      debugPrint('재생 기록 저장 실패: $e');
    }
  }

  /// 전체 기록 목록 반환
  Future<List<PlaybackRecord>> getAllRecords() async {
    final all = await _loadAll();
    return all.values.toList();
  }

  /// 원격 클라우드 재생 기록 목록과 로컬 목록을 스마트 병합
  Future<List<PlaybackRecord>> mergeWithRemote(List<PlaybackRecord> remoteRecords) async {
    final all = await _loadAll();

    for (final remote in remoteRecords) {
      final remoteKey = _generateKey(remote.accountId, remote.itemId);

      // 로컬에 기존 매칭되는 레코드가 있는지 검사 (키, itemId, fileName 기준)
      String? matchedOldKey;
      PlaybackRecord? existing;

      if (all.containsKey(remoteKey)) {
        matchedOldKey = remoteKey;
        existing = all[remoteKey];
      } else {
        for (final entry in all.entries) {
          if (entry.value.itemId == remote.itemId || entry.value.fileName == remote.fileName) {
            matchedOldKey = entry.key;
            existing = entry.value;
            break;
          }
        }
      }

      if (existing == null) {
        all[remoteKey] = remote;
      } else {
        // 기존 레코드가 remoteKey와 다른 키에 있었다면 구버전 중복 키 정리
        if (matchedOldKey != null && matchedOldKey != remoteKey) {
          all.remove(matchedOldKey);
        }

        final bool remoteIsNewer = remote.lastUpdated > existing.lastUpdated;
        final newerRecord = remoteIsNewer ? remote : existing;
        final olderRecord = remoteIsNewer ? existing : remote;

        int resolvedPosition = newerRecord.positionMillis;
        if (resolvedPosition < 5000 && olderRecord.positionMillis > resolvedPosition) {
          resolvedPosition = olderRecord.positionMillis;
        }

        final merged = PlaybackRecord(
          itemId: existing.itemId.isNotEmpty ? existing.itemId : remote.itemId,
          accountId: existing.accountId.isNotEmpty ? existing.accountId : remote.accountId,
          fileName: existing.fileName.isNotEmpty ? existing.fileName : remote.fileName,
          parentId: existing.parentId ?? remote.parentId,
          fileSize: existing.fileSize ?? remote.fileSize,
          positionMillis: resolvedPosition,
          durationMillis: newerRecord.durationMillis > 0 ? newerRecord.durationMillis : olderRecord.durationMillis,
          lastUpdated: math.max(existing.lastUpdated, remote.lastUpdated),
          subtitleType: newerRecord.subtitleType ?? olderRecord.subtitleType,
          subtitleId: newerRecord.subtitleId ?? olderRecord.subtitleId,
          subtitleName: newerRecord.subtitleName ?? olderRecord.subtitleName,
          subtitleLanguage: newerRecord.subtitleLanguage ?? olderRecord.subtitleLanguage,
          thumbnailUrl: existing.thumbnailUrl ?? remote.thumbnailUrl,
          localThumbnailPath: existing.localThumbnailPath ?? remote.localThumbnailPath,
        );

        final targetKey = _generateKey(merged.accountId, merged.itemId);
        all[targetKey] = merged;
      }
    }

    _cache = all;
    await _saveAll();
    notifyListeners();
    return getHistoryList();
  }

  /// 최근 재생한 기록 목록을 최신 재생순(lastUpdated 내림차순)으로 반환합니다.
  Future<List<PlaybackRecord>> getHistoryList({int limit = 30}) async {
    final all = await _loadAll();
    final list = all.values.toList();
    list.sort((a, b) => b.lastUpdated.compareTo(a.lastUpdated));
    if (limit > 0 && list.length > limit) {
      return list.sublist(0, limit);
    }
    return list;
  }

  /// 특정 미디어의 이전 저장된 이어보기 위치(Duration)를 반환합니다.
  /// 5초 미만이거나 영상 끝(종료 15초 전 또는 95% 이상)에 도달한 경우 null을 반환합니다.
  Future<Duration?> getSavedPosition({
    required String accountId,
    required MediaItem item,
  }) async {
    final record = await getRecord(accountId: accountId, item: item);
    if (record == null) return null;

    final posMillis = record.positionMillis;
    final durMillis = record.durationMillis;

    // 5초 미만 재생은 이어보기 불필요
    if (posMillis < 5000) return null;

    // 영상 거의 끝(종료 15초 전 또는 95% 이상 시청)까지 봤다면 처음부터 시작
    if (durMillis > 0) {
      if (posMillis >= durMillis - 15000 || (posMillis / durMillis) > 0.95) {
        return null;
      }
    }

    return Duration(milliseconds: posMillis);
  }

  /// 특정 미디어의 이어보기 위치, 자막 및 썸네일 설정을 로컬 디바이스에 저장합니다.
  Future<void> savePosition({
    required String accountId,
    required MediaItem item,
    required Duration position,
    required Duration totalDuration,
    String? subtitleType,
    String? subtitleId,
    String? subtitleName,
    String? subtitleLanguage,
    String? localThumbnailPath,
  }) async {
    final all = await _loadAll();
    final key = _generateKey(accountId, item.id);

    final posMillis = position.inMilliseconds;
    final durMillis = totalDuration.inMilliseconds;

    // 이전 자막, 썸네일 및 메타 설정 유지 (타 기기에서 동기화된 키가 있다면 정리 후 메타데이터 계승)
    PlaybackRecord? existing = all[key];
    if (existing == null) {
      for (final entry in all.entries.toList()) {
        if (entry.value.itemId == item.id || entry.value.fileName == item.name) {
          existing = entry.value;
          all.remove(entry.key);
          break;
        }
      }
    }
    final subType = subtitleType ?? existing?.subtitleType;
    final subId = subtitleId ?? existing?.subtitleId;
    final subName = subtitleName ?? existing?.subtitleName;
    final subLang = subtitleLanguage ?? existing?.subtitleLanguage;
    final pId = item.parentId ?? existing?.parentId;
    final fSize = item.size ?? existing?.fileSize;
    final thumbUrl = item.thumbnailUrl ?? existing?.thumbnailUrl;
    final localThumb = localThumbnailPath ?? existing?.localThumbnailPath;

    // 1. 5초 미만 재생인 경우 재생 위치는 0이지만 자막 및 썸네일 설정은 보존
    if (posMillis < 5000) {
      if (subType != null || thumbUrl != null || localThumb != null) {
        all[key] = PlaybackRecord(
          itemId: item.id,
          accountId: accountId,
          fileName: item.name,
          parentId: pId,
          fileSize: fSize,
          positionMillis: 0,
          durationMillis: durMillis,
          lastUpdated: DateTime.now().millisecondsSinceEpoch,
          subtitleType: subType,
          subtitleId: subId,
          subtitleName: subName,
          subtitleLanguage: subLang,
          thumbnailUrl: thumbUrl,
          localThumbnailPath: localThumb,
        );
        await _saveAll();
        notifyListeners();
      } else if (all.containsKey(key)) {
        all.remove(key);
        await _saveAll();
        notifyListeners();
      }
      return;
    }

    // 2. 영상 끝부분(종료 15초 전 또는 95% 이상) 도달 시 시청 완료로 간주하여 위치는 리셋하되 자막 및 썸네일 설정은 보존
    if (durMillis > 0 && (posMillis >= durMillis - 15000 || (posMillis / durMillis) > 0.95)) {
      if (subType != null || thumbUrl != null || localThumb != null) {
        all[key] = PlaybackRecord(
          itemId: item.id,
          accountId: accountId,
          fileName: item.name,
          parentId: pId,
          fileSize: fSize,
          positionMillis: 0,
          durationMillis: durMillis,
          lastUpdated: DateTime.now().millisecondsSinceEpoch,
          subtitleType: subType,
          subtitleId: subId,
          subtitleName: subName,
          subtitleLanguage: subLang,
          thumbnailUrl: thumbUrl,
          localThumbnailPath: localThumb,
        );
      } else {
        all.remove(key);
      }
      await _saveAll();
      notifyListeners();
      return;
    }

    // 3. 정상 중간 위치 및 자막/썸네일 설정 저장
    all[key] = PlaybackRecord(
      itemId: item.id,
      accountId: accountId,
      fileName: item.name,
      parentId: pId,
      fileSize: fSize,
      positionMillis: posMillis,
      durationMillis: durMillis,
      lastUpdated: DateTime.now().millisecondsSinceEpoch,
      subtitleType: subType,
      subtitleId: subId,
      subtitleName: subName,
      subtitleLanguage: subLang,
      thumbnailUrl: thumbUrl,
      localThumbnailPath: localThumb,
    );

    await _saveAll();
    notifyListeners();
  }

  /// 특정 미디어의 이어보기 기록을 삭제하거나 초기화합니다.
  Future<void> clearPosition({
    required String accountId,
    required MediaItem item,
    bool preserveSubtitle = true,
  }) async {
    final all = await _loadAll();
    final key = _generateKey(accountId, item.id);
    if (all.containsKey(key)) {
      if (preserveSubtitle &&
          (all[key]?.subtitleType != null ||
              all[key]?.thumbnailUrl != null ||
              all[key]?.localThumbnailPath != null)) {
        final ex = all[key]!;
        all[key] = PlaybackRecord(
          itemId: ex.itemId,
          accountId: ex.accountId,
          fileName: ex.fileName,
          parentId: ex.parentId,
          fileSize: ex.fileSize,
          positionMillis: 0,
          durationMillis: ex.durationMillis,
          lastUpdated: DateTime.now().millisecondsSinceEpoch,
          subtitleType: ex.subtitleType,
          subtitleId: ex.subtitleId,
          subtitleName: ex.subtitleName,
          subtitleLanguage: ex.subtitleLanguage,
          thumbnailUrl: ex.thumbnailUrl,
          localThumbnailPath: ex.localThumbnailPath,
        );
      } else {
        all.remove(key);
      }
      await _saveAll();
      notifyListeners();
    }
  }

  /// 특정 재생 기록 삭제
  Future<void> removeRecord({
    required String accountId,
    required String itemId,
  }) async {
    final all = await _loadAll();
    final key = _generateKey(accountId, itemId);
    if (all.containsKey(key)) {
      final rec = all[key];
      if (rec?.localThumbnailPath != null) {
        try {
          final file = File(rec!.localThumbnailPath!);
          if (file.existsSync()) {
            file.deleteSync();
          }
        } catch (_) {}
      }
      all.remove(key);
      await _saveAll();
      notifyListeners();
    }
  }

  /// 전체 히스토리 삭제
  Future<void> clearAllHistory() async {
    final all = await _loadAll();
    for (final rec in all.values) {
      if (rec.localThumbnailPath != null) {
        try {
          final file = File(rec.localThumbnailPath!);
          if (file.existsSync()) {
            file.deleteSync();
          }
        } catch (_) {}
      }
    }
    all.clear();
    await _saveAll();
    notifyListeners();
  }

  /// 로컬 비디오 캡처 썸네일 경로 업데이트
  Future<void> updateLocalThumbnail({
    required String accountId,
    required String itemId,
    required String path,
  }) async {
    final all = await _loadAll();
    final key = _generateKey(accountId, itemId);
    final existing = all[key];
    if (existing != null) {
      all[key] = PlaybackRecord(
        itemId: existing.itemId,
        accountId: existing.accountId,
        fileName: existing.fileName,
        parentId: existing.parentId,
        fileSize: existing.fileSize,
        positionMillis: existing.positionMillis,
        durationMillis: existing.durationMillis,
        lastUpdated: existing.lastUpdated,
        subtitleType: existing.subtitleType,
        subtitleId: existing.subtitleId,
        subtitleName: existing.subtitleName,
        subtitleLanguage: existing.subtitleLanguage,
        thumbnailUrl: existing.thumbnailUrl,
        localThumbnailPath: path,
      );
      await _saveAll();
      notifyListeners();
    }
  }

  /// 클라우드 썸네일 URL 업데이트
  Future<void> updateThumbnailUrl({
    required String accountId,
    required String itemId,
    required String url,
  }) async {
    final all = await _loadAll();
    final key = _generateKey(accountId, itemId);
    final existing = all[key];
    if (existing != null && existing.thumbnailUrl != url) {
      all[key] = PlaybackRecord(
        itemId: existing.itemId,
        accountId: existing.accountId,
        fileName: existing.fileName,
        parentId: existing.parentId,
        fileSize: existing.fileSize,
        positionMillis: existing.positionMillis,
        durationMillis: existing.durationMillis,
        lastUpdated: existing.lastUpdated,
        subtitleType: existing.subtitleType,
        subtitleId: existing.subtitleId,
        subtitleName: existing.subtitleName,
        subtitleLanguage: existing.subtitleLanguage,
        thumbnailUrl: url,
        localThumbnailPath: existing.localThumbnailPath,
      );
      await _saveAll();
      notifyListeners();
    }
  }

  /// 썸네일 로컬 캐시 디렉터리 경로 반환
  Future<String> getThumbnailDir() async {
    final localAppData = Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path;
    final dir = Directory('$localAppData\\CloudMediaPlayer\\thumbnails');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir.path;
  }

  /// 특정 미디어의 재생 기록 객체를 반환 (UI 프로그레스 바 및 자막 복원용)
  /// 타 기기에서 동기화되어 accountId가 다르거나 키가 일치하지 않더라도
  /// 1. 직접 키 2. itemId 3. 최신 fileName 순으로 완벽하게 매칭합니다.
  Future<PlaybackRecord?> getRecord({
    required String accountId,
    required MediaItem item,
  }) async {
    final all = await _loadAll();

    // 1. 현재 accountId + itemId 직접 매칭
    final directKey = _generateKey(accountId, item.id);
    if (all.containsKey(directKey)) return all[directKey];

    // 2. itemId 기준 매칭 (타 기기에서 계정 ID 접두사만 다르고 파일 ID는 동일한 경우)
    final byItemId = all.values.cast<PlaybackRecord?>().firstWhere(
      (r) => r?.itemId == item.id,
      orElse: () => null,
    );
    if (byItemId != null) return byItemId;

    // 3. 파일 이름 기준 매칭 (타 기기 동기화 또는 폴백) - 가장 최근 시청 기록 우선
    final matchingByName = all.values.where((r) => r.fileName == item.name).toList();
    if (matchingByName.isNotEmpty) {
      matchingByName.sort((a, b) => b.lastUpdated.compareTo(a.lastUpdated));
      return matchingByName.first;
    }

    return null;
  }
}
