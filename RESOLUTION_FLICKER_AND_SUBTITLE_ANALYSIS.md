# 심리스(Seamless) 해상도 전환 시 화면 깜빡거림(Flicker) 및 자막 유실 원인 분석과 개선 방안

## 1. 개요

듀얼 플레이어(`_player` & `_standbyPlayer`) 프리버퍼링 구조 도입 후 해상도 전환 대기 시간은 크게 단축되었으나, 실제 전환(Hot-Swap) 시점에 **1) 여전히 순간적인 검은 화면 깜빡거림(Flicker)이 발생하는 현상**과 **2) 해상도가 바뀌면 기존에 나오던 자막이 사라지는 현상**이 재발하고 있습니다.

현재 [`player_screen.dart`](file:///D:/My%20Documents/AI/cloud_media_player/lib/ui/screens/player_screen.dart)의 실제 구현 코드를 정밀 분석한 결과, 두 문제 모두 명확한 타이밍 및 렌더링 파이프라인 상의 원인이 존재합니다.

---

## 2. 문제 1: 전환 시 여전히 발생하는 '깜빡거림(Flicker)' 원인 분석

현재 [`_tryHotSwapQuality()`](file:///D:/My%20Documents/AI/cloud_media_player/lib/ui/screens/player_screen.dart#L2262-L2418) 및 [`build()`](file:///D:/My%20Documents/AI/cloud_media_player/lib/ui/screens/player_screen.dart#L1872-L1905)의 비디오 위젯 레이어 구조에서 다음 **4가지 결정적 원인**이 복합적으로 작용하여 깜빡거림을 유발합니다.

### 원인 1-1. 스왑 직전 `standby.seek(livePos)` 호출 직후 디코딩 완료 대기 누락 (가장 치명적)
- **코드 위치**: [`player_screen.dart#L2349-L2366`](file:///D:/My%20Documents/AI/cloud_media_player/lib/ui/screens/player_screen.dart#L2349-L2366)
  ```dart
  final livePos = _player.state.position;
  final standbyPos = standby.state.position;
  if ((livePos - standbyPos).abs() > const Duration(milliseconds: 300)) {
    try {
      await standby.seek(livePos);
    } catch (_) {}
  }
  // 대기 없이 즉시 아래에서 _controller = standbyCtrl 스왑 실행!
  ```
- **발생 메커니즘**:
  - `standby` 플레이어가 첫 프레임을 디코딩하기까지 걸린 시간(예: 2~4초) 동안 기존 `_player`는 계속 재생되어 `livePos`와 `standbyPos` 사이에 **거의 항상 300ms 이상의 차이**가 발생합니다.
  - 이때 `await standby.seek(livePos)`를 호출하면, `libmpv`의 `seek` 명령은 **탐색 명령을 큐에 넣었을 때 즉시 Future가 반환**될 뿐, 새로운 위치의 세그먼트(HLS `.ts` 또는 MP4 키프레임)를 받아 디코딩을 완료할 때까지 기다리지 않습니다.
  - 동시에 `seek()` 호출로 인해 `standby` 내부 비디오 출력 버퍼가 비워지고 `buffering = true` 상태가 되는데, **단 1ms도 기다리지 않고 바로 `_controller = standbyCtrl`로 화면을 스왑**해 버리므로 스왑 직후 수백 ms 동안 빈 버퍼(검은 화면)나 버퍼링 스피너가 노출됩니다.

### 원인 1-2. `ValueKey(_controller)` 교체로 인한 `Video` 위젯 언마운트 & 텍스처 재생성 딜레이
- **코드 위치**: [`player_screen.dart#L1875-L1905`](file:///D:/My%20Documents/AI/cloud_media_player/lib/ui/screens/player_screen.dart#L1875-L1905)
- **발생 메커니즘**:
  - 현재 백그라운드 워밍업 위젯은 `if (_standbyController != null)` 조건부 블록 안에 있고, 메인 비디오 위젯은 `Center` 내부에 별도의 `Video(key: ValueKey(_controller))`로 선언되어 있습니다.
  - 핫스왑 시 `_standbyController = null`이 되면서 워밍업 중이던 `Video` 위젯은 **트리에서 파괴(unmount)**되고, 메인 `Center` 안의 `Video` 위젯은 `ValueKey`가 바뀌면서 **기존 위젯 폐기 후 새로운 `Video`State 및 Android `Texture` 위젯을 처음부터 다시 마운트**합니다.
  - Flutter 엔진이 기존 `Texture` 레이어를 지우고 새 `VideoController`의 `Texture` ID를 바인딩하는 1~2 프레임(약 16~33ms) 동안 배경색(`Colors.black`)이 그대로 노출되어 육안으로 뚜렷한 검은색 깜빡임(Black Flash)이 보입니다.

### 원인 1-3. `checkReady()`의 첫 프레임 렌더링 판별 조건 불충분
- **코드 위치**: [`player_screen.dart#L2322-L2329`](file:///D:/My%20Documents/AI/cloud_media_player/lib/ui/screens/player_screen.dart#L2322-L2329)
  ```dart
  final hasWidth = standby.state.width != null && standby.state.width! > 0;
  final notBuffering = !standby.state.buffering;
  if (hasWidth && notBuffering) {
    readyCompleter.complete(true);
  }
  ```
- **발생 메커니즘**:
  - `libmpv`에서 `state.width > 0`은 실제 첫 비디오 프레임이 Android `SurfaceTexture`에 그려진 시점이 아니라, **비디오 스트림 헤더(SPS/PPS 또는 M3U8 메타데이터)만 파싱된 직후**에 즉시 `true`가 됩니다.
  - 또한 `open()` 직후 네트워크 버퍼링이 본격적으로 시작되기 전 찰나의 순간에 `state.buffering == false`인 구간이 존재합니다.
  - 따라서 아직 실제 비디오 프레임이 텍스처에 단 한 장도 그려지지 않았는데도 `checkReady()`가 통과되어 검은 텍스처 상태로 스왑되는 레이스 컨디션이 발생합니다.

### 원인 1-4. 전환 중 중앙 버퍼링 스피너(`_buildCenterPlayPause`) 깜빡임
- **코드 위치**: [`player_screen.dart#L2827-L2842`](file:///D:/My%20Documents/AI/cloud_media_player/lib/ui/screens/player_screen.dart#L2827-L2842)
- 스왑 직후 `standby`가 미세하게 버퍼링(`isBuffering == true`) 상태에 걸리면 화면 정중앙의 플레이 버튼 자리에 검은 원형 스피너(`CircularProgressIndicator`)가 순간적으로 번쩍하며 나타났다가 사라져 시각적 깜빡임을 가중시킵니다.

---

## 3. 문제 2: 해상도 전환 후 '자막이 안 나오는 문제' 원인 분석

해상도를 바꿨을 때 자막이 증발하는 현상은 **`libmpv`의 라이프사이클 특성**과 **`PlayerScreen`의 자막 트랙 이벤트 리스너(`_tracksSub`) 로직 충돌** 때문에 발생합니다.

### 원인 2-1. `standby.open()` 이전에 호출된 `standby.setSubtitleTrack()`이 무시 및 초기화됨 (핵심 원인)
- **코드 위치**: [`player_screen.dart#L2292-L2314`](file:///D:/My%20Documents/AI/cloud_media_player/lib/ui/screens/player_screen.dart#L2292-L2314)
  ```dart
  // [문제 지점] open() 호출 전에 setSubtitleTrack()을 먼저 호출함!
  if (savedSubType != 'none' && externalSubFile != null && externalSubFile.existsSync()) {
    final subTrack = SubtitleTrack.uri(
      externalSubFile.path,
      title: savedSubName,
      language: savedSubLang ?? 'ko',
    );
    standby.setSubtitleTrack(subTrack).catchError((_) {}); // <-- 무시되거나 open() 시 초기화됨!
  }
  ...
  await standby.open(Media(playUrl, ...), play: true);
  ```
- **발생 메커니즘**:
  1. `media_kit`(`libmpv`)에서 `SubtitleTrack.uri(...)`를 통한 외부 자막 추가(`sub-add` 명령)는 **반드시 미디어(`open`)가 로드된 이후(정확히는 디먹서가 생성된 이후)**에 실행되어야 합니다.
  2. 미디어가 열리기 전에 호출된 `sub-add`는 `libmpv`에서 에러로 무시되거나, 직후 실행되는 `standby.open(...)`(`loadfile` 명령)에 의해 **모든 트랙 테이블이 초기화(Reset)되면서 완전히 삭제**됩니다.
  3. 실제로 초기 재생 함수인 [`_initAndPlay()`(504~541행)](file:///D:/My%20Documents/AI/cloud_media_player/lib/ui/screens/player_screen.dart#L504-L541)에서는 이를 방지하기 위해 `open()` 이후 `duration > 0`이 될 때까지 기다렸다가 `setSubtitleTrack`을 호출하고 `_pendingInitialSubtitleTrack`까지 설정해 두었지만, **`_tryHotSwapQuality()`에서는 `open()` 이전에 단발성으로 호출하고 끝내버렸기 때문에** 외부 자막이 100% 유실됩니다.

### 원인 2-2. `_hasAutoSelectedSubtitle = true` 플래그가 리셋되지 않아 핫스왑 후 자막 복원 로직이 통째로 스킵됨
- **코드 위치**: [`player_screen.dart#L233-L245`](file:///D:/My%20Documents/AI/cloud_media_player/lib/ui/screens/player_screen.dart#L233-L245)
  ```dart
  // 이미 자막 트랙이 선택되었거나 로드된 경우 중복 호출 차단
  if (_hasAutoSelectedSubtitle) return;

  // 4. 외부 자막(클라우드/로컬) 적용 상태인 경우: 일반 내장 트랙 오버라이드 방지
  if (_currentSubtitleType == 'cloud' || _currentSubtitleType == 'local') {
    return;
  }

  // 5. 내장 자막 복원 또는 한국어 트랙 자동 선택
  if (_currentSubtitleType == 'track') {
    _restoreTrackSubtitle(tracks.subtitle);
  } else if (_currentSubtitleType == null) {
    _selectKoreanTrack(tracks.subtitle);
  }
  ```
- **발생 메커니즘**:
  - 초기 360p 영상 재생 시 자막이 선택되면서 `_hasAutoSelectedSubtitle = true`가 됩니다.
  - 이후 720p로 해상도를 전환하면 새로운 `standby` 플레이어가 생성되고 `_bindPlayerStreams(_player)`가 호출되지만, **`_hasAutoSelectedSubtitle`은 여전히 `true`로 남아 있습니다.**
  - 그 결과 새 플레이어에서 `stream.tracks` 이벤트가 발생해도 **233행의 `if (_hasAutoSelectedSubtitle) return;`에 가로막혀** 내장 자막 복원(`_restoreTrackSubtitle`)이나 한국어 트랙 자동 선택(`_selectKoreanTrack`)이 아예 실행되지 않습니다.

### 원인 2-3. 핫스왑 시점 이전에 이미 `standby.stream.tracks` 이벤트가 지나가 버림
- `_bindPlayerStreams(_player)`는 핫스왑이 완료되는 시점([`2384행`](file:///D:/My%20Documents/AI/cloud_media_player/lib/ui/screens/player_screen.dart#L2384))에야 비로소 `standby` 플레이어에 연결됩니다.
- 하지만 `standby` 플레이어의 트랙 파싱 이벤트(`stream.tracks`)는 백그라운드 버퍼링 도중(핫스왑 이전)에 이미 발생해 버렸으므로, 핫스왑 이후에 `_bindPlayerStreams`로 리스너를 등록해도 트랙 변경 이벤트가 다시 발생하지 않아 자막 연결 타이밍을 놓치게 됩니다.

### 원인 2-4. 360p/720p(HLS) ↔ 원본(Direct MP4/MKV) 전환 시 트랙 구조 변화 미대응
- 바이두/테라박스의 HLS 변환 스트림(`M3U8_AUTO_360`, `M3U8_AUTO_720`)은 원본 영상의 내장 자막 트랙(Soft-sub)을 제거한 트랜스코딩 스트림인 반면, `원본(Original)`은 내장 자막 트랙을 포함하고 있습니다.
- 또한 이전 트랙의 `activeSub.id`를 그대로 새 플레이어에 넣으면, HLS ↔ 원본 전환 시 트랙 ID 매핑이 달라지거나 외부 자막의 경우 새 플레이어에 파일 자체가 등록(`sub-add`)되지 않은 상태에서 숫자 ID(예: `1`)만 선택하려 하므로 자막이 출력되지 않습니다.

---

## 4. 단계별 완벽 개선 방안 (How to Fix)

### 4.1. 깜빡거림(Flicker) 제로화를 위한 4대 개선책

#### ① [프리즈 프레임 가드 상시 적용] 스왑 직전 마지막 프레임 캡처 오버레이 (`_freezeFrameBytes`)
- 기존에는 단일 플레이어 폴백(`_fallbackSinglePlayerSwitch`)에서만 사용하던 스크린샷 오버레이를 **듀얼 플레이어 핫스왑 시점에도 짧게(약 150~250ms) 적용**하거나, **단일 트리 크로스페이드 구조**로 변경합니다.
- 특히 Flutter Android의 `Texture` 위젯 교체 시 발생하는 1~2 프레임의 하드웨어 컴포지터 공백을 막기 위해, **두 `Video` 위젯을 파괴/재생성하지 않고 동일한 트리 뎁스에 유지한 채 `Opacity`만 `0.0 ↔ 1.0`으로 전환**합니다.

#### ② [위젯 트리 구조 통합] `Video` 위젯 언마운트/리마운트 제거
- `build()`에서 워밍업용 `Video`와 메인 `Video`를 별도 계층으로 두지 않고, **영구적인 2-슬롯(Slot A / Slot B) 또는 `Stack` 내 고정 위치**에서 투명도(`Opacity`)만 교차시킵니다:
  ```dart
  // 개선된 비디오 스택 구조 예시
  Stack(
    fit: StackFit.expand,
    children: [
      // 메인 플레이어
      Center(
        child: Video(
          key: ObjectKey(_controller),
          controller: _controller,
          controls: NoVideoControls,
          subtitleViewConfiguration: const SubtitleViewConfiguration(visible: false),
        ),
      ),
      // 스탠바이 플레이어 (준비 중에는 0.001, 준비 완료되어 스왑 직전 1.0으로 올린 뒤 컨트롤러 교체)
      if (_standbyController != null)
        Positioned.fill(
          child: Opacity(
            opacity: _isStandbyFrameReady ? 1.0 : 0.001,
            child: Center(
              child: Video(
                key: ObjectKey(_standbyController),
                controller: _standbyController!,
                controls: NoVideoControls,
                subtitleViewConfiguration: const SubtitleViewConfiguration(visible: false),
              ),
            ),
          ),
        ),
    ],
  )
  ```
- **핵심 원리**:
  1. `_standbyController`가 준비 완료되면 먼저 `_isStandbyFrameReady = true`로 만들어 **기존 영상 위에 새 화질 영상을 불투명도 1.0으로 덮어씌웁니다** (이 시점에 기존 `_controller`는 뒤에서 그대로 살아있으므로 검은 화면이 0ms도 노출될 수 없음).
  2. 다음 프레임(`WidgetsBinding.instance.addPostFrameCallback`)에서 `_controller = _standbyController!`로 레퍼런스를 넘기고 `_standbyController = null`로 제거하면, **사용자의 눈에는 단 1프레임의 깜빡임도 없이 완벽하게 전환**됩니다.

#### ③ [선행 위치 정밀 계산 & 불필요한 스왑 직전 `seek()` 제거]
- 스왑 직전 `await standby.seek(livePos)`가 버퍼를 비워 깜빡임을 유발하는 문제를 해결하기 위해:
  1. `standby.open()` 이후 **첫 비디오 패킷이 실제로 디코딩되어 `position`이 전진하기 시작한 시점(`standby.state.position > targetStart`)**을 감지합니다.
  2. 만약 `livePos`와 `standbyPos`의 차이가 크다면, **핫스왑 하기 전에** `await standby.seek(livePos + 500ms)`를 먼저 수행하고, **다시 `buffering == false`가 되며 `standby.stream.position`이 실제로 1프레임 이상 전진(`pos > seekTarget`)할 때까지 백그라운드에서 대기**한 뒤 스왑합니다.
  3. 가장 이상적인 방법은 `standby`를 `livePos + 1.5초`에서 열어 첫 프레임을 디코딩한 뒤 `standby.pause()` 상태로 대기시키고, Primary `_player.state.position`이 `standbyPos`에 도달하는 순간(예: 0.5초 대기) `standby.play()`와 함께 스왑하는 **무탐색 동기화(Zero-Seek Sync)** 방식입니다. 이 방식을 쓰면 `seek()`로 인한 디코더 플러시가 아예 발생하지 않습니다.

---

### 4.2. 해상도 변경 시 자막 유실 완벽 해결책

#### ① 자막 재적용 전용 헬퍼 함수 `_reapplySubtitleToPlayer(Player targetPlayer)` 구현
- `open()` 이전에 자막을 넣던 기존 방식을 폐기하고, **반드시 미디어의 디먹서 및 트랙이 초기화된 이후(`duration > 0` 및 `tracks` 로드 완료 후)** 자막을 바인딩하는 공통 함수를 만듭니다:

```dart
Future<void> _reapplySubtitleToPlayer(Player targetPlayer) async {
  // 1. 자막 끄기 상태면 명시적으로 'no' 설정
  if (_currentSubtitleType == 'none') {
    await targetPlayer.setSubtitleTrack(SubtitleTrack.no());
    return;
  }

  // 2. 외부 자막 파일(클라우드에서 받은 캐시 또는 로컬 파일)이 활성화된 경우 (최우선)
  final extFile = _activeExternalSubtitleFile;
  if ((_currentSubtitleType == 'cloud' || _currentSubtitleType == 'local') &&
      extFile != null &&
      extFile.existsSync() &&
      extFile.lengthSync() > 0) {
    final subTrack = SubtitleTrack.uri(
      extFile.path,
      title: _currentSubtitleName ?? 'subtitle',
      language: _currentSubtitleLanguage ?? 'ko',
    );
    // 트랙 초기화 완료 후 주입
    await targetPlayer.setSubtitleTrack(subTrack);
    debugPrint('[PlayerScreen] 해상도 전환 후 외부 자막 재바인딩 완료: ${extFile.path}');
    return;
  }

  // 3. 내장 자막('track')이거나 자동 선택 상태인 경우
  final subTracks = targetPlayer.state.tracks.subtitle;
  if (_currentSubtitleType == 'track') {
    _restoreTrackSubtitleForPlayer(targetPlayer, subTracks);
  } else {
    _selectKoreanTrackForPlayer(targetPlayer, subTracks);
  }
}
```

#### ② `standby` 플레이어의 비디오 디코딩이 시작된 직후(스왑 전) 자막 바인딩 및 강제 리프레시
- `_tryHotSwapQuality()`에서 `standby` 플레이어가 `open()`을 마치고 `width > 0 && !buffering` 상태(즉, `libmpv` 디먹서가 완전히 열린 상태)가 된 직후에 `await _reapplySubtitleToPlayer(standby)`를 호출합니다.
- 또한 핫스왑으로 `_player = standby`가 된 직후에도 안전장치로 300ms 뒤에 `if (_player.state.track.subtitle.id == 'no' && _currentSubtitleType != 'none') _reapplySubtitleToPlayer(_player)`를 한 번 더 검증합니다.

#### ③ `CustomSubtitleView`의 즉시 동기화 보장
- [`custom_subtitle_view.dart`](file:///D:/My%20Documents/AI/cloud_media_player/lib/ui/widgets/custom_subtitle_view.dart#L30-L48)에서 `didUpdateWidget`이 호출될 때:
  - 새 플레이어(`widget.player`)가 외부 자막(`SubtitleTrack.uri`)을 막 로드한 직후에는 현재 시점의 자막 라인이 `stream.subtitle` 이벤트로 다시 발생하기 전까지 `player.state.subtitle`이 빈 배열(`[]`)일 수 있습니다.
  - 따라서 핫스왑 완료 직전까지 화면에 떠 있던 마지막 자막(`oldWidget.player.state.subtitle`)이 있고 새 플레이어의 `state.subtitle`이 비어 있다면, 새 플레이어에서 첫 자막 이벤트가 올 때까지(최대 1.5초) 기존 자막 텍스트를 유지하도록 보완하면 전환 순간 자막조차 깜빡이지 않고 그대로 이어집니다.

---

## 5. 요약 대조표 (AS-IS vs TO-BE)

| 구분 | 현재 문제점 (AS-IS) | 개선 후 동작 (TO-BE) |
| :--- | :--- | :--- |
| **스왑 직전 시간 동기화** | `await standby.seek(livePos)` 호출 직후 버퍼링 완료를 기다리지 않고 즉시 스왑하여 빈 화면 노출 | 1) `standby`가 실제 프레임을 디코딩하고 `position`이 전진할 때까지 대기<br/>2) `seek`가 필요한 경우 `seek` 후 프레임 전진 완료까지 대기 후 스왑 |
| **비디오 위젯 교체 방식** | `_standbyController` 위젯 제거와 동시에 `ValueKey(_controller)` 변경으로 새 `Texture` 마운트 딜레이(검은 화면 1~2 프레임) 발생 | `_standbyController` 위젯의 `Opacity`를 먼저 `1.0`으로 올려 기존 화면 위를 덮은 뒤, 다음 프레임에서 컨트롤러 레퍼런스 교체 (Black Flash 0ms) |
| **외부 자막 유지** | `standby.open()` **이전에** `setSubtitleTrack`을 호출하여 `open()` 시 트랙이 초기화/증발됨 | `standby`의 미디어 디먹서가 완전히 열린 **이후(`width > 0`)** 및 스왑 직후에 `_reapplySubtitleToPlayer()`로 확실하게 바인딩 |
| **내장 자막 / 자동 자막** | `_hasAutoSelectedSubtitle = true`가 유지되어 새 플레이어의 `_tracksSub`에서 자막 복원 로직이 스킵됨 | 해상도 전환 시 자막 복원 플래그를 갱신하고 `_reapplySubtitleToPlayer()`에서 내장 트랙도 즉시 매칭 |
| **전환 중 자막 깜빡임** | 플레이어 교체 순간 `state.subtitle`이 잠시 `[]`로 초기화되어 자막이 깜빡임 | `CustomSubtitleView`에서 플레이어 핫스왑 시 새 자막 스트림 수신 전까지 직전 자막 프레임을 브릿지 유지 |
