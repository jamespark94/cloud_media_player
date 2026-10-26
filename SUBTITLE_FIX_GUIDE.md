# 자막 이슈 수정 가이드 (Baidu / TeraBox)

대상 파일: `lib/ui/screens/player_screen.dart`
(폰 logcat 분석 결과 기반. 수정 후 `flutter analyze` → 폰에서 재현 테스트)

## 이슈 1. Baidu: SMI/SRT 모두 안 나옴 (원인 확정)

**증상 로그**
```
자막 다운로드/변환 실패: FileSystemException: Cannot open file ... (OS Error: File name too long, errno = 36)
```
다운로드(HTTP 200)는 성공하지만 캐시 파일 저장에서 실패한다.

**원인**: `_getSafeSubtitleCacheFile(id, name)`(약 758행)이 `{safeId}_{safeBase}{ext}`로 파일명을 만든다.
Baidu의 `id`에는 전체 경로(`/Ani/건담…`)가 들어 있고 `name`(일본어/한글)까지 중복 포함되어 안드로이드 한도(255바이트, UTF-8 기준)를 넘는다. TeraBox는 id가 숫자라 정상.

**수정**
- 파일명에 id/원본 이름을 직접 쓰지 말고 해시로 짧게 만든다.
  - 예: `final key = (id + '|' + (name ?? '')).hashCode.toUnsigned(32).toRadixString(16);`
  - 파일명: `'$key$ext'` (`ext`는 기존처럼 `SubtitleUtils.getExtension(name ?? id)`, 없으면 빈 문자열)
  - 충돌이 걱정되면 `dart:convert` + `crypto` 패키지 사용 가능 여부를 확인하고 사용하되, 새 의존성은 추가하지 말 것(없으면 hashCode 사용).
- 확장자는 반드시 끝에 유지한다 (mpv가 포맷을 확장자로 감지).
- 기존 긴 이름의 캐시는 자연히 무시된다(별도 정리 불필요).
- 추가 방어: `_downloadAndNormalizeSubtitle`의 저장 로직에서 `{`로 시작하거나 `errno`가 들어 있는 본문(JSON 오류 응답)은 자막으로 저장하지 않고 `null` 반환.

## 이슈 2. TeraBox: SMI만 첫 재생 시 안 나옴 (SRT 경유 후 SMI 선택하면 나옴)

**로그 근거**: 첫 재생 시 SMI는 다운로드·UTF-8 변환까지 성공하지만 이후 `자막 트랙 목록 갱신`이 계속 `[auto, no]` 2개뿐이다. 즉 외부 자막이 mpv에 붙지 않았다.
(SRT는 `setSubtitleTrack` 직후 `[id=1, ...srt, lang=ko]`가 목록에 나타남. `초기 자막 적용` 로그도 남지 않음.)

**원인(추정)**: `initState` 흐름의 5단계(약 440~448행)에서 `_player.open()` 직후, 파일 로드 완료 전에 `_player.setSubtitleTrack(SubtitleTrack.uri(...))`를 호출한다. mpv가 로드 중 트랙을 재구성하면서 이를 버린다. 재생 중 선택(`_applySelectedSubtitleAsync`)은 로드 후라 정상 동작.

**수정**
1. `open()` 이후 초기 외부 자막 적용 전에 로드 완료를 기다린다.
   - `await _player.stream.duration.firstWhere((d) => d > Duration.zero).timeout(const Duration(seconds: 15), onTimeout: () => Duration.zero);`
   - 또는 `_player.stream.tracks` 첫 갱신을 대기. 타임아웃 시에도 그냥 진행.
   - 이 대기는 블로킹으로 UI 로딩을 막지 않게, 자막 적용 부분만 `unawaited` 비동기 함수로 분리하는 것을 권장.
2. 대기 후 `setSubtitleTrack(subTrack)` 호출, 이어서 `_hasAutoSelectedSubtitle = true`, `_saveCurrentPosition()` 유지.
3. 트랙 리스너(`_tracksSub`, 약 150행)의 순서 조정:
   - 현재는 `lang == 'ko' || title에 krcc` 분기가 먼저 실행되고 `return`하여 `_pendingInitialSubtitleTrack` 적용(3번 단계)에 도달하지 못한다.
   - `_pendingInitialSubtitleTrack` 처리를 ko/KRCC 분기보다 앞에 두거나, ko/KRCC 분기에서 `return` 전에 pending 처리를 하도록 한다.
   - 단, `_currentSubtitleType == 'none'`이면 기존대로 `no` 유지가 최우선.
4. SMI의 경우 적용 후 `krcc`/`ko` 트랙이 새로 생기면 그 트랙을 선택하는 기존 로직은 유지.

## 검증 체크리스트
- [ ] `flutter analyze` 통과
- [ ] Baidu: SRT/SMI 각각 첫 재생 시 자막 표시, 로그에 `UTF-8 변환 및 캐시 완료` 출력
- [ ] TeraBox: SMI 자막이 있는 영상 첫 재생 시 바로 표시 (SRT 경유 불필요)
- [ ] TeraBox: SRT 기존 동작 회귀 없음, 자막 끄기('none') 유지
- [ ] 로그 확인: `adb logcat -d -s flutter | Select-String "자막"`
  (adb 경로: `D:\Program Files\Android\Sdk\platform-tools\adb.exe`)

## 주의
- 기존 주석/독스트링은 수정 범위 외에는 보존할 것.
- 이 가이드 범위 밖의 리팩터링 금지.
