import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../../../models/ai_subtitle/ai_subtitle_config.dart';
import '../../../models/ai_subtitle/subtitle_segment.dart';
import '../extractors/audio_chunk_extractor.dart';
import '../stt/whisper_chunk_runner.dart';
import '../stt/whisper_isolate_worker.dart';
import '../subtitle_generator_engine.dart';
import '../translators/google_web_batch_translator.dart';

/// 번역 전 문장 병합(Pre-processing) 결과 단위.
///
/// Whisper가 출력한 파편화된 [SubtitleSegment]들을 완결된 문장 단위로 묶고,
/// 원본 세그먼트 인덱스 매핑 정보를 함께 보관합니다.
class MergedSubtitleSentence {
  final String mergedText;
  final List<int> segmentIndices;

  const MergedSubtitleSentence({
    required this.mergedText,
    required this.segmentIndices,
  });

  int get startIndex => segmentIndices.first;
  int get endIndex => segmentIndices.last;
}

/// 무료 하이브리드 실시간 자막 엔진 (API Key / 토큰 소모 없음).
///
/// 1. FFmpeg(Input Seeking)로 30~60초 오디오 청크를 16kHz Mono PCM WAV로 추출
/// 2. 로컬 `whisper.cpp` 백그라운드 Isolate(tiny / base / small / large-v3-turbo-q5)로 STT 전사
/// 3. 파편화된 세그먼트를 문장 부호(`. ? ! 。 ？ ！`) 및 1.5초 이상 침묵 간격 기준으로
///    완결 문장 단위로 병합(Pre-processing)한 뒤 `\n|||\n` 구분자로 결합해
///    무료 Google Web Translate(`client=gtx`)로 **청크당 1회 일괄 번역**
/// 4. 번역된 한국어 문장을 원본 세그먼트의 글자 수(또는 재생 시간) 비율에 맞춰
///    자연스럽게 재분배(Post-processing)하여 각 세그먼트 타임스탬프에 매핑
/// - HTTP 기반 번역이므로 Android, iPadOS, Windows 데스크톱 모두 동일하게 한국어 번역 지원
/// - 오프라인/번역 실패 시에도 재생을 멈추지 않고 원어 자막만 안전하게 출력
class FreeHybridSubtitleEngine implements SubtitleGeneratorEngine {
  static const Duration silenceSplitThreshold = Duration(milliseconds: 1500);
  static final RegExp _sentenceEndPattern =
      RegExp(r'[.?!。？！]["\x27”’」』\)\]]*$');
  static final RegExp _clauseBreakPattern = RegExp(r'[,，、;:\-—–]["\x27”’」』\)\]]*$');
  static final RegExp _whitespacePattern = RegExp(r'\s+');

  final AiWhisperModelTier modelTier;
  final AudioChunkExtractor _extractor;
  final WhisperIsolateWorker _whisperWorker;
  final GoogleWebBatchTranslator _batchTranslator;

  int _chunkSeq = 0;
  bool _isCancelled = false;
  CancelToken? _activeCancelToken;
  String? _lastTranslationError;

  FreeHybridSubtitleEngine({
    this.modelTier = AiWhisperModelTier.base,
    AudioChunkExtractor? extractor,
    WhisperIsolateWorker? whisperWorker,
    GoogleWebBatchTranslator? batchTranslator,
  })  : _extractor = extractor ?? AudioChunkExtractor.create(),
        _whisperWorker = whisperWorker ?? WhisperIsolateWorker(),
        _batchTranslator = batchTranslator ?? GoogleWebBatchTranslator();

  @override
  String get engineId => 'free_hybrid_whisper_${modelTier.code}';

  @override
  String get displayName => '온라인 무료 (${modelTier.shortName} + 구글 번역)';

  @override
  String get acceleratorLabel =>
      '${_whisperWorker.acceleratorLabel} + Google 번역';

  /// 마지막 무료 웹 번역 실패 메시지(정상 동작 시 `null`).
  String? get lastTranslationError => _lastTranslationError;

  @override
  Future<bool> isSupported() async {
    final whisperOk = await _whisperWorker.isAvailable();
    final ffmpegOk = await _extractor.isAvailable();
    return whisperOk && ffmpegOk;
  }

  @override
  Future<void> initialize({
    void Function(double progress, String status)? onProgress,
  }) async {
    _lastTranslationError = null;
    await _whisperWorker.initialize(
      tier: modelTier,
      onProgress: onProgress,
    );
  }

  @override
  Stream<SubtitleSegment> generateSubtitlesForChunk(
    AudioChunkRequest request,
  ) async* {
    _isCancelled = false;
    final seq = ++_chunkSeq;

    // 1. 오디오 청크 추출 + 로컬 Whisper.cpp 추론
    final rawSegments = await extractAndTranscribeChunkWithWhisper(
      extractor: _extractor,
      whisperWorker: _whisperWorker,
      request: request,
      chunkSequence: seq,
      isCancelled: () => _isCancelled,
      tempFolderName: 'ai_sub_free_hybrid_chunks',
    );

    if (_isCancelled || rawSegments.isEmpty) return;

    // 이미 목표 언어(한국어)로 고정 요청된 경우 번역 생략
    if (request.sourceLanguage != 'auto' &&
        request.sourceLanguage.toLowerCase() ==
            request.targetLanguage.toLowerCase()) {
      _lastTranslationError = null;
      for (final seg in rawSegments) {
        if (_isCancelled) return;
        yield seg;
      }
      return;
    }

    // 2. 번역 전 문장 병합 (Pre-processing): 완결된 문장 단위로 병합 + 원본 인덱스 매핑 유지
    final mergedSentences = mergeSegmentsIntoSentences(rawSegments);
    if (mergedSentences.isEmpty) {
      _lastTranslationError = null;
      for (final seg in rawSegments) {
        if (_isCancelled) return;
        yield seg;
      }
      return;
    }

    // 3. 병합된 완결 문장들을 `\n|||\n`로 묶어 청크당 1회 무료 배치 번역
    final cancelToken = CancelToken();
    _activeCancelToken = cancelToken;
    BatchTranslationResult? batchResult;
    try {
      batchResult = await _batchTranslator.translateBatch(
        mergedSentences.map((m) => m.mergedText).toList(growable: false),
        sourceLang: request.sourceLanguage,
        targetLang: request.targetLanguage,
        cancelToken: cancelToken,
      );
    } catch (e) {
      debugPrint('[FreeHybridSubtitleEngine] 배치 번역 예외(원어 폴백): $e');
      batchResult = null;
    } finally {
      if (identical(_activeCancelToken, cancelToken)) {
        _activeCancelToken = null;
      }
    }

    if (_isCancelled) return;

    if (batchResult == null) {
      // 오프라인/번역 실패 시 재생 중단 없이 원어 자막만 안전 출력
      _lastTranslationError =
          _batchTranslator.lastErrorMessage ?? '무료 번역 요청에 실패했습니다.';
      for (final seg in rawSegments) {
        if (_isCancelled) return;
        yield seg;
      }
      return;
    }

    // 4. 번역 결과 후처리 (Post-processing): 글자 수(또는 재생 시간) 비율에 맞춰 타임스탬프 재분배
    _lastTranslationError = null;
    final translatedSegments = applyMergedTranslations(
      rawSegments: rawSegments,
      mergedSentences: mergedSentences,
      translatedSentences: batchResult.translations,
      detectedLanguage: batchResult.detectedSourceLanguage,
    );
    for (final seg in translatedSegments) {
      if (_isCancelled) return;
      yield seg;
    }
  }

  /// Whisper가 출력한 파편화된 [segments]를 문장 끝 부호(`. ? ! 。 ？ ！`) 또는
  /// 1.5초 이상의 화자/침묵 간격 기준으로 완결된 문장 단위로 병합합니다.
  @visibleForTesting
  static List<MergedSubtitleSentence> mergeSegmentsIntoSentences(
    List<SubtitleSegment> segments,
  ) {
    if (segments.isEmpty) return const [];

    final merged = <MergedSubtitleSentence>[];
    final currentTexts = <String>[];
    final currentIndices = <int>[];

    void flushCurrent() {
      if (currentIndices.isEmpty) return;
      merged.add(
        MergedSubtitleSentence(
          mergedText: currentTexts.join(' '),
          segmentIndices: List<int>.unmodifiable(currentIndices),
        ),
      );
      currentTexts.clear();
      currentIndices.clear();
    }

    for (var i = 0; i < segments.length; i++) {
      final seg = segments[i];
      final normalized =
          seg.originalText.trim().replaceAll(_whitespacePattern, ' ');
      if (normalized.isEmpty) {
        flushCurrent();
        continue;
      }

      if (currentIndices.isNotEmpty) {
        final prevSeg = segments[currentIndices.last];
        final silenceGap = seg.startTime - prevSeg.endTime;
        if (silenceGap >= silenceSplitThreshold) {
          flushCurrent();
        }
      }

      currentTexts.add(normalized);
      currentIndices.add(i);

      if (_sentenceEndPattern.hasMatch(normalized)) {
        flushCurrent();
      }
    }

    flushCurrent();
    return merged;
  }

  /// 배치 번역된 문장들을 원본 세그먼트 인덱스 매핑에 따라 재분할해 채워 넣습니다.
  @visibleForTesting
  static List<SubtitleSegment> applyMergedTranslations({
    required List<SubtitleSegment> rawSegments,
    required List<MergedSubtitleSentence> mergedSentences,
    required List<String?> translatedSentences,
    String? detectedLanguage,
  }) {
    final result = List<SubtitleSegment>.generate(
      rawSegments.length,
      (i) => rawSegments[i].copyWith(
        languageCode: rawSegments[i].languageCode ?? detectedLanguage,
      ),
      growable: false,
    );

    for (var mIdx = 0; mIdx < mergedSentences.length; mIdx++) {
      if (mIdx >= translatedSentences.length) break;
      final translated = translatedSentences[mIdx]?.trim();
      if (translated == null || translated.isEmpty) continue;

      final group = mergedSentences[mIdx];
      final groupSegments = group.segmentIndices
          .map((idx) => rawSegments[idx])
          .toList(growable: false);
      final distributed = distributeTranslatedSentence(
        translatedText: translated,
        segments: groupSegments,
      );

      for (var j = 0; j < group.segmentIndices.length; j++) {
        final rawIdx = group.segmentIndices[j];
        final piece = j < distributed.length ? distributed[j]?.trim() : null;
        if (piece != null && piece.isNotEmpty) {
          result[rawIdx] = result[rawIdx].copyWith(translatedText: piece);
        }
      }
    }

    return result;
  }

  /// 번역된 완결 문장 [translatedText]를 병합되었던 [segments]들의
  /// 글자 수 비율(원문 글자 수 0일 때는 재생 시간 비율)에 맞춰 자연스럽게 분할합니다.
  @visibleForTesting
  static List<String?> distributeTranslatedSentence({
    required String translatedText,
    required List<SubtitleSegment> segments,
  }) {
    if (segments.isEmpty) return const [];
    final trimmed = translatedText.trim().replaceAll(_whitespacePattern, ' ');
    if (trimmed.isEmpty) {
      return List<String?>.filled(segments.length, null);
    }
    if (segments.length == 1) {
      return [trimmed];
    }

    final weights = _computeSegmentWeights(segments);
    final words =
        trimmed.split(' ').where((w) => w.isNotEmpty).toList(growable: false);

    if (words.length >= segments.length) {
      return _splitWordsByWeights(words: words, weights: weights);
    }
    return _splitRunesByWeights(
      text: trimmed,
      segmentCount: segments.length,
      weights: weights,
    );
  }

  static List<double> _computeSegmentWeights(List<SubtitleSegment> segments) {
    final charWeights = segments
        .map((s) => s.originalText.trim().runes.length.toDouble())
        .toList(growable: false);
    if (charWeights.every((w) => w > 0)) {
      return charWeights;
    }
    return segments
        .map(
          (s) => (s.endTime - s.startTime)
              .inMilliseconds
              .clamp(1, 1 << 30)
              .toDouble(),
        )
        .toList(growable: false);
  }

  static List<String?> _splitWordsByWeights({
    required List<String> words,
    required List<double> weights,
  }) {
    final k = weights.length;
    final m = words.length;
    final totalWeight = weights.fold<double>(0, (a, b) => a + b);

    // cumLen[p] = words.sublist(0, p).join(' ').runes.length
    final cumLen = List<int>.filled(m + 1, 0);
    for (var i = 0; i < m; i++) {
      final wLen = words[i].runes.length;
      cumLen[i + 1] = i == 0 ? wLen : cumLen[i] + 1 + wLen;
    }

    final totalSlicesLen = (cumLen[m] - (k - 1)).clamp(1, 1 << 30);

    int sliceLength(int a, int b) {
      return cumLen[b] - (a == 0 ? 0 : cumLen[a] + 1);
    }

    double segmentCost(int segIdx, int a, int b) {
      final targetRatio = weights[segIdx] / totalWeight;
      final actualRatio = sliceLength(a, b) / totalSlicesLen;
      final diff = actualRatio - targetRatio;
      var cost = diff * diff;
      // 쉼표/구두점 직후 분절에 소폭 가산점을 주어 어절 경계를 자연스럽게 유지
      if (segIdx < k - 1 && _clauseBreakPattern.hasMatch(words[b - 1])) {
        cost -= 0.002;
      }
      return cost;
    }

    // 매우 긴 문장에 대한 선형 시간 폴백
    if (m > 250) {
      return _splitWordsGreedy(
        words: words,
        weights: weights,
        totalWeight: totalWeight,
        cumLen: cumLen,
        totalSlicesLen: totalSlicesLen,
      );
    }

    const inf = 1e18;
    final dp = List.generate(k + 1, (_) => List<double>.filled(m + 1, inf));
    final choice = List.generate(k + 1, (_) => List<int>.filled(m + 1, 0));

    for (var p = 1; p <= m - (k - 1); p++) {
      dp[1][p] = segmentCost(0, 0, p);
      choice[1][p] = 0;
    }

    for (var segCount = 2; segCount <= k; segCount++) {
      final segIdx = segCount - 1;
      final minEnd = segCount;
      final maxEnd = segCount == k ? m : m - (k - segCount);
      final startEnd = segCount == k ? m : minEnd;

      for (var p = startEnd; p <= maxEnd; p++) {
        var bestCost = inf;
        var bestPrev = segCount - 1;
        for (var prev = segCount - 1; prev < p; prev++) {
          final prevCost = dp[segCount - 1][prev];
          if (prevCost >= inf) continue;
          final cand = prevCost + segmentCost(segIdx, prev, p);
          if (cand < bestCost) {
            bestCost = cand;
            bestPrev = prev;
          }
        }
        dp[segCount][p] = bestCost;
        choice[segCount][p] = bestPrev;
      }
    }

    final boundaries = List<int>.filled(k + 1, 0);
    var cur = m;
    for (var segCount = k; segCount >= 1; segCount--) {
      boundaries[segCount] = cur;
      cur = choice[segCount][cur];
    }

    return List<String?>.generate(k, (i) {
      return words.sublist(boundaries[i], boundaries[i + 1]).join(' ');
    }, growable: false);
  }

  static List<String?> _splitWordsGreedy({
    required List<String> words,
    required List<double> weights,
    required double totalWeight,
    required List<int> cumLen,
    required int totalSlicesLen,
  }) {
    final k = weights.length;
    final m = words.length;
    final result = List<String?>.filled(k, null);
    var start = 0;
    var cumWeight = 0.0;

    for (var i = 0; i < k - 1; i++) {
      cumWeight += weights[i];
      final targetLen = (cumWeight / totalWeight) * (totalSlicesLen + (k - 1));
      final maxEnd = m - (k - 1 - i);
      var bestEnd = start + 1;
      var bestDiff = double.infinity;

      for (var end = start + 1; end <= maxEnd; end++) {
        final diff = (cumLen[end] - targetLen).abs();
        if (diff < bestDiff) {
          bestDiff = diff;
          bestEnd = end;
        }
      }
      result[i] = words.sublist(start, bestEnd).join(' ');
      start = bestEnd;
    }

    result[k - 1] = words.sublist(start).join(' ');
    return result;
  }

  static List<String?> _splitRunesByWeights({
    required String text,
    required int segmentCount,
    required List<double> weights,
  }) {
    final runes = text.runes.toList(growable: false);
    final totalNonSpace = runes.where((r) => r != 0x20).length;
    if (totalNonSpace < segmentCount) {
      return List<String?>.generate(
        segmentCount,
        (i) => i == 0 ? text : null,
        growable: false,
      );
    }

    // 각 세그먼트에 최소 1개 이상의 비공백 문자가 배정되도록 룬 단위 분할
    final prefixNonSpace = List<int>.filled(runes.length + 1, 0);
    for (var i = 0; i < runes.length; i++) {
      prefixNonSpace[i + 1] =
          prefixNonSpace[i] + (runes[i] == 0x20 ? 0 : 1);
    }

    final totalWeight = weights.fold<double>(0, (a, b) => a + b);
    final result = List<String?>.filled(segmentCount, null);
    var start = 0;
    var cumWeight = 0.0;

    for (var i = 0; i < segmentCount - 1; i++) {
      while (start < runes.length && runes[start] == 0x20) {
        start++;
      }
      cumWeight += weights[i];
      final targetNonSpace =
          (cumWeight / totalWeight) * totalNonSpace;
      final remainingSegments = segmentCount - 1 - i;

      var bestEnd = start + 1;
      var bestDiff = double.infinity;
      for (var end = start + 1; end <= runes.length; end++) {
        final sliceNonSpace = prefixNonSpace[end] - prefixNonSpace[start];
        if (sliceNonSpace < 1) continue;
        final remainingNonSpace = totalNonSpace - prefixNonSpace[end];
        if (remainingNonSpace < remainingSegments) break;

        final diff = (prefixNonSpace[end] - targetNonSpace).abs();
        if (diff < bestDiff) {
          bestDiff = diff;
          bestEnd = end;
        }
      }

      final slice = String.fromCharCodes(runes.sublist(start, bestEnd)).trim();
      result[i] = slice.isEmpty ? null : slice;
      start = bestEnd;
    }

    while (start < runes.length && runes[start] == 0x20) {
      start++;
    }
    final tail = String.fromCharCodes(runes.sublist(start)).trim();
    result[segmentCount - 1] = tail.isEmpty ? null : tail;
    return result;
  }

  @override
  Future<void> cancelCurrentJob() async {
    _isCancelled = true;
    try {
      _activeCancelToken?.cancel('Cancelled by user/seek');
    } catch (_) {}
    await _extractor.cancel();
  }

  @override
  Future<void> dispose() async {
    _isCancelled = true;
    try {
      _activeCancelToken?.cancel('Engine disposed');
    } catch (_) {}
    await _extractor.dispose();
    _batchTranslator.dispose();
    await _whisperWorker.release();
  }
}
