import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';

/// Google OAuth 및 Google Drive 전용 인증 매니저 (Singleton)
class GoogleAuthManager {
  static final GoogleAuthManager _instance = GoogleAuthManager._internal();
  factory GoogleAuthManager() => _instance;
  GoogleAuthManager._internal();

  /// Google Drive 읽기 전용 스코프
  static const String driveReadonlyScope =
      'https://www.googleapis.com/auth/drive.readonly';

  /// Google Drive 앱 생성 파일(재생기록/독서기록 동기화 JSON) 읽기/쓰기 스코프
  static const String driveFileScope =
      'https://www.googleapis.com/auth/drive.file';

  static const List<String> requiredScopes = <String>[
    driveReadonlyScope,
    driveFileScope,
  ];

  final GoogleSignIn _googleSignIn = GoogleSignIn(
    scopes: requiredScopes,
  );

  GoogleSignInAccount? _currentUser;
  GoogleSignInAccount? get currentUser => _currentUser;
  bool get isAuthenticated => _currentUser != null;

  final StreamController<GoogleSignInAccount?> _userStreamController =
      StreamController<GoogleSignInAccount?>.broadcast();
  Stream<GoogleSignInAccount?> get onAuthStateChanged =>
      _userStreamController.stream;

  bool _isInitialized = false;

  /// 앱 시작 시 이전 로그인 세션 무음 복구 (Non-blocking)
  Future<bool> initialize() async {
    if (_isInitialized && _currentUser != null) return true;

    _googleSignIn.onCurrentUserChanged.listen((GoogleSignInAccount? account) {
      _currentUser = account;
      _userStreamController.add(account);
    });

    try {
      // 이전에 로그인한 이력이 있는 경우 무음 로그인 시도
      _currentUser = await _googleSignIn.signInSilently();
      _isInitialized = true;
      return _currentUser != null;
    } catch (e) {
      debugPrint('[GoogleAuthManager] signInSilently error: $e');
      _isInitialized = true;
      return false;
    }
  }

  /// 대화형 로그인 (네이티브 바텀시트 / 계정 선택기)
  Future<GoogleSignInAccount?> signIn() async {
    try {
      // 기존 캐시 충돌 방지를 위해 필요 시 세션 정리 후 로그인
      final account = await _googleSignIn.signIn();
      if (account == null) {
        debugPrint('[GoogleAuthManager] User cancelled sign in.');
        return null;
      }

      // 필수 스코프 부여 여부 검증 및 요청
      try {
        final hasScope = await _googleSignIn.canAccessScopes(requiredScopes);
        if (!hasScope) {
          final granted = await _googleSignIn.requestScopes(requiredScopes);
          if (!granted) {
            debugPrint('[GoogleAuthManager] Scope $requiredScopes was denied.');
            await signOut();
            throw Exception('Google Drive 접근 권한이 거부되었습니다.');
          }
        }
      } catch (scopeError) {
        // Android의 경우 signIn() 시점에 이미 scopes가 요청/승인되므로
        // canAccessScopes가 지원되지 않거나 예외가 나더라도 authHeaders 획득 가능 여부로 검증
        debugPrint('[GoogleAuthManager] Scope check note: $scopeError');
      }

      _currentUser = account;
      _userStreamController.add(account);
      return account;
    } catch (e) {
      debugPrint('[GoogleAuthManager] signIn error: $e');
      rethrow;
    }
  }

  /// 무음 재로그인 시도
  Future<GoogleSignInAccount?> signInSilently() async {
    try {
      _currentUser = await _googleSignIn.signInSilently();
      _userStreamController.add(_currentUser);
      return _currentUser;
    } catch (e) {
      debugPrint('[GoogleAuthManager] signInSilently failed: $e');
      return null;
    }
  }

  /// 최신 액세스 토큰 문자열 반환 (실패 시 null)
  Future<String?> getAccessToken() async {
    try {
      final headers = await getAuthHeaders();
      final auth = headers['Authorization'];
      if (auth != null && auth.startsWith('Bearer ')) {
        return auth.substring(7).trim();
      }
    } catch (_) {}
    return null;
  }

  /// 최신 인증 헤더 반환 (`{'Authorization': 'Bearer <token>'}`)
  Future<Map<String, String>> getAuthHeaders() async {
    // 계정 세션이 없으면 silent 복구 1회 시도
    _currentUser ??= await _googleSignIn.signInSilently();

    if (_currentUser == null) {
      throw Exception('로그인된 Google 계정이 없습니다. 다시 로그인해 주세요.');
    }

    try {
      return await _currentUser!.authHeaders;
    } catch (e) {
      debugPrint('[GoogleAuthManager] getAuthHeaders failed, trying refresh: $e');
      return await refreshAuthHeaders();
    }
  }

  /// 401 Unauthorized 또는 토큰 만료 시 캐시 무효화 및 강제 토큰 갱신
  Future<Map<String, String>> refreshAuthHeaders() async {
    try {
      if (_currentUser != null) {
        // Play Services의 만료된 로컬 토큰 캐시 파기
        await _currentUser!.clearAuthCache();
      }

      // 새 토큰 획득을 위한 silent 로그인
      _currentUser = await _googleSignIn.signInSilently(suppressErrors: false);
      if (_currentUser == null) {
        throw Exception('세션이 만료되었습니다. 다시 로그인해 주세요.');
      }

      return await _currentUser!.authHeaders;
    } catch (e) {
      debugPrint('[GoogleAuthManager] refreshAuthHeaders failed: $e');
      rethrow;
    }
  }

  /// 로그아웃
  Future<void> signOut() async {
    try {
      await _googleSignIn.signOut();
    } catch (e) {
      debugPrint('[GoogleAuthManager] signOut error: $e');
    } finally {
      _currentUser = null;
      _userStreamController.add(null);
    }
  }

  /// 연결 해제 (앱 권한 취소)
  Future<void> disconnect() async {
    try {
      await _googleSignIn.disconnect();
    } catch (e) {
      debugPrint('[GoogleAuthManager] disconnect error: $e');
    } finally {
      _currentUser = null;
      _userStreamController.add(null);
    }
  }

  void dispose() {
    _userStreamController.close();
  }
}
