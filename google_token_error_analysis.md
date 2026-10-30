# Google 로그인 성공 후 `Exception: 구글 토큰 발급 실패` 원인 및 점검 가이드

브라우저에서 Google 계정 로그인과 권한 동의가 **성공(✓ 인증이 성공적으로 완료되었습니다!)**으로 표시되었음에도 앱으로 돌아온 직후 `Exception: 구글 토큰 발급 실패`가 발생하는 원인과 점검해야 할 코드 위치를 정리한 문서입니다.

---

## 1. 에러가 발생하는 정확한 코드 위치

에러 메시지는 아래 두 파일의 `OAuthHelper.exchangeGoogleToken()` 메서드에서 발생합니다:

- **미디어 플레이어**: [`lib/services/oauth_helper.dart`](file:///D:/My%20Documents/AI/cloud_media_player/lib/services/oauth_helper.dart#L276-L304) (298~300행)
- **만화 뷰어**: [`lib/services/oauth_helper.dart`](file:///D:/My%20Documents/AI/cloud_comic_viewer/lib/services/oauth_helper.dart#L273-L301) (295~297행)

```dart
final res = await postWithRetry(
  Uri.parse('https://oauth2.googleapis.com/token'),
  headers: {'Content-Type': 'application/x-www-form-urlencoded'},
  body: body,
);

if (res.statusCode != 200) {
  throw Exception('구글 토큰 발급 실패 (${res.statusCode}): ${res.body}');
}
```

즉, **1단계(인가 코드 `code` 발급 및 로컬 루프백 서버 수신)는 성공**했으나, **2단계(받은 `code`를 `https://oauth2.googleapis.com/token`에 보내 Access Token으로 교환하는 과정)**에서 실패한 것입니다.

---

## 2. 왜 브라우저 로그인은 성공했는데 토큰 발급에서 실패하는가? (핵심 원인 3가지)

### 원인 A: 인증 코드(`code`) 중복 제출 (이중 호출로 인한 `400 invalid_grant`) — **[가장 유력]**
Google OAuth의 인가 코드(`authorization_code`)는 **단 1회만 사용 가능한 일회성(One-time) 코드**입니다.

현재 [`add_account_dialog.dart`](file:///D:/My%20Documents/AI/cloud_media_player/lib/ui/screens/add_account_dialog.dart)와 [`oauth_helper.dart`](file:///D:/My%20Documents/AI/cloud_media_player/lib/services/oauth_helper.dart)의 흐름을 보면 다음 문제가 발생할 수 있습니다:

1. **클립보드 자동 감지(`didChangeAppLifecycleState`)와 루프백의 충돌**:
   - 사용자가 이전에 주소창을 복사해 두었거나 브라우저에서 돌아올 때 `didChangeAppLifecycleState(AppLifecycleState.resumed)`가 즉시 실행됩니다.
   - 만약 클립보드에 **이전에 시도했던 만료된 `code=` URL**이 남아 있었다면, 앱으로 돌아오는 순간 `_checkClipboardForAuthCode()`가 **만료된 이전 클립보드 코드**를 `OAuthHelper.submitManualCallback(text)`로 먼저 밀어넣어 버립니다!
   - 그 결과 `exchangeGoogleToken()`이 **이미 사용되었거나 만료된 이전 `code`**(또는 다른 `code_verifier`로 생성된 코드)로 토큰 교환을 요청하게 되어, Google 서버가 `400 Bad Request (invalid_grant: Bad Request / Code was already redeemed)`를 반환합니다.

#### 점검할 위치:
- [`lib/ui/screens/add_account_dialog.dart`](file:///D:/My%20Documents/AI/cloud_media_player/lib/ui/screens/add_account_dialog.dart#L72-L90)의 `_checkClipboardForAuthCode()`
  - 클립보드에 남아 있던 **과거의 URL/코드**를 현재 세션의 코드로 착각하고 자동 제출하는지 확인해야 합니다. (OAuth 시작 시점에 클립보드를 비우거나, `state` 파라미터를 비교해야 함)

---

### 원인 B: 인앱 브라우저 종료 직후 안드로이드 네트워크 복구 지연 (`SocketException` / `ClientException`)
1. `OAuthHelper.authenticateWithLoopback()`에서 `code`를 받자마자 `closeInAppWebView()`로 브라우저를 닫고 즉시 [`add_account_dialog.dart`](file:///D:/My%20Documents/AI/cloud_media_player/lib/ui/screens/add_account_dialog.dart#L244-L252)에서 `OAuthHelper.exchangeGoogleToken()`을 호출합니다.
2. 갤럭시(삼성 One UI) 환경에서는 Custom Tab(또는 외부 브라우저)에서 메인 Activity로 포커스가 넘어오는 약 0.5~1.5초 동안 앱의 DNS/소켓이 일시적으로 끊기거나, `postWithRetry` 도중 예외가 발생할 수 있습니다.
3. 특히 [`add_account_dialog.dart`](file:///D:/My%20Documents/AI/cloud_media_player/lib/ui/screens/add_account_dialog.dart#L245)의 대기 시간(`Future.delayed`)이 짧으면 앱이 완전히 포그라운드 네트워크 권한을 회복하기 전에 요청이 실패할 수 있습니다.

#### 점검할 위치:
- [`lib/ui/screens/add_account_dialog.dart`](file:///D:/My%20Documents/AI/cloud_media_player/lib/ui/screens/add_account_dialog.dart#L244-L253)의 `_authenticateGoogle()` 내 토큰 교환 전 대기 시간(`Future.delayed`)
- [`lib/services/oauth_helper.dart`](file:///D:/My%20Documents/AI/cloud_media_player/lib/services/oauth_helper.dart#L247-L273)의 `postWithRetry()` 예외 처리 부분

---

### 원인 C: 네이티브 로그인(`GoogleLoginButton`)과 브라우저 OAuth(`_startOAuth`)의 동시 실행 충돌
1. 사용자가 **`Google 계정으로 원터치 연결` (`GoogleLoginButton`)** 버튼을 눌렀을 때:
   - 현재 PC의 디버그 키스토어 SHA-1이 Google Cloud Console에 등록되어 있지 않으면 `ApiException: 10 (sign_in_failed)`이 발생합니다.
2. 이때 [`add_account_dialog.dart`](file:///D:/My%20Documents/AI/cloud_media_player/lib/ui/screens/add_account_dialog.dart#L1525-L1530)의 `onError` 콜백이 자동으로 `_startOAuth()`(브라우저 로그인)를 호출하도록 되어 있는데, 만약 사용자가 버튼 두 개를 연달아 눌렀다면 `_startOAuth()`가 두 번 실행되면서 **`codeVerifier`가 새로 덮어써지는 현상(PKCE 불일치)**이 발생합니다.
   - 첫 번째 브라우저에서 로그인해서 받은 `code`를 두 번째로 덮어써진 `codeVerifier`로 토큰 교환하려고 하면 Google 서버는 무조건 `400 invalid_grant (invalid code_verifier)` 에러를 냅니다.

#### 점검할 위치:
- [`lib/ui/screens/add_account_dialog.dart`](file:///D:/My%20Documents/AI/cloud_media_player/lib/ui/screens/add_account_dialog.dart#L1501-L1542)의 `GoogleLoginButton` `onError` 자동 폴백 로직 및 `_isLoading` 중복 실행 방지 여부

---

## 3. 한눈에 보는 점검 체크리스트 요약

| 순번 | 의심 원인 | 화면에 표시되는 상세 에러 형태 | 확인해야 할 파일 및 라인 |
| :--- | :--- | :--- | :--- |
| **1순위** | **클립보드에 남아있던 이전 `code=` URL이 앱 복귀 시 자동 제출됨** (또는 `codeVerifier` 불일치) | `구글 토큰 발급 실패 (400): { "error": "invalid_grant", ... }` | [`add_account_dialog.dart` (72~90행)](file:///D:/My%20Documents/AI/cloud_media_player/lib/ui/screens/add_account_dialog.dart#L72-L90) `_checkClipboardForAuthCode()` |
| **2순위** | **네이티브 로그인 실패 후 자동 폴백 시 중복 호출로 `codeVerifier` 덮어쓰기** | `구글 토큰 발급 실패 (400): { "error": "invalid_grant" }` | [`add_account_dialog.dart` (1525~1530행)](file:///D:/My%20Documents/AI/cloud_media_player/lib/ui/screens/add_account_dialog.dart#L1525-L1530) `GoogleLoginButton.onError` |
| **3순위** | **GCP 콘솔의 Client ID / Client Secret 만료 또는 유형 불일치** | `구글 토큰 발급 실패 (401): { "error": "invalid_client" }` | [`google_drive_service.dart` (11~13행)](file:///D:/My%20Documents/AI/cloud_media_player/lib/services/google_drive_service.dart#L11-L13) `defaultClientId`, `defaultClientSecret` |
| **4순위** | **기기 시간(날짜/시각) 오차 또는 포그라운드 전환 직후 소켓 단절** | `SocketException` 또는 `invalid_grant` | [`oauth_helper.dart` (247~273행)](file:///D:/My%20Documents/AI/cloud_media_player/lib/services/oauth_helper.dart#L247-L273) `postWithRetry()` |
