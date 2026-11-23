import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Gemini API Key 로컬 보안 저장소 (`flutter_secure_storage` 기반).
///
/// - 코드 내 API Key 하드코딩을 금지하고, 사용자가 설정 UI에서 직접 입력한 키만
///   OS 보안 키체인/자격증명 저장소(Android Keystore / iOS Keychain / Windows Credential Manager)에 보관합니다.
class AiSubtitleKeyStorage {
  static const String _geminiApiKeyStorageKey = 'ai_subtitle_gemini_api_key';

  static final AiSubtitleKeyStorage instance = AiSubtitleKeyStorage();

  final FlutterSecureStorage _secureStorage;
  String? _cachedKey;
  bool _hasLoaded = false;

  AiSubtitleKeyStorage({FlutterSecureStorage? secureStorage})
      : _secureStorage = secureStorage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(resetOnError: true),
            );

  /// 테스트용 메모리 기반 저장소 생성자.
  AiSubtitleKeyStorage.inMemory({String? initialKey})
      : _secureStorage = const FlutterSecureStorage(),
        _cachedKey = initialKey,
        _hasLoaded = true;

  bool get isLoaded => _hasLoaded;
  String? get cachedApiKey => _cachedKey;
  bool get hasCachedApiKey =>
      _cachedKey != null && _cachedKey!.trim().isNotEmpty;

  Future<String?> loadApiKey({bool forceRefresh = false}) async {
    if (_hasLoaded && !forceRefresh) return _cachedKey;
    try {
      final raw = await _secureStorage.read(key: _geminiApiKeyStorageKey);
      final cleaned = raw?.trim();
      _cachedKey = (cleaned != null && cleaned.isNotEmpty) ? cleaned : null;
    } on MissingPluginException {
      // 단위 테스트/비플랫폼 환경에서는 메모리 캐시만 유지
    } catch (e) {
      debugPrint('[AiSubtitleKeyStorage] 보안 저장소 조회 실패: $e');
    }
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
    try {
      await _secureStorage.write(
        key: _geminiApiKeyStorageKey,
        value: cleaned,
      );
    } on MissingPluginException {
      // 단위 테스트 환경 허용
    } catch (e) {
      debugPrint('[AiSubtitleKeyStorage] 보안 저장소 저장 실패: $e');
      rethrow;
    }
  }

  Future<void> deleteApiKey() async {
    _cachedKey = null;
    _hasLoaded = true;
    try {
      await _secureStorage.delete(key: _geminiApiKeyStorageKey);
    } on MissingPluginException {
      // 단위 테스트 환경 허용
    } catch (e) {
      debugPrint('[AiSubtitleKeyStorage] 보안 저장소 삭제 실패: $e');
    }
  }

  /// UI 표시/로그 안전성을 위한 마스킹 문자열 반환.
  static String? maskApiKey(String? key) {
    final cleaned = key?.trim();
    if (cleaned == null || cleaned.isEmpty) return null;
    if (cleaned.length <= 8) return '••••••••';
    return '${cleaned.substring(0, 4)}••••${cleaned.substring(cleaned.length - 4)}';
  }
}
