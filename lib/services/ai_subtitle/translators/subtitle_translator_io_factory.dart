import 'dart:io';
import 'fallback_subtitle_translator.dart';
import 'mlkit_subtitle_translator.dart';
import 'subtitle_translator.dart';

/// dart:io 플랫폼 분기 팩토리:
/// - Android / iPadOS(iOS): Google ML Kit 온디바이스 번역기
/// - Windows / 기타 데스크톱: ML Kit 로드 없이 원어 자막(Passthrough) 폴백
SubtitleTranslator createPlatformSubtitleTranslator() {
  if (Platform.isAndroid || Platform.isIOS) {
    return MlKitSubtitleTranslator();
  }
  return FallbackSubtitleTranslator();
}
