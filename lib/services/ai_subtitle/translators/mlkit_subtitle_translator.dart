import 'package:flutter/foundation.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';
import 'subtitle_translator.dart';

/// Android / iPadOS(iOS) 전용 Google ML Kit 온디바이스 번역기.
///
/// Windows 타깃에서는 `subtitle_translator_io_factory.dart` 분기에 의해
/// 인스턴스화 및 네이티브 MethodChannel 호출이 완전히 차단됩니다.
class MlKitSubtitleTranslator implements SubtitleTranslator {
  MlKitSubtitleTranslator({
    OnDeviceTranslatorModelManager? modelManager,
    OnDeviceTranslator Function(
      TranslateLanguage sourceLanguage,
      TranslateLanguage targetLanguage,
    )? translatorFactory,
  })  : _modelManager = modelManager ?? OnDeviceTranslatorModelManager(),
        _translatorFactory = translatorFactory ??
            ((src, tgt) => OnDeviceTranslator(
                  sourceLanguage: src,
                  targetLanguage: tgt,
                ));

  final OnDeviceTranslatorModelManager _modelManager;
  final OnDeviceTranslator Function(
    TranslateLanguage sourceLanguage,
    TranslateLanguage targetLanguage,
  ) _translatorFactory;
  final Map<String, OnDeviceTranslator> _translators = {};
  final Set<String> _ensuredModels = {};
  final Map<String, Future<void>> _pendingDownloads = {};

  String _configuredSource = 'auto';
  String _targetLang = 'ko';
  String? _lastErrorMessage;

  static final RegExp _hangulRegex = RegExp(r'[\uAC00-\uD7AF\u1100-\u11FF]');
  static final RegExp _japaneseKanaRegex =
      RegExp(r'[\u3040-\u309F\u30A0-\u30FF\uFF65-\uFF9F\u3005\u30FC]');
  static final RegExp _cjkIdeographRegex = RegExp(r'[\u4E00-\u9FFF]');
  static final RegExp _cyrillicRegex = RegExp(r'[\u0400-\u04FF]');

  @override
  bool get isTranslationSupported => true;

  @override
  String get translatorName => 'Google ML Kit On-Device';

  @override
  String? get lastErrorMessage => _lastErrorMessage;

  @override
  Future<void> initialize({
    required String sourceLang,
    String targetLang = 'ko',
    void Function(double progress, String status)? onProgress,
  }) async {
    _targetLang = _normalizeLangCode(targetLang);
    if (_targetLang == 'auto') _targetLang = 'ko';
    _configuredSource = _normalizeLangCode(sourceLang);
    _lastErrorMessage = null;

    try {
      onProgress?.call(0.92, '온디바이스 번역 모델($_targetLang) 확인 중...');
      await _ensureModelDownloaded(_targetLang);
      // 'auto' 모드에서는 영어로 강제 고정하지 않고 실제 전사 문자셋에 맞춰 동적으로 모델을 준비합니다.
      if (_configuredSource != 'auto' && _configuredSource != _targetLang) {
        onProgress?.call(0.96, '온디바이스 번역 모델($_configuredSource) 확인 중...');
        await _ensureModelDownloaded(_configuredSource);
      }
      onProgress?.call(1.0, '온디바이스 번역 준비 완료');
    } catch (e) {
      _lastErrorMessage = '온디바이스 번역 모델 준비 실패: $e';
      debugPrint('[MlKitSubtitleTranslator] 모델 사전 확인 중 경고: $e');
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

    final key = '${srcCode}_$_targetLang';
    try {
      await _ensureModelDownloaded(srcCode);
      await _ensureModelDownloaded(_targetLang);

      final translator = _translators.putIfAbsent(
        key,
        () => _translatorFactory(srcEnum, tgtEnum),
      );
      final translated = await translator.translateText(trimmed);
      final cleaned = translated.trim();
      if (cleaned.isEmpty) return null;
      _lastErrorMessage = null;
      return cleaned;
    } catch (e) {
      _lastErrorMessage = '온디바이스 번역 실패($srcCode→$_targetLang): $e';
      // 실패한 모델/인스턴스 캐시를 비워 다음 청크에서 재시도 가능하도록 유지
      _ensuredModels.remove(srcCode);
      _ensuredModels.remove(_targetLang);
      final broken = _translators.remove(key);
      if (broken != null) {
        try {
          await broken.close();
        } catch (_) {}
      }
      debugPrint('[MlKitSubtitleTranslator] 번역 실패(원어 유지, $srcCode→$_targetLang): $e');
      return null;
    }
  }

  String _resolveSourceLangCode(String text, String? hint) {
    final normalizedHint = hint == null ? '' : _normalizeLangCode(hint);
    if (normalizedHint.isNotEmpty &&
        normalizedHint != 'auto' &&
        BCP47Code.fromRawValue(normalizedHint) != null) {
      return normalizedHint;
    }
    if (_configuredSource.isNotEmpty &&
        _configuredSource != 'auto' &&
        BCP47Code.fromRawValue(_configuredSource) != null) {
      return _configuredSource;
    }
    return detectScriptLanguage(text);
  }

  static String _normalizeLangCode(String code) {
    final trimmed = code.trim().toLowerCase();
    if (trimmed.isEmpty || trimmed == 'auto') return 'auto';
    final dashIdx = trimmed.indexOf('-');
    if (dashIdx > 0) {
      return trimmed.substring(0, dashIdx);
    }
    return trimmed;
  }

  /// Whisper `auto` 모드에서 텍스트 문자셋 기반의 초경량 언어 추론.
  static String detectScriptLanguage(
    String text, {
    String? preferredCjkLang,
  }) {
    if (_hangulRegex.hasMatch(text)) return 'ko';
    if (_japaneseKanaRegex.hasMatch(text)) return 'ja';
    if (_cjkIdeographRegex.hasMatch(text)) {
      if (preferredCjkLang == 'ja' || preferredCjkLang == 'zh') {
        return preferredCjkLang!;
      }
      return 'zh';
    }
    if (_cyrillicRegex.hasMatch(text)) return 'ru';
    return 'en';
  }

  /// 텍스트에 일본어 가나(히라가나/가타카나)가 포함되어 있는지 검사합니다.
  static bool containsJapaneseKana(String text) =>
      _japaneseKanaRegex.hasMatch(text);

  /// 텍스트에 한자(CJK 통합 한자)가 포함되어 있는지 검사합니다.
  static bool containsCjkIdeograph(String text) =>
      _cjkIdeographRegex.hasMatch(text);

  Future<void> _ensureModelDownloaded(String bcpCode) async {
    if (_ensuredModels.contains(bcpCode)) return;
    final pending = _pendingDownloads[bcpCode];
    if (pending != null) {
      await pending;
      return;
    }

    final future = () async {
      final downloaded = await _modelManager.isModelDownloaded(bcpCode);
      if (!downloaded) {
        final ok = await _modelManager.downloadModel(
          bcpCode,
          isWifiRequired: false,
        );
        if (!ok) {
          throw StateError('ML Kit 언어 모델($bcpCode) 다운로드가 완료되지 않았습니다.');
        }
      }
      _ensuredModels.add(bcpCode);
    }();

    _pendingDownloads[bcpCode] = future;
    try {
      await future;
    } finally {
      _pendingDownloads.remove(bcpCode);
    }
  }

  @override
  Future<void> dispose() async {
    final instances = _translators.values.toList();
    _translators.clear();
    _ensuredModels.clear();
    _pendingDownloads.clear();
    _lastErrorMessage = null;
    for (final t in instances) {
      try {
        await t.close();
      } catch (_) {}
    }
  }
}
