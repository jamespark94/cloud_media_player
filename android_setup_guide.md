# Google Drive OAuth (Android) 환경 설정 가이드

본 문서는 `cloud_media_player` 안드로이드 환경에서 공식 `google_sign_in` 패키지를 통해 Google Drive에 안전하게 연동하기 위한 설정 가이드입니다.

---

## 1. `pubspec.yaml` 의존성 추가

`pubspec.yaml`의 `dependencies:` 섹션에 아래 패키지를 추가하고 `flutter pub get`을 실행합니다.

```yaml
dependencies:
  flutter:
    sdk: flutter
  # ... 기존 의존성 ...
  google_sign_in: ^6.2.1
```

터미널 실행:
```bash
flutter pub get
```

---

## 2. SHA-1 서명 지문 추출 (Android)

안드로이드의 `google_sign_in`은 Client Secret을 사용하지 않는 대신 **앱 패키지명(applicationId)**과 **서명 키의 SHA-1 지문** 조합으로 클라이언트 신원을 검증합니다.

### 터미널 명령어
프로젝트 루트 또는 `android` 디렉터리에서 아래 명령을 실행합니다:

```bash
# Windows (PowerShell / CMD)
cd android
.\gradlew signingReport

# macOS / Linux
cd android
./gradlew signingReport
```

실행 결과 중 `Task :app:signingReport` 아래의 `Variant: debug` (출시 시 `Variant: release`)에 표시되는 **SHA-1** 값을 복사합니다:
```text
Variant: debug
Config: debug
Store: C:\Users\<Username>\.android\debug.keystore
Alias: AndroidDebugKey
SHA1: AA:BB:CC:DD:EE:FF:11:22:33:44:55:66:77:88:99:00:11:22:33:44
```

---

## 3. Google Cloud Platform (GCP) 콘솔 등록 절차

1. **GCP 콘솔 접속**: [Google Cloud Console](https://console.cloud.google.com/)
2. **API 및 서비스 > 라이브러리**:
   - `Google Drive API` 검색 후 **사용(Enable)** 클릭.
3. **OAuth 동의 화면 (OAuth consent screen)**:
   - 사용자 유형: 외부(External) 선택 후 앱 정보 입력.
   - **범위(Scopes)** 추가:
     - `https://www.googleapis.com/auth/drive.readonly` 필수 추가.
   - 테스트 상태인 경우 본인의 Google 계정을 **테스트 사용자**로 등록.
4. **사용자 인증 정보 (Credentials) 생성**:
   - `+ 사용자 인증 정보 만들기` > `OAuth 클라이언트 ID` 선택.
   - 애플리케이션 유형: **Android** 선택.
   - **패키지 이름**: `android/app/build.gradle`의 `applicationId` 입력 (예: `com.example.cloud_media_player`).
   - **SHA-1 인증서 지문**: 위 2번 단계에서 추출한 `SHA-1` 값 입력.
   - 만들기 클릭.

---

## 4. `google-services.json` 배치 (선택/권장)

- Firebase 프로젝트를 연동하거나 Google Services 플러그인을 사용하는 경우:
  - GCP / Firebase에서 다운로드한 `google-services.json` 파일을 `android/app/` 경로에 배치합니다.
- 패키지명과 SHA-1이 정확히 등록되어 있다면 코드 내에 `clientId`나 `clientSecret`을 하드코딩할 필요 없이 `GoogleSignIn`이 네이티브 SDK 레벨에서 정상 동작합니다.
