import 'package:flutter/foundation.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';
import 'subtitle_translator.dart';

/// Android / iPadOS(iOS) 전용 Google ML Kit 온디바이스 번역기.
///
/// Windows 타깃에서는 `subtitle_translator_io_factory.dart` 분기에 의해
/// 인스턴스화 및 네이티브 MethodChannel 호출이 완전히 차단됩니다.
class MlKitSubtitleTranslator implements SubtitleTranslator {
  final OnDeviceTranslatorModelManager _modelManager =
      OnDeviceTranslatorModelManager();
  final Map<String, OnDeviceTranslator> _translators = {};
  final Set<String> _ensuredModels = {};

  String _configuredSource = 'en';
  String _targetLang = 'ko';

  @override
  bool get isTranslationSupported => true;

  @override
  String get translatorName => 'Google ML Kit On-Device';

  @override
  Future<void> initialize({
    required String sourceLang,
    String targetLang = 'ko',
  }) async {
    _targetLang = targetLang;
    _configuredSource = sourceLang == 'auto' ? 'en' : sourceLang;

    try {
      await _ensureModelDownloaded(_targetLang);
      if (_configuredSource != _targetLang) {
        await _ensureModelDownloaded(_configuredSource);
      }
    } catch (e) {
      debugPrint('[MlKitSubtitleTranslator] 모델 사전 확인 중 경고(무시): $e');
    }
  }

  @override
  Future<String?> translate(
    String originalText, {
    String? detectedSourceLang,
  }) async {
    final trimmed = originalText.trim();
    if (trimmed.isEmpty) return null;

    final srcCode = _resolveSourceLangCode(trimmed, detectedSourceLang);
    if (srcCode == _targetLang) return null;

    final srcEnum = BCP47Code.fromRawValue(srcCode);
    final tgtEnum = BCP47Code.fromRawValue(_targetLang);
    if (srcEnum == null || tgtEnum == null) return null;

    try {
      await _ensureModelDownloaded(srcCode);
      await _ensureModelDownloaded(_targetLang);

      final key = '${srcCode}_$_targetLang';
      final translator = _translators.putIfAbsent(
        key,
        () => OnDeviceTranslator(
          sourceLanguage: srcEnum,
          targetLanguage: tgtEnum,
        ),
      );
      final translated = await translator.translateText(trimmed);
      if (translated.trim().isEmpty) return null;
      return translated.trim();
    } catch (e) {
      debugPrint('[MlKitSubtitleTranslator] 번역 실패(원어 유지): $e');
      return null;
    }
  }

  String _resolveSourceLangCode(String text, String? hint) {
    if (hint != null && hint.isNotEmpty && hint != 'auto') {
      return hint;
    }
    if (_configuredSource.isNotEmpty && _configuredSource != 'auto') {
      return _configuredSource;
    }
    return detectScriptLanguage(text);
  }

  /// Whisper `auto` 모드에서 텍스트 문자셋 기반의 초경량 언어 추론.
  static String detectScriptLanguage(String text) {
    if (RegExp(r'[\uAC00-\uD7AF\u1100-\u11FF]').hasMatch(text)) return 'ko';
    if (RegExp(r'[\u3040-\u309F\u30A0-\u30FF]').hasMatch(text)) return 'ja';
    if (RegExp(r'[\u4E00-\u9FFF]').hasMatch(text)) return 'zh';
    if (RegExp(r'[\u0400-\u04FF]').hasMatch(text)) return 'ru';
    return 'en';
  }

  Future<void> _ensureModelDownloaded(String bcpCode) async {
    if (_ensuredModels.contains(bcpCode)) return;
    final downloaded = await _modelManager.isModelDownloaded(bcpCode);
    if (!downloaded) {
      await _modelManager.downloadModel(bcpCode, isWifiRequired: false);
    }
    _ensuredModels.add(bcpCode);
  }

  @override
  Future<void> dispose() async {
    final instances = _translators.values.toList();
    _translators.clear();
    _ensuredModels.clear();
    for (final t in instances) {
      try {
        await t.close();
      } catch (_) {}
    }
  }
}
