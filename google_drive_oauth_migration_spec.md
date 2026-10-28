# Google Drive OAuth 마이그레이션 아키텍처 명세서 (Interface & Architecture Specification)

본 문서는 기존 수동 OAuth2(Client ID/Secret, WebView 리다이렉트) 기반 Google Drive 연동을 공식 `google_sign_in` 패키지(Android Native Google Play Services 기반)로 전환하기 위한 아키텍처 및 인터페이스 명세서입니다.

---

## 1. 시스템 구성 다이어그램 / 호출 흐름도 (텍스트)

### 1.1 계층형 시스템 구성도 (Layered Architecture)
```text
[UI / Player Layer]
       │ (파일 탐색, 스트리밍 URL 및 인증 헤더 요청)
       ▼
[CloudStorageProvider (Abstract Interface)]
  ├── TeraBoxProvider
  ├── BaiduNetdiskProvider
  ├── NaverMyBoxProvider
  └── GoogleDriveProvider (구현체)
       │
       ├──► [GoogleAuthService] (Single Responsibility: 인증 세션 및 헤더 관리)
       │       └── GoogleSignIn (scopes: ['.../auth/drive.readonly'])
       │
       └──► [Dio + GoogleAuthInterceptor] (HTTP 통신 및 401 자동 복구)
               └── Google Drive REST API v3 (www.googleapis.com/drive/v3)
```

### 1.2 인증 및 API 호출 흐름도 (Pipeline Flow)

```text
[1. 앱 초기화 / 자동 로그인 파이프라인]
App Start ──► GoogleDriveProvider.initialize()
                └──► GoogleAuthService.restoreSession()
                       └──► GoogleSignIn.signInSilently()
                              ├── (성공) GoogleSignInAccount 캐싱 ──► Ready 상태
                              └── (실패/계정없음) 미인증 상태 유지 (예외 발생 안 함)

[2. 사용자 대화형 로그인 파이프라인]
User Click ──► GoogleDriveProvider.connect()
                └──► GoogleAuthService.signInInteractive()
                       └──► GoogleSignIn.signIn() (네이티브 계정 선택 바텀시트)
                              ├── (사용자 취소: null 반환) ──► AuthCancelledException
                              ├── (권한 누락 시) ──► requestScopes([drive.readonly])
                              └── (성공) ──► GoogleSignInAccount 반환 및 연결 완료

[3. API 호출 및 401 Silent Refresh 파이프라인]
API 요청 (listFiles 등)
  └──► [GoogleAuthInterceptor.onRequest]
         ├── currentUser 확인 (없으면 signInSilently() 1회 시도)
         ├── currentUser.authHeaders 호출 (내부 캐시 토큰 반환)
         └── Request Header에 'Authorization: Bearer <token>' 주입 후 전송
               │
               ├── [200 OK] ──► 응답 데이터 파싱 및 반환
               └── [401 Unauthorized] ──► [GoogleAuthInterceptor.onError] 진입
                     ├── 1. 요청이 이미 재시도된 요청인지 확인 (무한 루프 방지 플래그 검사)
                     ├── 2. currentUser.clearAuthCache() 호출 (만료된 로컬 토큰 파기)
                     ├── 3. signInSilently(suppressErrors: false) 호출하여 새 토큰 발급
                     ├── 4-A. (갱신 성공) 새 authHeaders 추출 ──► 원본 RequestOptions 복제 후 재요청(dio.fetch)
                     └── 4-B. (갱신 실패) signOut() 처리 ──► AuthExpiredException 발생 (UI에서 재로그인 유도)
```

---

## 2. 안드로이드 환경 제약 조건 (Technical Constraints)

Flash 모델이 코드를 구현할 때 반드시 준수해야 할 안드로이드 네이티브 환경 제약 사항입니다.

1. **Client Secret 및 리다이렉트 URI 완전 제거**
   - 안드로이드의 `google_sign_in`은 Google Play Services SDK를 통해 OS 수준에서 인증을 위임받습니다.
   - 앱 내부에 `client_secret`이나 `redirect_uri`를 하드코딩하거나 로컬 서버/웹뷰를 띄우는 기존 코드는 **전면 폐기**해야 합니다.
2. **SHA-1 인증서 지문 및 패키지명 바인딩 원리**
   - Google Cloud Console의 **Android 타입 OAuth 2.0 클라이언트 ID**는 앱의 `applicationId`(패키지명)와 서명 키의 **SHA-1 지문** 조합으로 클라이언트의 신원을 증명합니다.
   - 따라서 **Debug 키스토어**와 **Release 키스토어**(및 Google Play App Signing)의 SHA-1이 모두 Google Cloud Console / Firebase 프로젝트에 등록되어 있어야 합니다. (`PlatformException(sign_in_failed, com.google.android.gms.common.api.ApiException: 10)` 에러의 주원인)
3. **`google-services.json` 및 Server Client ID 제약**
   - `android/app/google-services.json`이 올바르게 배치되어 있으면 안드로이드 네이티브 인증 시 별도의 `clientId` 파라미터를 Dart 코드에 전달하지 않습니다.
   - (주의) 만약 `GoogleSignIn(clientId: ...)`에 Android Client ID를 직접 넣으면 런타임 에러가 발생합니다.
4. **7일 토큰 만료 문제 해결 조건**
   - Google Play Services가 Refresh Token의 생명주기를 OS 레벨에서 관리하므로 앱이 직접 Refresh Token을 저장할 필요가 없습니다. (단, GCP OAuth 동의 화면의 게시 상태가 '테스트'인 경우 7일 제한이 걸릴 수 있으므로 프로덕션 전환 또는 테스트 사용자 등록이 전제되어야 함)

---

## 3. 핵심 클래스 및 메서드 시그니처 명세 (Dart Interfaces)

다른 클라우드 스토리지(`TeraBoxProvider`, `BaiduProvider`, `NaverMyBoxProvider`)와 동일한 인터페이스로 교체(Liskov Substitution)할 수 있도록 설계된 추상 구조입니다.

```dart
import 'package:dio/dio.dart';
import 'package:google_sign_in/google_sign_in.dart';

/// 1. 통합 클라우드 스토리지 예외 정의
enum CloudAuthErrorType {
  cancelledByUser,      // 사용자가 로그인 창을 닫음
  scopeDenied,          // 필수 권한(drive.readonly) 거부
  sessionExpired,       // Silent Refresh 실패 (재로그인 필요)
  networkOrPlayService, // 네트워크 오류 또는 SHA-1/Play Services 설정 오류 (Code 10, 7 등)
}

class CloudStorageException implements Exception {
  final String providerId;
  final String message;
  final CloudAuthErrorType? authErrorType;
  final Object? originalException;

  const CloudStorageException({
    required this.providerId,
    required this.message,
    this.authErrorType,
    this.originalException,
  });
}

/// 2. 미디어 플레이어용 파일/스트림 모델 시그니처
class CloudMediaItem {
  final String id;
  final String name;
  final bool isDirectory;
  final int? sizeBytes;
  final String? mimeType;
  final DateTime? modifiedTime;

  const CloudMediaItem({
    required this.id,
    required this.name,
    required this.isDirectory,
    this.sizeBytes,
    this.mimeType,
    this.modifiedTime,
  });
}

/// 외부 비디오/오디오 플레이어(ExoPlayer, media_kit 등)에 전달할 스트리밍 정보
class MediaStreamDescriptor {
  final Uri streamUrl;
  final Map<String, String> httpHeaders; // Authorization: Bearer <token> 포함

  const MediaStreamDescriptor({
    required this.streamUrl,
    required this.httpHeaders,
  });
}

/// 3. 모든 스토리지(테라박스, 바이두, 네이버 MYBOX, 구글 드라이브) 공통 인터페이스
abstract interface class CloudStorageProvider {
  String get providerId; // 예: 'google_drive', 'terabox', 'baidu', 'mybox'
  bool get isConnected;
  String? get connectedAccountEmail;

  /// 앱 시작 시 무음 세션 복구 시도
  Future<bool> initialize();

  /// 사용자 대화형 로그인 수행
  Future<void> connect();

  /// 로그아웃 및 연결 해제
  Future<void> disconnect();

  /// 특정 폴더 내의 파일/폴더 목록 조회 (rootId 기본값: 'root')
  Future<List<CloudMediaItem>> listFiles({
    String folderId = 'root',
    String? pageToken,
  });

  /// 미디어 플레이어가 즉시 재생할 수 있는 스트리밍 URL + 인증 헤더 반환
  Future<MediaStreamDescriptor> getStreamDescriptor(String fileId);
}

/// 4. Google 인증 전담 서비스 인터페이스
abstract interface class IGoogleAuthService {
  static const String driveReadonlyScope =
      'https://www.googleapis.com/auth/drive.readonly';

  GoogleSignInAccount? get currentUser;
  bool get isAuthenticated;

  /// 앱 실행 시 호출: signInSilently() 래핑
  Future<GoogleSignInAccount?> signInSilently();

  /// 유저 로그인 버튼 클릭 시 호출: signIn() 및 스코프 검증 래핑
  Future<GoogleSignInAccount> signInInteractive();

  /// 로그아웃
  Future<void> signOut();

  /// 현재 유효한 인증 헤더({'Authorization': 'Bearer ...'}) 반환
  Future<Map<String, String>> getAuthHeaders();

  /// 401 발생 시 캐시 무효화 후 강제 토큰 갱신
  Future<Map<String, String>> refreshAuthHeaders();
}

/// 5. Dio 인터셉터 시그니처 (authHeaders 주입 및 401 재시도)
class GoogleAuthInterceptor extends QueuedInterceptor {
  final IGoogleAuthService _authService;
  final Dio _dio;

  GoogleAuthInterceptor({
    required IGoogleAuthService authService,
    required Dio dio,
  })  : _authService = authService,
        _dio = dio;

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    // 구현 가이드: _authService.getAuthHeaders()를 호출하여 options.headers에 병합
  }

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    // 구현 가이드: 401 감지 시 _authService.refreshAuthHeaders() 호출 및 재요청
  }
}

/// 6. GoogleDriveProvider 클래스 구조
class GoogleDriveProvider implements CloudStorageProvider {
  final IGoogleAuthService _authService;
  final Dio _dio;

  GoogleDriveProvider({
    required IGoogleAuthService authService,
    required Dio dio,
  })  : _authService = authService,
        _dio = dio;

  @override
  String get providerId => 'google_drive';

  // CloudStorageProvider의 나머지 메서드 구현...
}
```

---

## 4. 토큰 갱신 및 예외 처리 가이드라인

### 4.1 동시성 제어 (`QueuedInterceptor` 사용 필수)
- 미디어 플레이어가 폴더를 탐색하거나 메타데이터를 병렬로 불러올 때 여러 API 요청이 동시에 401을 받을 수 있습니다.
- 일반 `Interceptor` 대신 반드시 Dio의 **`QueuedInterceptor`**를 상속하여, 첫 번째 401 에러가 토큰을 갱신하는 동안 후속 요청들이 대기하도록 구현해야 합니다.

### 4.2 401 Unauthorized 발생 시 무음 갱신(Silent Refresh) 표준 순서
`GoogleSignInAccount.authHeaders`는 내부적으로 토큰을 캐싱하므로, 401 발생 시 단순히 `authHeaders`를 다시 읽으면 **만료된 동일한 토큰**이 반환됩니다. 반드시 아래 순서를 지켜야 합니다:
1. `options.extra['is_retry'] == true`인지 확인합니다. 이미 `true`라면 갱신 후에도 실패한 것이므로 즉시 에러를 전파합니다.
2. 현재 `GoogleSignInAccount` 인스턴스에서 **`await account.clearAuthCache()`**를 호출하여 Play Services 로컬 캐시에서 만료된 액세스 토큰을 제거합니다.
3. **`await googleSignIn.signInSilently(suppressErrors: false)`**를 호출하여 최신 계정 인스턴스를 다시 획득합니다.
4. 새 계정 인스턴스에서 **`await refreshedAccount.authHeaders`**를 호출하여 새 토큰을 가져옵니다.
5. 원본 `err.requestOptions`에 `extra['is_retry'] = true`를 설정하고 새 헤더를 덮어씌운 뒤 `_dio.fetch(options)`로 재시도합니다.

### 4.3 미디어 플레이어 스트리밍(ExoPlayer 등) 연동 주의사항
- Google Drive의 파일 다운로드/스트리밍 엔드포인트는 `https://www.googleapis.com/drive/v3/files/{fileId}?alt=media`입니다.
- 플레이어에 URL을 넘길 때 URL 쿼리 파라미터에 토큰을 노출하기보다, `getStreamDescriptor(fileId)`를 통해 최신 `authHeaders`를 받아 플레이어의 `httpHeaders` 옵션에 주입해야 합니다.
- 장시간 영상 재생 후 다음 영상을 재생할 때 토큰(보통 1시간 유효)이 만료되었을 수 있으므로, `getStreamDescriptor` 호출 시점마다 `authHeaders`를 새로 조회하도록 구현합니다.

### 4.4 예외 매핑 규칙 (Exception Mapping)
| 발생 상황 | 감지 조건 | 변환할 예외 (`CloudAuthErrorType`) | UI 후속 조치 |
| :--- | :--- | :--- | :--- |
| 사용자가 계정 선택창 취소 | `googleSignIn.signIn()`이 `null` 반환 | `cancelledByUser` | 토스트 안내 후 현 상태 유지 |
| 스코프 권한 미동의 | `requestScopes()`가 `false` 반환 | `scopeDenied` | 권한 필요 안내 다이얼로그 표시 |
| SHA-1 미등록 / 설정 오류 | `PlatformException(code: 'sign_in_failed')` 및 메시지 내 `10:` 포함 | `networkOrPlayService` | 개발자 설정 오류 로그 출력 |
| Silent Refresh 실패 | 401 처리 중 `signInSilently()`가 `null` 반환 또는 예외 발생 | `sessionExpired` | `signOut()` 호출 후 재로그인 화면/모달 표시 |

---

## 5. Flash 모델에게 전달할 필수 구현 체크리스트

> **Flash 모델 구현 지시사항:** 아래 체크리스트를 하나도 빠짐없이 준수하여 코드를 작성하세요.

- [ ] **레거시 코드 제거:** 기존의 `clientId`, `clientSecret`, `redirectUri` 상수, `flutter_web_auth` / `webview_flutter` 기반 인증 코드, 그리고 `SharedPreferences`나 `FlutterSecureStorage`에 직접 Access/Refresh 토큰을 저장하던 로직을 모두 제거할 것.
- [ ] **GoogleSignIn 싱글턴/인스턴스 설정:** `GoogleSignIn(scopes: ['https://www.googleapis.com/auth/drive.readonly'])`로 초기화하되, 안드로이드에서 `clientId` 파라미터를 임의로 넣지 말 것.
- [ ] **초기화(`initialize`) 비차단 보장:** 앱 시작 시 호출되는 `signInSilently()`에서 네트워크 단절이나 로그인 이력 없음으로 실패하더라도 앱 크래시나 강제 로그인 창이 뜨지 않고 조용히 `false`를 반환하도록 `try-catch`로 감쌀 것.
- [ ] **스코프 재검증:** 대화형 `signIn()` 성공 직후, 필요한 드라이브 스코프가 부여되었는지 확인하고 필요 시 `requestScopes`를 호출하여 권한 누락으로 인한 403 에러를 방지할 것.
- [ ] **`clearAuthCache()` 누락 금지:** 401 에러 핸들링 시 반드시 `clearAuthCache()`를 먼저 호출한 뒤 `signInSilently()`와 `authHeaders`를 재호출할 것.
- [ ] **무한 루프 방지 플래그:** Dio 인터셉터에서 401 재시도 시 `RequestOptions.extra['is_retry'] = true`를 설정하고, 재시도 요청마저 401이 발생하면 즉시 루프를 종료하고 `CloudAuthErrorType.sessionExpired` 예외를 던질 것.
- [ ] **`QueuedInterceptor` 적용:** 다중 API 호출 시 토큰 갱신이 한 번만 일어나도록 `Interceptor`가 아닌 `QueuedInterceptor`를 상속할 것.
- [ ] **인터페이스 일관성 유지:** `GoogleDriveProvider`의 모든 public 메서드는 테라박스, 바이두, 네이버 MYBOX 프로바이더와 동일한 `CloudStorageProvider` 시그니처 및 반환 타입(`CloudMediaItem`, `MediaStreamDescriptor`)을 엄격히 준수할 것.
