import 'package:flutter/foundation.dart';
import '../ai_subtitle_key_storage.dart';
import 'gcp_cloud_batch_translator.dart';
import 'google_web_batch_translator.dart';
import 'subtitle_translator.dart';

/// GCP Cloud Translation API v2 우선 번역기 + 자동 폴백 래퍼.
///
/// - 저장된 GCP Cloud Translation API 키가 있으면 `GcpCloudBatchTranslator`를 사용해
///   `<span translate="no">|||</span>` 구분자 기반 3,500자 배치 POST 번역을 수행합니다.
/// - API 키가 미입력이거나 403/429 에러가 발생하면 즉시 기존 온디바이스 ML Kit
///   (모바일) 또는 `FallbackSubtitleTranslator`(데스크톱)로 자동 전환됩니다.
class GcpCloudSubtitleTranslator implements SubtitleTranslator {
  final Future<String?> Function() _apiKeyProvider;
  final bool Function()? _hasApiKeySync;
  final GcpCloudBatchTranslator _gcpTranslator;
  final SubtitleTranslator _fallbackTranslator;
  final void Function(String reason)? onFallback;

  String _sourceLang = 'auto';
  String _targetLang = 'ko';
  bool _fallbackInitialized = false;
  bool _isInFallbackMode = false;
  String? _disabledApiKey;
  String? _lastErrorMessage;
  String? _lastDetectedSourceLanguage;

  GcpCloudSubtitleTranslator({
    Future<String?> Function()? apiKeyProvider,
    bool Function()? hasApiKeySync,
    GcpCloudBatchTranslator? gcpTranslator,
    SubtitleTranslator? fallbackTranslator,
    this.onFallback,
  })  : _apiKeyProvider = apiKeyProvider ??
            (() => AiSubtitleKeyStorage.instance.loadGcpTranslationApiKey()),
        _hasApiKeySync = hasApiKeySync ??
            (() => AiSubtitleKeyStorage.instance.hasCachedGcpTranslationApiKey),
        _gcpTranslator = gcpTranslator ?? GcpCloudBatchTranslator(),
        _fallbackTranslator = fallbackTranslator ?? SubtitleTranslator.create();

  bool get isUsingFallback => _isInFallbackMode;
  String? get lastDetectedSourceLanguage => _lastDetectedSourceLanguage;

  @override
  bool get isTranslationSupported {
    if (_fallbackTranslator.isTranslationSupported) return true;
    if (!_isInFallbackMode && (_hasApiKeySync?.call() ?? false)) return true;
    return false;
  }

  @override
  String get translatorName => _isInFallbackMode || !(_hasApiKeySync?.call() ?? false)
      ? _fallbackTranslator.translatorName
      : 'GCP Cloud Translation v2';

  @override
  String? get lastErrorMessage =>
      _lastErrorMessage ?? _fallbackTranslator.lastErrorMessage;

  @override
  Future<void> initialize({
    required String sourceLang,
    String targetLang = 'ko',
    void Function(double progress, String status)? onProgress,
  }) async {
    _sourceLang = sourceLang;
    final cleanedTarget = targetLang.trim();
    _targetLang = (cleanedTarget.isEmpty || cleanedTarget == 'auto')
        ? 'ko'
        : cleanedTarget;
    _lastErrorMessage = null;
    _lastDetectedSourceLanguage = null;

    final apiKey = await _resolveActiveApiKey();
    if (apiKey == null) {
      _isInFallbackMode = true;
      await _ensureFallbackInitialized(onProgress: onProgress);
    } else {
      _isInFallbackMode = false;
      onProgress?.call(1.0, 'GCP Cloud Translation 준비 완료');
    }
  }

  @override
  Future<String?> translate(
    String originalText, {
    String? detectedSourceLang,
  }) async {
    final results = await translateBatch(
      <String>[originalText],
      detectedSourceLang: detectedSourceLang,
    );
    return results.isEmpty ? null : results.first;
  }

  @override
  Future<List<String?>> translateBatch(
    List<String> texts, {
    String? detectedSourceLang,
    List<String?>? detectedSourceLangs,
  }) async {
    if (texts.isEmpty) return const [];

    final res = await translateBatchDetailed(
      texts,
      detectedSourceLang: detectedSourceLang,
      detectedSourceLangs: detectedSourceLangs,
    );
    return res.translations;
  }

  /// 배치 번역 결과와 감지된 원본 언어를 함께 반환합니다.
  Future<BatchTranslationResult> translateBatchDetailed(
    List<String> texts, {
    String? detectedSourceLang,
    List<String?>? detectedSourceLangs,
  }) async {
    if (texts.isEmpty) {
      return const BatchTranslationResult(translations: []);
    }

    final apiKey = await _resolveActiveApiKey();
    if (apiKey == null) {
      _isInFallbackMode = true;
      return _translateWithFallback(
        texts,
        detectedSourceLang: detectedSourceLang,
        detectedSourceLangs: detectedSourceLangs,
      );
    }

    try {
      final result = await _gcpTranslator.translateBatch(
        texts,
        apiKey: apiKey,
        targetLang: _targetLang,
      );
      _isInFallbackMode = false;
      _lastErrorMessage = null;
      _lastDetectedSourceLanguage = result.detectedSourceLanguage;
      return result;
    } on GcpTranslationException catch (e) {
      _lastErrorMessage = e.message;
      if (e.isFallbackStatus) {
        _disabledApiKey = apiKey;
        _isInFallbackMode = true;
        final reason =
            'GCP Cloud Translation API 오류(HTTP ${e.statusCode})로 기본 번역기(${_fallbackTranslator.translatorName})로 자동 전환합니다.';
        debugPrint('[GcpCloudSubtitleTranslator] $reason');
        onFallback?.call(reason);
      } else {
        debugPrint('[GcpCloudSubtitleTranslator] GCP 번역 실패(폴백 시도): ${e.message}');
      }
      return _translateWithFallback(
        texts,
        detectedSourceLang: detectedSourceLang,
        detectedSourceLangs: detectedSourceLangs,
      );
    } catch (e) {
      _lastErrorMessage = 'GCP 번역 오류: $e';
      debugPrint('[GcpCloudSubtitleTranslator] 예외(폴백 시도): $e');
      return _translateWithFallback(
        texts,
        detectedSourceLang: detectedSourceLang,
        detectedSourceLangs: detectedSourceLangs,
      );
    }
  }

  Future<String?> _resolveActiveApiKey() async {
    final raw = (await _apiKeyProvider())?.trim();
    if (raw == null || raw.isEmpty) return null;
    if (_disabledApiKey != null && _disabledApiKey == raw) return null;
    // 새 키가 입력된 경우 이전 비활성화 상태 해제
    if (_disabledApiKey != null && _disabledApiKey != raw) {
      _disabledApiKey = null;
    }
    return raw;
  }

  Future<void> _ensureFallbackInitialized({
    void Function(double progress, String status)? onProgress,
  }) async {
    if (_fallbackInitialized) return;
    await _fallbackTranslator.initialize(
      sourceLang: _sourceLang,
      targetLang: _targetLang,
      onProgress: onProgress,
    );
    _fallbackInitialized = true;
  }

  Future<BatchTranslationResult> _translateWithFallback(
    List<String> texts, {
    String? detectedSourceLang,
    List<String?>? detectedSourceLangs,
  }) async {
    await _ensureFallbackInitialized();
    final translations = await _fallbackTranslator.translateBatch(
      texts,
      detectedSourceLang: detectedSourceLang,
      detectedSourceLangs: detectedSourceLangs,
    );
    return BatchTranslationResult(translations: translations);
  }

  @override
  Future<void> dispose() async {
    _fallbackInitialized = false;
    _disabledApiKey = null;
    _lastErrorMessage = null;
    _lastDetectedSourceLanguage = null;
    _gcpTranslator.dispose();
    await _fallbackTranslator.dispose();
  }
}
