import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// AI 자막·번역 API Key 로컬 보안 저장소 (`flutter_secure_storage` 기반).
///
/// - 코드 내 API Key 하드코딩을 금지하고, 사용자가 설정 UI에서 직접 입력한 키만
///   OS 보안 키체인/자격증명 저장소(Android Keystore / iOS Keychain / Windows Credential Manager)에 보관합니다.
class AiSubtitleKeyStorage {
  static const String _geminiApiKeyStorageKey = 'ai_subtitle_gemini_api_key';
  static const String _gcpTranslationApiKeyStorageKey =
      'ai_subtitle_gcp_translation_api_key';

  static final AiSubtitleKeyStorage instance = AiSubtitleKeyStorage();

  final FlutterSecureStorage _secureStorage;
  final bool _inMemoryOnly;
  String? _cachedKey;
  bool _hasLoaded = false;
  String? _cachedGcpTranslationKey;
  bool _hasLoadedGcpTranslation = false;

  AiSubtitleKeyStorage({FlutterSecureStorage? secureStorage})
      : _secureStorage = secureStorage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(resetOnError: true),
            ),
        _inMemoryOnly = false;

  /// 테스트용 메모리 기반 저장소 생성자.
  AiSubtitleKeyStorage.inMemory({
    String? initialKey,
    String? initialGcpTranslationKey,
  })  : _secureStorage = const FlutterSecureStorage(),
        _inMemoryOnly = true,
        _cachedKey = _cleanKey(initialKey),
        _hasLoaded = true,
        _cachedGcpTranslationKey = _cleanKey(initialGcpTranslationKey),
        _hasLoadedGcpTranslation = true;

  bool get isLoaded => _hasLoaded;
  String? get cachedApiKey => _cachedKey;
  bool get hasCachedApiKey =>
      _cachedKey != null && _cachedKey!.trim().isNotEmpty;

  bool get isGcpTranslationKeyLoaded => _hasLoadedGcpTranslation;
  String? get cachedGcpTranslationApiKey => _cachedGcpTranslationKey;
  bool get hasCachedGcpTranslationApiKey =>
      _cachedGcpTranslationKey != null &&
      _cachedGcpTranslationKey!.trim().isNotEmpty;

  Future<String?> loadApiKey({bool forceRefresh = false}) async {
    if (_hasLoaded && !forceRefresh) return _cachedKey;
    _cachedKey = await _readKey(_geminiApiKeyStorageKey, _cachedKey);
    _hasLoaded = true;
    return _cachedKey;
  }

  Future<void> saveApiKey(String apiKey) async {
    final cleaned = apiKey.trim();
    if (cleaned.isEmpty) {
      await deleteApiKey();
      return;
    }
    _cachedKey = cleaned;
    _hasLoaded = true;
    await _writeKey(_geminiApiKeyStorageKey, cleaned);
  }

  Future<void> deleteApiKey() async {
    _cachedKey = null;
    _hasLoaded = true;
    await _deleteKey(_geminiApiKeyStorageKey);
  }

  Future<String?> loadGcpTranslationApiKey({bool forceRefresh = false}) async {
    if (_hasLoadedGcpTranslation && !forceRefresh) {
      return _cachedGcpTranslationKey;
    }
    _cachedGcpTranslationKey = await _readKey(
      _gcpTranslationApiKeyStorageKey,
      _cachedGcpTranslationKey,
    );
    _hasLoadedGcpTranslation = true;
    return _cachedGcpTranslationKey;
  }

  Future<void> saveGcpTranslationApiKey(String apiKey) async {
    final cleaned = apiKey.trim();
    if (cleaned.isEmpty) {
      await deleteGcpTranslationApiKey();
      return;
    }
    _cachedGcpTranslationKey = cleaned;
    _hasLoadedGcpTranslation = true;
    await _writeKey(_gcpTranslationApiKeyStorageKey, cleaned);
  }

  Future<void> deleteGcpTranslationApiKey() async {
    _cachedGcpTranslationKey = null;
    _hasLoadedGcpTranslation = true;
    await _deleteKey(_gcpTranslationApiKeyStorageKey);
  }

  Future<String?> _readKey(String storageKey, String? fallbackValue) async {
    if (_inMemoryOnly) return fallbackValue;
    try {
      final raw = await _secureStorage.read(key: storageKey);
      return _cleanKey(raw);
    } on MissingPluginException {
      // 단위 테스트/비플랫폼 환경에서는 메모리 캐시만 유지
      return fallbackValue;
    } catch (e) {
      debugPrint('[AiSubtitleKeyStorage] 보안 저장소 조회 실패($storageKey): $e');
      return fallbackValue;
    }
  }

  Future<void> _writeKey(String storageKey, String value) async {
    if (_inMemoryOnly) return;
    try {
      await _secureStorage.write(key: storageKey, value: value);
    } on MissingPluginException {
      // 단위 테스트 환경 허용
    } catch (e) {
      debugPrint('[AiSubtitleKeyStorage] 보안 저장소 저장 실패($storageKey): $e');
      rethrow;
    }
  }

  Future<void> _deleteKey(String storageKey) async {
    if (_inMemoryOnly) return;
    try {
      await _secureStorage.delete(key: storageKey);
    } on MissingPluginException {
      // 단위 테스트 환경 허용
    } catch (e) {
      debugPrint('[AiSubtitleKeyStorage] 보안 저장소 삭제 실패($storageKey): $e');
    }
  }

  static String? _cleanKey(String? raw) {
    final cleaned = raw?.trim();
    return (cleaned != null && cleaned.isNotEmpty) ? cleaned : null;
  }

  /// UI 표시/로그 안전성을 위한 마스킹 문자열 반환.
  static String? maskApiKey(String? key) {
    final cleaned = key?.trim();
    if (cleaned == null || cleaned.isEmpty) return null;
    if (cleaned.length <= 8) return '••••••••';
    return '${cleaned.substring(0, 4)}••••${cleaned.substring(cleaned.length - 4)}';
  }
}
