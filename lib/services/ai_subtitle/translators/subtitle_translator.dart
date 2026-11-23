import 'subtitle_translator_stub.dart'
    if (dart.library.io) 'subtitle_translator_io_factory.dart';

/// 온디바이스 자막 번역기 추상 인터페이스.
///
/// Conditional Import를 통해 Android / iPadOS 타깃에서만 `google_mlkit_translation`이
/// 로드되며, Windows 데스크톱 환경에서는 의존성 충돌 없이 안전한 원어 유지(No-Op) 모드로 동작합니다.
abstract class SubtitleTranslator {
  /// 현재 실행 플랫폼에서 로컬 번역이 지원되는지 여부.
  bool get isTranslationSupported;

  /// 플랫폼별 번역기 설명 문자열.
  String get translatorName;

  /// 마지막 번역/모델 다운로드 오류 메시지(정상 시 `null`).
  String? get lastErrorMessage => null;

  /// 원본 언어 -> 목표 언어 번역 모델 초기화.
  Future<void> initialize({
    required String sourceLang,
    String targetLang = 'ko',
    void Function(double progress, String status)? onProgress,
  });

  /// 원어 텍스트를 한국어로 번역합니다.
  /// 미지원 플랫폼(Windows) 또는 번역 실패 시 `null`을 반환해 원어 자막만 안전하게 표시합니다.
  Future<String?> translate(
    String originalText, {
    String? detectedSourceLang,
  });

  /// 모델 및 네이티브 리소스 해제.
  Future<void> dispose();

  /// 플랫폼 안전 팩토리.
  factory SubtitleTranslator.create() => createPlatformSubtitleTranslator();
}
