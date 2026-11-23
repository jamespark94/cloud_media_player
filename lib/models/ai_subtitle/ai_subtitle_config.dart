/// AI 자막 생성 엔진 종류 (Strategy 선택용).
enum AiSubtitleEngineType {
  onDevice('on_device', '로컬 온디바이스 (무료/오프라인)'),
  cloudApi('cloud_api', '클라우드 AI (고품질/API Key 필요)');

  final String code;
  final String label;

  const AiSubtitleEngineType(this.code, this.label);

  static AiSubtitleEngineType fromCode(String? code) {
    for (final v in values) {
      if (v.code == code || v.name == code) return v;
    }
    return AiSubtitleEngineType.onDevice;
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

/// 온디바이스 Whisper 경량 모델 티어.
enum AiWhisperModelTier {
  tiny('tiny', 'Tiny (~75MB, 가장 빠름)'),
  base('base', 'Base (~142MB, 균형)');

  final String code;
  final String label;

  const AiWhisperModelTier(this.code, this.label);

  static AiWhisperModelTier fromCode(String? code) {
    for (final v in values) {
      if (v.code == code) return v;
    }
    return AiWhisperModelTier.tiny;
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
  static const int defaultCloudChunkSeconds = 45;

  final AiSubtitleEngineType engineType;
  final AiWhisperModelTier modelTier;
  final String sourceLanguage;
  final String targetLanguage;
  final int chunkSeconds;
  final int lookaheadChunks;
  final AiSubtitleDisplayMode displayMode;
  final String cloudModelName;

  const AiSubtitleConfig({
    this.engineType = AiSubtitleEngineType.onDevice,
    this.modelTier = AiWhisperModelTier.tiny,
    this.sourceLanguage = 'auto',
    this.targetLanguage = 'ko',
    this.chunkSeconds = defaultOnDeviceChunkSeconds,
    this.lookaheadChunks = 2,
    this.displayMode = AiSubtitleDisplayMode.dual,
    this.cloudModelName = 'gemini-3.8-flash',
  });

  bool get showDualSubtitle => displayMode == AiSubtitleDisplayMode.dual;

  int get effectiveChunkSeconds => engineType == AiSubtitleEngineType.cloudApi
      ? (chunkSeconds >= 30 && chunkSeconds <= 60
          ? chunkSeconds
          : defaultCloudChunkSeconds)
      : chunkSeconds;

  int get effectiveLookaheadChunks =>
      engineType == AiSubtitleEngineType.cloudApi ? 1 : lookaheadChunks;

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
              ? (nextEngine == AiSubtitleEngineType.cloudApi
                  ? defaultCloudChunkSeconds
                  : defaultOnDeviceChunkSeconds)
              : this.chunkSeconds),
      lookaheadChunks: lookaheadChunks ??
          (engineType != null && engineType != this.engineType
              ? (nextEngine == AiSubtitleEngineType.cloudApi ? 1 : 2)
              : this.lookaheadChunks),
      displayMode: nextDisplayMode,
      cloudModelName: cloudModelName ?? this.cloudModelName,
    );
  }
}
