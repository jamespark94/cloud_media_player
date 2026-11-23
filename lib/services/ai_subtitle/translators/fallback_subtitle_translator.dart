import 'subtitle_translator.dart';

/// Windows 데스크톱 및 미지원 플랫폼용 안전 폴백 번역기.
///
/// Phase 1에서는 `google_mlkit_translation` 의존성으로 인한 빌드 깨짐을 원천 차단하고,
/// STT가 인식한 원어 자막만 안전하게 출력합니다.
class FallbackSubtitleTranslator implements SubtitleTranslator {
  @override
  bool get isTranslationSupported => false;

  @override
  String get translatorName => 'Original Only (Windows Safe Mode)';

  @override
  String? get lastErrorMessage => null;

  @override
  Future<void> initialize({
    required String sourceLang,
    String targetLang = 'ko',
    void Function(double progress, String status)? onProgress,
  }) async {}

  @override
  Future<String?> translate(
    String originalText, {
    String? detectedSourceLang,
  }) async {
    return null;
  }

  @override
  Future<void> dispose() async {}
}
