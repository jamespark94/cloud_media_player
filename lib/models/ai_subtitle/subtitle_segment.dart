import 'ai_subtitle_config.dart';

/// AI 실시간 자막 생성 및 번역 시스템의 공통 자막 세그먼트 모델.
///
/// Phase 1(로컬 Whisper + ML Kit)과 Phase 2(클라우드 AI 멀티모달) 엔진이
/// 동일한 출력 규격을 공유하여 UI 레이어와 캐시 계층을 완전히 분리합니다.
class SubtitleSegment {
  final Duration startTime;
  final Duration endTime;
  final String originalText;
  final String? translatedText;
  final String? languageCode;

  const SubtitleSegment({
    required this.startTime,
    required this.endTime,
    required this.originalText,
    this.translatedText,
    this.languageCode,
  });

  /// 재생 위치 [pos]가 현재 세그먼트 시간 범위에 포함되는지 검사합니다.
  bool contains(Duration pos) => pos >= startTime && pos <= endTime;

  /// 자막 오버레이 렌더링용 문자열을 생성합니다.
  /// - [displayMode]가 지정되면 3가지 모드(`dual`, `koreanOnly`, `originalOnly`)를 따릅니다.
  /// - 하위 호환을 위해 [showDual] 플래그도 유지합니다.
  String formatForDisplay({
    bool showDual = true,
    AiSubtitleDisplayMode? displayMode,
  }) {
    final orig = originalText.trim();
    final trans = (translatedText ?? '').trim();
    if (orig.isEmpty && trans.isEmpty) return '';

    final mode = displayMode ??
        (showDual
            ? AiSubtitleDisplayMode.dual
            : AiSubtitleDisplayMode.koreanOnly);

    switch (mode) {
      case AiSubtitleDisplayMode.originalOnly:
        return orig.isNotEmpty ? orig : trans;
      case AiSubtitleDisplayMode.koreanOnly:
        if (trans.isEmpty || trans == orig) return orig;
        return trans;
      case AiSubtitleDisplayMode.dual:
        if (trans.isEmpty || trans == orig) return orig;
        if (orig.isEmpty) return trans;
        return '$orig\n$trans';
    }
  }

  SubtitleSegment copyWith({
    Duration? startTime,
    Duration? endTime,
    String? originalText,
    String? translatedText,
    String? languageCode,
  }) {
    return SubtitleSegment(
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      originalText: originalText ?? this.originalText,
      translatedText: translatedText ?? this.translatedText,
      languageCode: languageCode ?? this.languageCode,
    );
  }

  Map<String, dynamic> toJson() => {
        'startMs': startTime.inMilliseconds,
        'endMs': endTime.inMilliseconds,
        'originalText': originalText,
        if (translatedText != null) 'translatedText': translatedText,
        if (languageCode != null) 'languageCode': languageCode,
      };

  factory SubtitleSegment.fromJson(Map<String, dynamic> json) {
    return SubtitleSegment(
      startTime: Duration(milliseconds: (json['startMs'] as num).toInt()),
      endTime: Duration(milliseconds: (json['endMs'] as num).toInt()),
      originalText: (json['originalText'] as String?) ?? '',
      translatedText: json['translatedText'] as String?,
      languageCode: json['languageCode'] as String?,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is SubtitleSegment &&
        other.startTime == startTime &&
        other.endTime == endTime &&
        other.originalText == originalText &&
        other.translatedText == translatedText &&
        other.languageCode == languageCode;
  }

  @override
  int get hashCode =>
      Object.hash(startTime, endTime, originalText, translatedText, languageCode);
}
