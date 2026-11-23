import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../../../models/ai_subtitle/ai_subtitle_config.dart';
import '../../../models/ai_subtitle/subtitle_segment.dart';
import '../extractors/audio_chunk_extractor.dart';
import '../stt/whisper_isolate_worker.dart';
import '../subtitle_generator_engine.dart';
import '../translators/mlkit_subtitle_translator.dart';
import '../translators/subtitle_translator.dart';

/// Phase 1 온디바이스 경량 MVP 자막 생성 엔진.
///
/// 1. FFmpeg(Input Seeking)로 16kHz Mono PCM WAV 청크 추출
/// 2. Whisper.cpp FFI (백그라운드 Isolate)로 원어 STT + 타임스탬프 추출
/// 3. 플랫폼 분기 번역기 (Android/iPadOS: ML Kit 한국어 번역, Windows: 원어 단독 출력)
class OnDeviceSubtitleEngine implements SubtitleGeneratorEngine {
  final AudioChunkExtractor _extractor;
  final WhisperIsolateWorker _whisperWorker;
  final SubtitleTranslator _translator;
  final AiWhisperModelTier modelTier;

  int _chunkSeq = 0;
  bool _isCancelled = false;
  String? _sessionPreferredCjkLang;

  OnDeviceSubtitleEngine({
    this.modelTier = AiWhisperModelTier.tiny,
    AudioChunkExtractor? extractor,
    WhisperIsolateWorker? whisperWorker,
    SubtitleTranslator? translator,
  })  : _extractor = extractor ?? AudioChunkExtractor.create(),
        _whisperWorker = whisperWorker ?? WhisperIsolateWorker(),
        _translator = translator ?? SubtitleTranslator.create();

  @override
  String get engineId => 'on_device_whisper_${modelTier.code}';

  @override
  String get displayName => '온디바이스 AI (${modelTier.code.toUpperCase()})';

  @override
  String get acceleratorLabel => _whisperWorker.acceleratorLabel;

  bool get isTranslationSupported => _translator.isTranslationSupported;

  String? get lastTranslationError => _translator.lastErrorMessage;

  @override
  Future<bool> isSupported() async {
    final whisperOk = await _whisperWorker.isAvailable();
    final ffmpegOk = await _extractor.isAvailable();
    return whisperOk && ffmpegOk;
  }

  @override
  Future<void> initialize({
    void Function(double progress, String status)? onProgress,
    String sourceLanguage = 'auto',
    String targetLanguage = 'ko',
  }) async {
    _sessionPreferredCjkLang = null;
    await _whisperWorker.initialize(
      tier: modelTier,
      onProgress: onProgress,
    );
    await _translator.initialize(
      sourceLang: sourceLanguage,
      targetLang: targetLanguage,
      onProgress: onProgress,
    );
  }

  /// Whisper 모델 재로딩 없이 번역기 언어 설정만 갱신합니다.
  Future<void> updateLanguages({
    required String sourceLanguage,
    String targetLanguage = 'ko',
  }) async {
    _sessionPreferredCjkLang = null;
    await _translator.initialize(
      sourceLang: sourceLanguage,
      targetLang: targetLanguage,
    );
  }

  @override
  Stream<SubtitleSegment> generateSubtitlesForChunk(
    AudioChunkRequest request,
  ) async* {
    _isCancelled = false;
    final tempDir = Directory('${Directory.systemTemp.path}/ai_sub_chunks');
    if (!tempDir.existsSync()) {
      tempDir.createSync(recursive: true);
    }

    final seq = ++_chunkSeq;
    final wavPath =
        '${tempDir.path}/chunk_${request.chunkStart.inMilliseconds}_$seq.wav';
    final wavFile = File(wavPath);

    try {
      // 1. 오디오 청크 추출 (16kHz, Mono, WAV)
      await _extractor.extractChunk(
        streamUrl: request.streamUrl,
        httpHeaders: request.httpHeaders,
        start: request.chunkStart,
        duration: request.chunkDuration,
        outputWavPath: wavPath,
      );

      if (_isCancelled) return;

      // 2. Whisper.cpp FFI 백그라운드 추론
      final rawSegments = await _whisperWorker.transcribeChunk(
        wavPath: wavPath,
        chunkOffset: request.chunkStart,
        chunkDuration: request.chunkDuration,
        sourceLanguage: request.sourceLanguage,
      );

      // `auto` 모드에서 청크 내 일본어 가나가 감지되면 한자 단독 세그먼트("大丈夫" 등)도 일본어로 해석
      if (request.sourceLanguage == 'auto') {
        final hasKana = rawSegments.any(
          (s) => MlKitSubtitleTranslator.containsJapaneseKana(s.originalText),
        );
        if (hasKana) {
          _sessionPreferredCjkLang = 'ja';
        }
      }

      // 3. 플랫폼별 로컬 번역 (Windows는 null 반환 -> 원어 자막 단독 유지)
      for (final seg in rawSegments) {
        if (_isCancelled) return;
        String? translated;
        if (_translator.isTranslationSupported) {
          final hint = _resolveTranslationHint(
            requestSourceLanguage: request.sourceLanguage,
            segment: seg,
          );
          translated = await _translator.translate(
            seg.originalText,
            detectedSourceLang: hint,
          );
        }
        yield seg.copyWith(translatedText: translated);
      }
    } finally {
      // 임시 WAV 파일 즉시 정리 (디스크 누적 방지)
      try {
        if (wavFile.existsSync()) await wavFile.delete();
      } catch (e) {
        debugPrint('[OnDeviceSubtitleEngine] 임시 WAV 삭제 무시: $e');
      }
    }
  }

  String _resolveTranslationHint({
    required String requestSourceLanguage,
    required SubtitleSegment segment,
  }) {
    if (requestSourceLanguage.isNotEmpty && requestSourceLanguage != 'auto') {
      return requestSourceLanguage;
    }
    final segLang = segment.languageCode;
    if (segLang != null && segLang.isNotEmpty && segLang != 'auto') {
      return segLang;
    }
    if (MlKitSubtitleTranslator.containsJapaneseKana(segment.originalText)) {
      return 'ja';
    }
    if (_sessionPreferredCjkLang != null &&
        MlKitSubtitleTranslator.containsCjkIdeograph(segment.originalText)) {
      return _sessionPreferredCjkLang!;
    }
    return 'auto';
  }

  @override
  Future<void> cancelCurrentJob() async {
    _isCancelled = true;
    await _extractor.cancel();
  }

  @override
  Future<void> dispose() async {
    _isCancelled = true;
    await _extractor.dispose();
    await _translator.dispose();
    await _whisperWorker.release();
  }
}
