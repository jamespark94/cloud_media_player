import 'fallback_subtitle_translator.dart';
import 'subtitle_translator.dart';

/// 비-IO 환경(예: Web/테스트 스텁)용 안전 팩토리.
SubtitleTranslator createPlatformSubtitleTranslator() {
  return FallbackSubtitleTranslator();
}
