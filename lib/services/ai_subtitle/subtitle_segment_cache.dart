import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../../models/ai_subtitle/ai_subtitle_config.dart';
import '../../models/ai_subtitle/subtitle_segment.dart';

/// 청크 처리 상태.
enum ChunkProcessState {
  unprocessed,
  processing,
  completed,
  failed,
}

/// 설정 가능 단위(온디바이스 20초, 클라우드 AI 45초) 버킷 인덱싱 기반의 자막 세그먼트 캐시.
///
/// - 사용자가 뒤로 감기(Seek)를 수행할 때 이미 생성된 자막을 재추론 없이 0ms 만에 즉시 반환합니다.
/// - (mediaItemId, sourceLanguage, engineKey, chunkSeconds) 및 Chunk Key 단위로 중복 호출을 방어합니다.
class SubtitleSegmentCache {
  final int chunkSeconds;
  final Map<int, List<SubtitleSegment>> _buckets = {};
  final Map<int, ChunkProcessState> _states = {};
  final Map<int, int> _retryCounts = {};
  final Set<String> _processedChunkKeys = <String>{};

  String? _activeCacheKey;

  SubtitleSegmentCache({this.chunkSeconds = 20});

  int bucketIndexFor(Duration position) {
    if (position <= Duration.zero) return 0;
    return position.inSeconds ~/ chunkSeconds;
  }

  Duration bucketStartFor(int bucketIndex) {
    return Duration(seconds: bucketIndex * chunkSeconds);
  }

  Duration bucketDuration() => Duration(seconds: chunkSeconds);

  /// 시간 구간 중복 체크용 고유 Chunk Key 생성.
  String chunkKeyFor(int bucketIndex) {
    final prefix = _activeCacheKey ?? 'default';
    return '${prefix}_b${bucketIndex}_s$chunkSeconds';
  }

  /// 이미 완료되었거나 현재 처리 중인 구간인지(Chunk Key 포함) 검사합니다.
  bool isChunkProcessedOrActive(int bucketIndex) {
    final state = getState(bucketIndex);
    if (state == ChunkProcessState.completed ||
        state == ChunkProcessState.processing) {
      return true;
    }
    return _processedChunkKeys.contains(chunkKeyFor(bucketIndex));
  }

  ChunkProcessState getState(int bucketIndex) {
    return _states[bucketIndex] ?? ChunkProcessState.unprocessed;
  }

  int getRetryCount(int bucketIndex) => _retryCounts[bucketIndex] ?? 0;

  void markProcessing(int bucketIndex) {
    _states[bucketIndex] = ChunkProcessState.processing;
  }

  void markCompleted(int bucketIndex) {
    _states[bucketIndex] = ChunkProcessState.completed;
    _processedChunkKeys.add(chunkKeyFor(bucketIndex));
  }

  void markFailed(int bucketIndex) {
    final retries = (_retryCounts[bucketIndex] ?? 0) + 1;
    _retryCounts[bucketIndex] = retries;
    _states[bucketIndex] = ChunkProcessState.failed;
  }

  void resetProcessingToUnprocessed(int bucketIndex) {
    if (_states[bucketIndex] == ChunkProcessState.processing) {
      _states[bucketIndex] = ChunkProcessState.unprocessed;
    }
  }

  void insertSegment(int bucketIndex, SubtitleSegment segment) {
    if (segment.originalText.trim().isEmpty &&
        (segment.translatedText ?? '').trim().isEmpty) {
      return;
    }
    final list = _buckets.putIfAbsent(bucketIndex, () => []);
    final exists = list.any((s) =>
        s.startTime == segment.startTime &&
        s.endTime == segment.endTime &&
        s.originalText == segment.originalText);
    if (!exists) {
      list.add(segment);
      list.sort((a, b) => a.startTime.compareTo(b.startTime));
    }
  }

  /// 현재 재생 시점([position])에 해당하는 자막 세그먼트를 조회합니다.
  /// 세그먼트 경계 오차를 보완하기 위해 인접 버킷까지 안전하게 탐색합니다.
  SubtitleSegment? findAt(Duration position) {
    if (_buckets.isEmpty) return null;
    final idx = bucketIndexFor(position);
    final candidates = <int>[idx, if (idx > 0) idx - 1, idx + 1];

    SubtitleSegment? bestMatch;
    for (final bIdx in candidates) {
      final segments = _buckets[bIdx];
      if (segments == null || segments.isEmpty) continue;
      for (final seg in segments) {
        if (seg.contains(position)) {
          bestMatch = seg;
        }
      }
      if (bestMatch != null) return bestMatch;
    }
    return null;
  }

  UnmodifiableListView<SubtitleSegment> segmentsInBucket(int bucketIndex) {
    return UnmodifiableListView(_buckets[bucketIndex] ?? const []);
  }

  int get totalSegmentCount {
    var count = 0;
    for (final list in _buckets.values) {
      count += list.length;
    }
    return count;
  }

  /// 현재까지 캐싱된 모든 자막 세그먼트를 시간 순으로 정렬·중복 제거하여 반환합니다.
  List<SubtitleSegment> getAllSegmentsSorted() {
    if (_buckets.isEmpty) return const [];
    final all = <SubtitleSegment>[];
    for (final list in _buckets.values) {
      all.addAll(list);
    }
    all.sort((a, b) {
      final cmp = a.startTime.compareTo(b.startTime);
      if (cmp != 0) return cmp;
      return a.endTime.compareTo(b.endTime);
    });

    final deduped = <SubtitleSegment>[];
    for (final seg in all) {
      final duplicate = deduped.any((prev) =>
          prev.startTime == seg.startTime &&
          prev.endTime == seg.endTime &&
          prev.originalText == seg.originalText);
      if (!duplicate) {
        deduped.add(seg);
      }
    }
    return deduped;
  }

  /// 현재까지 캐싱된 자막을 표준 `.srt` 문자열로 변환합니다.
  String exportAsSrt({
    AiSubtitleDisplayMode displayMode = AiSubtitleDisplayMode.dual,
  }) {
    final segments = getAllSegmentsSorted();
    if (segments.isEmpty) return '';

    final buf = StringBuffer();
    var cueIndex = 1;
    for (final seg in segments) {
      final text = seg.formatForDisplay(displayMode: displayMode).trim();
      if (text.isEmpty) continue;
      final end = seg.endTime > seg.startTime
          ? seg.endTime
          : seg.startTime + const Duration(milliseconds: 1500);
      buf.writeln(cueIndex++);
      buf.writeln('${_formatSrtTime(seg.startTime)} --> ${_formatSrtTime(end)}');
      buf.writeln(text);
      buf.writeln();
    }
    return buf.toString();
  }

  static String _formatSrtTime(Duration d) {
    final safe = d.isNegative ? Duration.zero : d;
    final hours = safe.inHours.toString().padLeft(2, '0');
    final minutes = safe.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = safe.inSeconds.remainder(60).toString().padLeft(2, '0');
    final millis = safe.inMilliseconds.remainder(1000).toString().padLeft(3, '0');
    return '$hours:$minutes:$seconds,$millis';
  }

  /// 미디어/언어/엔진 컨텍스트 전환 시 메모리 캐시 초기화 및 디스크 캐시 복원 시도.
  Future<void> switchContext({
    required String mediaItemId,
    required String sourceLanguage,
    String engineKey = 'onDevice',
  }) async {
    final nextKey = '${mediaItemId}_${sourceLanguage}_${engineKey}_$chunkSeconds';
    if (_activeCacheKey == nextKey) return;

    clearMemory();
    _activeCacheKey = nextKey;
    await _tryLoadFromDisk(nextKey);
  }

  void clearMemory() {
    _buckets.clear();
    _states.clear();
    _retryCounts.clear();
    _processedChunkKeys.clear();
  }

  void clearAll() {
    _activeCacheKey = null;
    clearMemory();
  }

  File _getDiskCacheFile(String key) {
    final hash = key.hashCode.toUnsigned(32).toRadixString(16);
    final dir = Directory('${Directory.systemTemp.path}/ai_subtitles_cache');
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return File('${dir.path}/aisub_$hash.json');
  }

  Future<void> persistToDisk() async {
    final key = _activeCacheKey;
    if (key == null || _buckets.isEmpty) return;
    try {
      final completedBuckets = <String, dynamic>{};
      for (final entry in _buckets.entries) {
        if (_states[entry.key] == ChunkProcessState.completed) {
          completedBuckets[entry.key.toString()] =
              entry.value.map((s) => s.toJson()).toList();
        }
      }
      if (completedBuckets.isEmpty) return;

      final payload = jsonEncode({
        'cacheVersion': 2,
        'chunkSeconds': chunkSeconds,
        'buckets': completedBuckets,
      });
      await _getDiskCacheFile(key).writeAsString(payload);
    } catch (e) {
      debugPrint('[SubtitleSegmentCache] 디스크 캐시 저장 무시: $e');
    }
  }

  Future<void> _tryLoadFromDisk(String key) async {
    try {
      final file = _getDiskCacheFile(key);
      if (!file.existsSync()) return;
      final raw = await file.readAsString();
      if (raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return;
      if ((decoded['cacheVersion'] as num?)?.toInt() != 2) return;
      if ((decoded['chunkSeconds'] as num?)?.toInt() != chunkSeconds) return;

      final bucketsMap = decoded['buckets'];
      if (bucketsMap is! Map<String, dynamic>) return;

      for (final entry in bucketsMap.entries) {
        final bIdx = int.tryParse(entry.key);
        if (bIdx == null || entry.value is! List) continue;
        final list = <SubtitleSegment>[];
        for (final item in (entry.value as List)) {
          if (item is Map<String, dynamic>) {
            list.add(SubtitleSegment.fromJson(item));
          }
        }
        if (list.isNotEmpty) {
          list.sort((a, b) => a.startTime.compareTo(b.startTime));
          _buckets[bIdx] = list;
        }
        markCompleted(bIdx);
      }
      debugPrint(
        '[SubtitleSegmentCache] 디스크 캐시 복원 완료 ($totalSegmentCount 세그먼트)',
      );
    } catch (e) {
      debugPrint('[SubtitleSegmentCache] 디스크 캐시 복원 무시: $e');
    }
  }
}
