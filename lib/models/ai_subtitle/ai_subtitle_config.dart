/// AI 자막 생성 엔진 종류 (Strategy 선택용).
enum AiSubtitleEngineType {
  onDevice('on_device', '로컬 오프라인 (완전 무료 / ML Kit)'),
  freeHybrid('free_hybrid', '온라인 무료 (무제한 / 로컬 Whisper + 구글 번역)'),
  cloudApi('cloud_api', '클라우드 AI (최고 품질 / Gemini 멀티모달 토큰 소모)');

  final String code;
  final String label;

  const AiSubtitleEngineType(this.code, this.label);

  static AiSubtitleEngineType fromCode(String? code) {
    for (final v in values) {
      if (v.code == code || v.name == code) return v;
    }
    return AiSubtitleEngineType.freeHybrid;
  }
}

/// AI 자막 오버레이 표시 모드.
enum AiSubtitleDisplayMode {
  dual('dual', '원어 + 한국어 동시 표시'),
  koreanOnly('korean_only', '한국어만 표시'),
  originalOnly('original_only', '원어만 표시');

  final String code;
  final String label;

  const AiSubtitleDisplayMode(this.code, this.label);

  static AiSubtitleDisplayMode fromCode(String? code) {
    for (final v in values) {
      if (v.code == code || v.name == code) return v;
    }
    return AiSubtitleDisplayMode.dual;
  }
}

/// 로컬 Whisper.cpp 모델 크기 티어.
enum AiWhisperModelTier {
  tiny('tiny', 'Tiny (~75MB, 가장 빠름 · 저사양 CPU용)', 'ggml-tiny.bin', 'Tiny (~75MB)', '~75MB'),
  base('base', 'Base (~142MB, 빠름)', 'ggml-base.bin', 'Base (~142MB)', '~142MB'),
  smallQ5_1(
    'small-q5_1',
    'Small Q5_1 (~190MB, 빠른 고효율 · 실시간 추천)',
    'ggml-small-q5_1.bin',
    'Small Q5_1',
    '~190MB',
  ),
  small('small', 'Small (~466MB, 실시간 기본 추천 · 균형)', 'ggml-small.bin', 'Small (~466MB)', '~466MB'),
  largeV3TurboQ5(
    'large-v3-turbo-q5_0',
    'Large v3 Turbo Q5 (~547MB, 최고 인식률 · 고성능 GPU 권장)',
    'ggml-large-v3-turbo-q5_0.bin',
    'Large v3 Turbo Q5',
    '~547MB',
  );

  final String code;
  final String label;
  final String modelFileName;
  final String shortName;
  final String approxSize;

  const AiWhisperModelTier(
    this.code,
    this.label,
    this.modelFileName,
    this.shortName,
    this.approxSize,
  );

  static AiWhisperModelTier fromCode(String? code) {
    for (final v in values) {
      if (v.code == code || v.name == code) return v;
    }
    if (code == 'large-v3-turbo') {
      return AiWhisperModelTier.largeV3TurboQ5;
    }
    return AiWhisperModelTier.small;
  }
}

/// AI 음성 인식 원본 언어 프리셋.
class AiSourceLanguageOption {
  final String code;
  final String label;

  const AiSourceLanguageOption(this.code, this.label);

  static const List<AiSourceLanguageOption> presets = [
    AiSourceLanguageOption('auto', '자동 감지'),
    AiSourceLanguageOption('en', '영어 (English)'),
    AiSourceLanguageOption('es', '스페인어 (Español)'),
    AiSourceLanguageOption('ja', '일본어 (日本語)'),
    AiSourceLanguageOption('zh', '중국어 (中文)'),
    AiSourceLanguageOption('ko', '한국어 (한국어)'),
    AiSourceLanguageOption('fr', '프랑스어 (Français)'),
    AiSourceLanguageOption('de', '독일어 (Deutsch)'),
  ];

  static String labelOf(String code) {
    for (final opt in presets) {
      if (opt.code == code) return opt.label;
    }
    return code;
  }
}

/// AI 실시간 자막 파이프라인 동작 설정.
class AiSubtitleConfig {
  static const int defaultOnDeviceChunkSeconds = 20;
  static const int defaultFreeHybridChunkSeconds = 45;
  static const int defaultCloudChunkSeconds = 45;

  /// 첫 자막 대기 시간 단축을 위한 초기 짧은 청크 길이(10~15초).
  static const int initialShortChunkSeconds = 12;

  /// 선행 버퍼링용 후속 스트리밍 청크 길이(30초).
  static const int streamingChunkSeconds = 30;

  /// 지나간 Stale 청크 폐기 후 새로 추출할 미래 구간 선행 오프셋(10~30초).
  static const int staleSkipLeadSeconds = 15;

  final AiSubtitleEngineType engineType;
  final AiWhisperModelTier modelTier;
  final String sourceLanguage;
  final String targetLanguage;
  final int chunkSeconds;
  final int lookaheadChunks;
  final AiSubtitleDisplayMode displayMode;
  final String cloudModelName;

  const AiSubtitleConfig({
    this.engineType = AiSubtitleEngineType.freeHybrid,
    this.modelTier = AiWhisperModelTier.small,
    this.sourceLanguage = 'auto',
    this.targetLanguage = 'ko',
    this.chunkSeconds = defaultFreeHybridChunkSeconds,
    this.lookaheadChunks = 1,
    this.displayMode = AiSubtitleDisplayMode.dual,
    this.cloudModelName = 'gemini-3.8-flash',
  });

  bool get showDualSubtitle => displayMode == AiSubtitleDisplayMode.dual;

  int get effectiveChunkSeconds {
    switch (engineType) {
      case AiSubtitleEngineType.cloudApi:
        return chunkSeconds >= 30 && chunkSeconds <= 60
            ? chunkSeconds
            : defaultCloudChunkSeconds;
      case AiSubtitleEngineType.freeHybrid:
        return chunkSeconds >= 30 && chunkSeconds <= 60
            ? chunkSeconds
            : defaultFreeHybridChunkSeconds;
      case AiSubtitleEngineType.onDevice:
        return chunkSeconds > 0 && chunkSeconds <= 30
            ? chunkSeconds
            : defaultOnDeviceChunkSeconds;
    }
  }

  int get effectiveLookaheadChunks {
    switch (engineType) {
      case AiSubtitleEngineType.cloudApi:
      case AiSubtitleEngineType.freeHybrid:
        return 1;
      case AiSubtitleEngineType.onDevice:
        return lookaheadChunks;
    }
  }

  static int defaultChunkSecondsFor(AiSubtitleEngineType type) {
    switch (type) {
      case AiSubtitleEngineType.onDevice:
        return defaultOnDeviceChunkSeconds;
      case AiSubtitleEngineType.freeHybrid:
        return defaultFreeHybridChunkSeconds;
      case AiSubtitleEngineType.cloudApi:
        return defaultCloudChunkSeconds;
    }
  }

  static int defaultLookaheadFor(AiSubtitleEngineType type) {
    switch (type) {
      case AiSubtitleEngineType.onDevice:
        return 2;
      case AiSubtitleEngineType.freeHybrid:
      case AiSubtitleEngineType.cloudApi:
        return 1;
    }
  }

  AiSubtitleConfig copyWith({
    AiSubtitleEngineType? engineType,
    AiWhisperModelTier? modelTier,
    String? sourceLanguage,
    String? targetLanguage,
    int? chunkSeconds,
    int? lookaheadChunks,
    AiSubtitleDisplayMode? displayMode,
    bool? showDualSubtitle,
    String? cloudModelName,
  }) {
    final nextEngine = engineType ?? this.engineType;
    final nextDisplayMode = displayMode ??
        (showDualSubtitle == null
            ? this.displayMode
            : (showDualSubtitle
                ? AiSubtitleDisplayMode.dual
                : AiSubtitleDisplayMode.koreanOnly));

    return AiSubtitleConfig(
      engineType: nextEngine,
      modelTier: modelTier ?? this.modelTier,
      sourceLanguage: sourceLanguage ?? this.sourceLanguage,
      targetLanguage: targetLanguage ?? this.targetLanguage,
      chunkSeconds: chunkSeconds ??
          (engineType != null && engineType != this.engineType
              ? defaultChunkSecondsFor(nextEngine)
              : this.chunkSeconds),
      lookaheadChunks: lookaheadChunks ??
          (engineType != null && engineType != this.engineType
              ? defaultLookaheadFor(nextEngine)
              : this.lookaheadChunks),
      displayMode: nextDisplayMode,
      cloudModelName: cloudModelName ?? this.cloudModelName,
    );
  }
}
