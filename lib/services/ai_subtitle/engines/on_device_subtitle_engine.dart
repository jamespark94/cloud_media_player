import 'dart:async';
import 'dart:io';
import '../../../models/ai_subtitle/ai_subtitle_config.dart';
import '../../../models/ai_subtitle/subtitle_segment.dart';
import '../extractors/audio_chunk_extractor.dart';
import '../extractors/desktop_ffmpeg_extractor.dart';
import '../stt/whisper_chunk_runner.dart';
import '../stt/whisper_isolate_worker.dart';
import '../subtitle_generator_engine.dart';
import '../translators/gcp_cloud_subtitle_translator.dart';
import '../translators/mlkit_subtitle_translator.dart';
import '../translators/subtitle_translator.dart';

/// 온디바이스 경량 + 선택적 GCP Cloud Translation 자막 생성 엔진.
///
/// 1. FFmpeg(Input Seeking)로 16kHz Mono PCM WAV 청크 추출
/// 2. Whisper.cpp FFI (백그라운드 Isolate)로 원어 STT + 타임스탬프 추출
/// 3. GCP Cloud Translation API 키가 설정된 경우 배치 POST 번역 우선 수행,
///    미입력 또는 403/429 오류 시 플랫폼별 로컬 번역기(Android/iPadOS: ML Kit, Windows: 원어 단독)로 자동 전환
class OnDeviceSubtitleEngine implements SubtitleGeneratorEngine {
  final AudioChunkExtractor _extractor;
  final AudioChunkExtractor _preExtractor;
  final WhisperIsolateWorker _whisperWorker;
  final SubtitleTranslator _translator;
  final AiWhisperModelTier modelTier;

  int _chunkSeq = 0;
  bool _isCancelled = false;
  String? _sessionPreferredCjkLang;

  OnDeviceSubtitleEngine({
    this.modelTier = AiWhisperModelTier.tiny,
    AudioChunkExtractor? extractor,
    AudioChunkExtractor? preExtractor,
    WhisperIsolateWorker? whisperWorker,
    SubtitleTranslator? translator,
  })  : _extractor = extractor ?? AudioChunkExtractor.create(),
        _preExtractor = preExtractor ?? extractor ?? AudioChunkExtractor.create(),
        _whisperWorker = whisperWorker ?? WhisperIsolateWorker(),
        _translator = translator ?? GcpCloudSubtitleTranslator();

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

  /// 현재 환경에서 엔진을 사용할 수 없는 구체적 사유를 반환합니다.
  Future<String?> getUnsupportedReason() async {
    final whisperReason = await _whisperWorker.getUnavailableReason();
    String? extractorReason;
    if (!await _extractor.isAvailable()) {
      final extractor = _extractor;
      if (extractor is DesktopFfmpegExtractor) {
        extractorReason = await extractor.getUnavailableReason();
      } else {
        extractorReason = '오디오 청크 추출 모듈을 사용할 수 없습니다.';
      }
    }
    if (whisperReason != null && extractorReason != null) {
      return '$extractorReason $whisperReason';
    }
    return whisperReason ?? extractorReason;
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
    final seq = ++_chunkSeq;

    // 1. 오디오 청크 추출 + Whisper.cpp FFI 백그라운드 추론
    final rawSegments = await extractAndTranscribeChunkWithWhisper(
      extractor: _extractor,
      whisperWorker: _whisperWorker,
      request: request,
      chunkSequence: seq,
      isCancelled: () => _isCancelled,
      tempFolderName: 'ai_sub_chunks',
    );

    if (_isCancelled || rawSegments.isEmpty) return;

    // `auto` 모드에서 청크 내 일본어 가나가 감지되면 한자 단독 세그먼트("大丈夫" 등)도 일본어로 해석
    if (request.sourceLanguage == 'auto') {
      final hasKana = rawSegments.any(
        (s) => MlKitSubtitleTranslator.containsJapaneseKana(s.originalText),
      );
      if (hasKana) {
        _sessionPreferredCjkLang = 'ja';
      }
    }

    // 2. 일괄 번역 (GCP Cloud Translation 우선, 미입력/403/429 시 ML Kit 또는 기본 폴백 자동 전환)
    List<String?> translations = List<String?>.filled(rawSegments.length, null);
    if (_translator.isTranslationSupported) {
      final hints = rawSegments
          .map(
            (seg) => _resolveTranslationHint(
              requestSourceLanguage: request.sourceLanguage,
              segment: seg,
            ),
          )
          .toList(growable: false);
      translations = await _translator.translateBatch(
        rawSegments.map((s) => s.originalText).toList(growable: false),
        detectedSourceLangs: hints,
      );
    }

    final detectedGcpLang = _translator is GcpCloudSubtitleTranslator
        ? _translator.lastDetectedSourceLanguage
        : null;

    for (var i = 0; i < rawSegments.length; i++) {
      if (_isCancelled) return;
      final seg = rawSegments[i];
      yield seg.copyWith(
        translatedText: i < translations.length ? translations[i] : null,
        languageCode: seg.languageCode ?? detectedGcpLang,
      );
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

  /// 다음 구간의 오디오 청크(16kHz Mono PCM WAV)를 백그라운드에서 미리 추출합니다.
  Future<File> preExtractAudioChunk({
    required String streamUrl,
    required Map<String, String> httpHeaders,
    required Duration start,
    required Duration duration,
    required String outputWavPath,
  }) {
    return _preExtractor.extractChunk(
      streamUrl: streamUrl,
      httpHeaders: httpHeaders,
      start: start,
      duration: duration,
      outputWavPath: outputWavPath,
    );
  }

  Future<void> cancelPreExtraction() => _preExtractor.cancel();

  @override
  Future<void> cancelCurrentJob() async {
    _isCancelled = true;
    await _extractor.cancel();
    await _preExtractor.cancel();
    await _whisperWorker.cancel();
  }

  @override
  Future<void> dispose() async {
    _isCancelled = true;
    await _extractor.dispose();
    await _preExtractor.dispose();
    await _translator.dispose();
    await _whisperWorker.release();
  }
}
