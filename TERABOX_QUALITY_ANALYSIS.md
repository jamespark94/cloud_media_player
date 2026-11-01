# 테라박스(TeraBox) 동영상 해상도 변경 미동작 원인 분석 및 코드 수정 가이드

## 1. 현상 요약 (사용자 경험)
미디어 플레이어에서 테라박스(TeraBox) 영상을 재생한 뒤 해상도(화질) 변경 UI에서 `480p`, `720p`, `원본 (Direct)` 등을 선택하면:
1. 화면 하단에 **"해상도 전환 준비 중..."** → **"화질 전환 완료: 720p (고화질)"** 배너가 정상적으로 출력되고 상단 HD 아이콘 뱃지 숫자도 `480` / `720`으로 바뀝니다.
2. 내부적으로 보조 플레이어(Standby Player)가 생성되어 버퍼링 후 핫스왑(Hot-Swap)되는 동작이 실제로 수행됩니다.
3. **하지만 실제 재생되는 비디오 스트림의 해상도는 여전히 `640x360` (360p)에서 전혀 변하지 않거나**, `원본 (Direct)` 선택 시에는 약 10초간 대기하다가 화면이 멈추거나 전환에 실패합니다.

---

## 2. 연결된 기기(SM-A908N) ADB 로그 분석

연결된 기기(`SM-A908N`)에서 테라박스 영상(`Rome.S01E03.720p.BluRay.x264.anoXmous_.mp4` 및 `...1080p.HEVC.x265.PRT.mkv`)을 재생하고 해상도를 변경했을 때의 실제 `adb logcat` 기록입니다.

### 로그 증거 1: 480p / 720p 요청 시에도 무조건 `M3U8_AUTO_360` URL이 반환 및 캐싱됨
```text
11-01 07:42:39.997 I flutter : [TeraBoxService] HLS (360p) 스트림 URL 획득 성공: https://www.terabox.com/api/streaming?...&type=M3U8_AUTO_360&path=%2Ftemp%2FRome.S01E03.720p.BluRay.x264.anoXmous_.mp4...
11-01 07:42:40.499 I flutter : [TeraBoxService] HLS (480p) 스트림 URL 획득 성공: https://www.terabox.com/api/streaming?...&type=M3U8_AUTO_360&path=%2Ftemp%2FRome.S01E03.720p.BluRay.x264.anoXmous_.mp4...
11-01 07:42:40.925 I flutter : [TeraBoxService] HLS (720p) 스트림 URL 획득 성공: https://www.terabox.com/api/streaming?...&type=M3U8_AUTO_360&path=%2Ftemp%2FRome.S01E03.720p.BluRay.x264.anoXmous_.mp4...
```
* **분석**: `360p`, `480p`, `720p` 세 가지 화질의 스트림 URL을 획득할 때 **세 개 모두 쿼리 파라미터가 `type=M3U8_AUTO_360`인 완전히 동일한 URL**을 획득하여 각 화질의 캐시 키(`_360p`, `_480p`, `_720p`)에 저장하고 있습니다.

### 로그 증거 2: 사용자가 화질 변경을 시도할 때마다 `640x360` (360p) 스트림으로만 핫스왑됨
```text
// 1차 해상도 변경 시도 (07:42:48)
11-01 07:42:48.854 I VideoOutputManager: com.alexmercerind.media_kit_video.VideoOutputManager.create: -5476376605843027376
11-01 07:42:48.865 I flutter : [LocalStreamProxy] 스트림 요청: https://www.terabox.com/api/streaming?...&type=M3U8_AUTO_360...
11-01 07:42:50.694 I VideoOutputManager: com.alexmercerind.media_kit_video.VideoOutputManager.setSurfaceSize: -5476376605843027376 640 360
11-01 07:42:50.696 I flutter : {rect: {top: 0, left: 0, width: 640, height: 360}, wid: 6642, handle: -5476376605843027376, id: 1}
11-01 07:42:54.210 I flutter : [LocalStreamProxy] 스트림 세션 등록 해제: 1793486559997409_0

// 2차 해상도 변경 시도 (07:42:58)
11-01 07:42:58.495 I VideoOutputManager: com.alexmercerind.media_kit_video.VideoOutputManager.create: -5476376607888322992
11-01 07:42:58.512 I flutter : [LocalStreamProxy] 스트림 요청: https://www.terabox.com/api/streaming?...&type=M3U8_AUTO_360...
11-01 07:43:00.465 I VideoOutputManager: com.alexmercerind.media_kit_video.VideoOutputManager.setSurfaceSize: -5476376607888322992 640 360
```
* **분석**: 사용자가 480p 또는 720p를 선택했을 때 `StandbyPlayer`가 생성(`VideoOutputManager.create`)되고 스트림을 새로 열어 구 플레이어와 교체(`dispose`)하는 작업이 실제로 일어나지만, 요청하는 URL이 여전히 `type=M3U8_AUTO_360`이므로 디코더 출력 해상도(`setSurfaceSize`)는 계속 **`640 360` (360p)**에 머무릅니다.

### 로그 증거 3: `원본 (Direct)` 선택 시 10초 타임아웃 및 MediaCodec Surface 충돌 (07:43:07 ~ 07:43:18)
```text
11-01 07:43:07.978 I VideoOutputManager: com.alexmercerind.media_kit_video.VideoOutputManager.create: -5476376608839633328
// (LocalStreamProxy 경유 없이 rawStreamUrl을 직접 open 시도 -> 10초 동안 첫 프레임 디코딩 실패)
11-01 07:43:18.008 I VideoOutputManager: com.alexmercerind.media_kit_video.VideoOutputManager.dispose: -5476376608839633328
11-01 07:43:18.009 I flutter : {rect: {top: 0, left: 0, width: 1, height: 1}, wid: 0, handle: -5476376608839633328, id: 0}
11-01 07:43:18.369 I ACodec  : [OMX.qcom.video.decoder.avc] signalFlush
11-01 07:43:18.390 E Surface : freeAllBuffers: 10 buffers were freed while being dequeued!
11-01 07:43:18.409 I MediaCodec: Codec shutdown complete
11-01 07:43:18.427 I flutter : [LocalStreamProxy] 스트림 세션 등록 해제: 1793486578469736_1
```
* **분석**: `07:43:07`에 사용자가 `원본 (Direct)`을 선택했을 때, `StandbyPlayer`가 생성되었으나 **10초 동안 단 한 프레임도 디코딩하지 못해(`width: 1, height: 1`) `07:43:18`에 타임아웃으로 파기**되었습니다. 직후 단일 플레이어 폴백(`_fallbackSinglePlayerSwitch`)이 실행되면서 기존 HLS 프록시 세션이 해제되고 코덱이 종료되었습니다.

---

## 3. 코드 상의 근본 원인 (Root Causes)

### 원인 1 (핵심): `TeraBoxService._fetchHlsStreamUrl`의 후보 리스트 순서 버그
[`lib/services/terabox_service.dart`](file:///D:/My%20Documents/AI/cloud_media_player/lib/services/terabox_service.dart#L444-L460) 444~460행 코드를 보면 다음과 같이 작성되어 있습니다:

```dart
  Future<String?> _fetchHlsStreamUrl(String filePath, String fsId, [VideoQuality? quality]) async {
    List<String> qualities;
    if (quality != null) {
      if (quality == VideoQuality.q360p) {
        qualities = ['M3U8_AUTO_360'];
      } else if (quality == VideoQuality.q480p) {
        qualities = ['M3U8_AUTO_360', 'M3U8_AUTO_480']; // <-- 문제 지점!
      } else if (quality == VideoQuality.q720p) {
        qualities = ['M3U8_AUTO_360', 'M3U8_AUTO_720']; // <-- 문제 지점!
      } else {
        qualities = ['M3U8_AUTO_360'];
      }
    } else {
      qualities = ['M3U8_AUTO_360'];
    }

    for (final q in qualities) {
      // ...
      if (bodyText.contains('#EXTM3U')) {
        return streamUri.toString(); // <-- 첫 번째 요소(M3U8_AUTO_360)가 성공하므로 즉시 return!
      }
```
1. `q480p`나 `q720p`를 요청해도 `qualities` 배열의 **첫 번째 원소(`qualities[0]`)에 `'M3U8_AUTO_360'`이 배치**되어 있습니다.
2. 아래 `for (final q in qualities)` 루프는 첫 번째 원소인 `M3U8_AUTO_360`을 먼저 테라박스 서버에 요청합니다.
3. `M3U8_AUTO_360`은 항상 `200 OK`와 `#EXTM3U`를 반환하므로, **첫 번째 반복에서 즉시 `M3U8_AUTO_360` URL을 `return`** 해버립니다. 두 번째 원소인 `M3U8_AUTO_480`이나 `M3U8_AUTO_720`은 **절대 호출조차 되지 않는 데드 코드(Dead Code)** 상태입니다.
4. 심지어 `_resolveStreamUrl`은 이렇게 반환된 360p URL을 `${fsId}_480p`, `${fsId}_720p` 캐시 키에 그대로 저장하고, `PlayerScreen`은 URL에 `api/streaming`이 포함되어 있으니 요청한 화질(480p/720p)로 정상 전환되었다고 착각하여 UI에 `"화질 전환 완료: 720p (고화질)"` 배너를 띄웁니다.

> **참고**: 반면 [`lib/services/baidu_service.dart`](file:///D:/My%20Documents/AI/cloud_media_player/lib/services/baidu_service.dart#L574-L580)는 `q480p`일 때 `['M3U8_AUTO_480', 'M3U8_AUTO_360', ...]`, `q720p`일 때 `['M3U8_AUTO_720', 'M3U8_AUTO_480', 'M3U8_AUTO_360']` 순서로 되어 있으나, 이 역시 720p 실패 시 360p로 몰래 폴백되면서 UI에는 720p로 표시되는 문제가 있습니다.

---

### 원인 2: 테라박스 M3U8 플레이리스트 내부 청크(.ts) 유효성 미검증 및 무음 폴백 문제
설령 배열 순서를 `['M3U8_AUTO_720']`으로 바꾸더라도, 테라박스 서버의 특성이 있습니다:
* 테라박스 `/api/streaming?type=M3U8_AUTO_720` (또는 `480`, `1080`) 호출 시:
  * **경우 A**: 비VIP 계정이나 인코딩 미지원 영상에 대해 JSON(`{"errno": ...}`)을 반환하거나 HTTP 403을 반환.
  * **경우 B**: `#EXTM3U` 플레이리스트 텍스트 자체는 `200 OK`로 내려주지만, 그 안에 에러 태그가 들어있거나 첫 번째 `.ts` 세그먼트 요청 시 `403 Forbidden`으로 차단하는 경우가 존재합니다.
* 또한 사용자가 명시적으로 `720p`를 선택했는데 서버에서 720p가 거부되었을 때, `_fetchHlsStreamUrl` 내부에서 몰래 `M3U8_AUTO_360`을 반환해버리면 사용자는 **"720p로 전환 완료되었다고 뜨는데 화질은 그대로 360p"**인 현상을 또 겪게 됩니다.

---

### 원인 3: `원본 (Direct)` 선택 시 헤더 누락 및 302 리다이렉트 처리 결함
로그(`07:43:07 ~ 07:43:18`)에서 `원본 (Direct)` 전환이 실패한 원인은 **3가지 복합 버그** 때문입니다:

1. **보조 플레이어(`_standbyPlayer`) 생성 시 비동기 프로퍼티(`demuxer-lavf-o`) 경쟁 조건(Race Condition)**:
   * [`PlayerScreen._createConfiguredPlayer()`](file:///D:/My%20Documents/AI/cloud_media_player/lib/ui/screens/player_screen.dart#L129-L137)에서 `_applyPlayerPlatformProperties(player)`를 **`await` 없이** 호출합니다.
   * 그 직후 `_tryHotSwapQuality`에서 `standby.open(Media(playUrl, httpHeaders: headers))`를 호출하면, `_applyPlayerPlatformProperties` 내부의 `await widget.service.getStreamHeaders()`가 나중에 완료되면서 `demuxer-lavf-o` 프로퍼티를 덮어쓰거나, `Media(httpHeaders: ...)`와 충돌을 일으킵니다.
2. **`TeraBoxService._resolveStreamUrl`의 1단계 302 리다이렉트 해석 한계 및 쿠키 유실**:
   * [`TeraBoxService._resolveStreamUrl`](file:///D:/My%20Documents/AI/cloud_media_player/lib/services/terabox_service.dart#L410-L430)은 `dlink`에 대해 **단 1회만** 302 리다이렉트를 추적합니다. 테라박스의 `dlink`(`d.terabox.com/...`)는 종종 2단계 리다이렉트를 거치거나, 리다이렉트된 CDN URL을 `libmpv`가 직접 열 때 `LocalStreamProxy`를 거치지 않으면 Range 요청 및 리다이렉트 과정에서 `Cookie` / `User-Agent` 헤더가 유실되어 연결이 지연/거부됩니다.
3. **`PlayerScreen`에서 TeraBox 원본(`!isHls`)을 `LocalStreamProxy`에서 제외한 문제**:
   * [`PlayerScreen._initAndPlay`](file:///D:/My%20Documents/AI/cloud_media_player/lib/ui/screens/player_screen.dart#L465-L467) 및 [`_switchQuality`](file:///D:/My%20Documents/AI/cloud_media_player/lib/ui/screens/player_screen.dart#L2277-L2279)에서:
     ```dart
     final playUrl = ((isBaiduOrTeraBox && isHls) || isNaver || isMega)
         ? LocalStreamProxy.instance.registerStream(widget.service, widget.item, quality: targetQuality)
         : rawStreamUrl;
     ```
   * `isHls`가 `false`(즉, `원본 (Direct)`)일 때는 `LocalStreamProxy`를 거치지 않고 `libmpv`에게 `rawStreamUrl`을 직접 전달합니다. 이 때문에 `libmpv`가 테라박스 서버와 직접 통신하다가 인증 헤더/리다이렉트 문제로 10초간 멈춘 뒤 타임아웃됩니다.

---

## 4. 코드 수정 방안 (How to Fix)

### 수정 1: `lib/services/terabox_service.dart` — 요청한 화질만 정확히 조회 및 폴백 분리

1. **`_fetchHlsStreamUrl`에서 타겟 화질을 최우선/단독으로 요청**:
   * 사용자가 특정 화질(`q480p`, `q720p`, `q1080p`)을 지정한 경우, 임의로 `M3U8_AUTO_360`을 앞에 두거나 몰래 360p로 덮어쓰지 않고 **요청한 해상도의 M3U8만 시도**하도록 수정합니다.
   * 초기 재생 시(또는 `autoQuality`일 때)에만 고화질 → 저화질 또는 기본 화질 순차 탐색을 수행합니다.
2. **1080p 옵션 추가 지원**:
   * 테라박스는 1080p 영상에 대해 `M3U8_AUTO_1080`도 지원하므로 `getAvailableQualities`에 `VideoQuality.q1080p`를 추가할 수 있습니다.
3. **원본(`dlink`) 리다이렉트 다단계 추적 보강**:
   * 302 리다이렉트가 여러 번 발생할 수 있으므로 최대 3~5회 루프를 돌며 최종 CDN URL을 해석하되, `HEAD` 또는 `Range: bytes=0-0`을 사용하여 본문 다운로드를 방지하고 즉시 `client.close()` 하도록 개선합니다.

#### `lib/services/terabox_service.dart` 수정 예시 코드:
```dart
  /// 지원하는 화질 목록 (HLS 변환 화질 + 원본)
  @override
  Future<List<VideoQuality>> getAvailableQualities(MediaItem item) async {
    return const [
      VideoQuality.q360p,
      VideoQuality.q480p,
      VideoQuality.q720p,
      VideoQuality.q1080p,
      VideoQuality.original,
    ];
  }

  /// 백그라운드 프리페치 시 원본(original)이나 미지원 화질이 불필요한 트래픽을 유발하지 않도록 HLS 화질만 프리페치
  @override
  Future<void> prefetchQualities(MediaItem item, List<VideoQuality> qualities) async {
    for (final q in qualities) {
      if (q.isOriginal) continue; // 원본 dlink는 선택 시점에 해석
      try {
        await _resolveStreamUrl(item, q);
      } catch (_) {}
    }
  }
```

```dart
  Future<String> _resolveStreamUrl(MediaItem item, VideoQuality targetQuality) async {
    await refreshTokensIfNeeded();
    final fsId = _extractFsId(item.id);
    final filePath = _extractPath(item.id);

    if (fsId.isEmpty && filePath.isEmpty) {
      throw Exception('유효하지 않은 TeraBox 파일 ID: ${item.id}');
    }

    final cacheKey = '${fsId.isNotEmpty ? fsId : filePath}_${targetQuality.id}';

    // 캐시 확인
    final cached = _streamUrlCache[cacheKey];
    if (cached != null && DateTime.now().isBefore(cached.expiry)) {
      return cached.url;
    }

    // 1. 비디오 파일이고 원본 요청이 아닐 경우, 요청한 해상도의 HLS(M3U8) 스트림 획득 시도
    if (!targetQuality.isOriginal && !item.isSubtitle && filePath.isNotEmpty && filePath != fsId) {
      final hlsUrl = await _fetchHlsStreamUrl(filePath, fsId, targetQuality);
      if (hlsUrl != null && hlsUrl.isNotEmpty) {
        debugPrint('[TeraBoxService] HLS (${targetQuality.id}) 스트림 URL 획득 성공: $hlsUrl');
        _streamUrlCache[cacheKey] = (
          url: hlsUrl,
          expiry: DateTime.now().add(const Duration(hours: 3)),
        );
        return hlsUrl;
      }
      debugPrint('[TeraBoxService] 요청한 HLS (${targetQuality.id}) 획득 실패 -> 원본(dlink) 또는 대체 화질 폴백');
    }

    // 2. 원본(Direct) 요청이거나 HLS 획득 실패 시 filemetas API로 원본 dlink 획득
    // ... (기존 dlink 획득 로직) ...
```

```dart
  /// /api/streaming 비공식 API로부터 요청한 화질의 HLS 스트림 URL 획득
  Future<String?> _fetchHlsStreamUrl(String filePath, String fsId, [VideoQuality? quality]) async {
    List<String> qualities;
    if (quality != null) {
      if (quality == VideoQuality.q360p) {
        qualities = ['M3U8_AUTO_360'];
      } else if (quality == VideoQuality.q480p) {
        qualities = ['M3U8_AUTO_480']; // 360p를 앞에 두지 않고 480p만 정확히 요청!
      } else if (quality == VideoQuality.q720p) {
        qualities = ['M3U8_AUTO_720']; // 360p를 앞에 두지 않고 720p만 정확히 요청!
      } else if (quality == VideoQuality.q1080p) {
        qualities = ['M3U8_AUTO_1080']; // 1080p만 정확히 요청!
      } else {
        qualities = ['M3U8_AUTO_720', 'M3U8_AUTO_480', 'M3U8_AUTO_360'];
      }
    } else {
      qualities = ['M3U8_AUTO_360'];
    }

    for (final q in qualities) {
      final streamUri = Uri.parse('https://www.terabox.com/api/streaming').replace(
        queryParameters: {
          'app_id': appId,
          'web': '1',
          'channel': 'dubox',
          'clienttype': '0',
          'isplayer': '1',
          'check_blue': '1',
          'type': q,
          'path': filePath,
          if (fsId.isNotEmpty) 'fsid': fsId,
          if (_cachedJsToken != null && _cachedJsToken!.isNotEmpty) 'jsToken': _cachedJsToken!,
        },
      );

      final client = http.Client();
      try {
        final req = http.Request('GET', streamUri)
          ..followRedirects = false
          ..headers.addAll({
            'User-Agent': defaultUserAgent,
            'Cookie': cookieHeader,
            'Referer': 'https://www.terabox.com/',
            'Accept': '*/*',
          });

        final streamedRes = await client.send(req);

        // 1. 302/301 리다이렉트된 Location 헤더가 HLS m3u8 주소인 경우
        if (streamedRes.isRedirect && streamedRes.headers['location'] != null) {
          final location = streamedRes.headers['location']!;
          if (location.isNotEmpty) {
            return location;
          }
        }

        // 2. 200 OK 응답인 경우
        if (streamedRes.statusCode == 200) {
          final bodyBytes = await streamedRes.stream.toBytes();
          final bodyText = utf8.decode(bodyBytes, allowMalformed: true);

          // 유효한 M3U8 플레이리스트이고 세그먼트(#EXTINF)가 실제로 존재하는지 확인
          if (bodyText.contains('#EXTM3U') && bodyText.contains('#EXTINF')) {
            return streamUri.toString();
          }

          // JSON 응답인 경우 (errno 검사)
          try {
            final json = jsonDecode(bodyText);
            if (json is Map) {
              if (json['errno'] != null && json['errno'] != 0) {
                debugPrint('[TeraBoxService] HLS 스트리밍 응답 errno: ${json['errno']} (type: $q)');
                continue;
              }
              final directM3u8 = json['url'] ??
                  json['m3u8'] ??
                  json['m3u8_url'] ??
                  json['streaming_url'] ??
                  json['dlink'];
              if (directM3u8 != null && directM3u8.toString().isNotEmpty) {
                return directM3u8.toString();
              }
            }
          } catch (_) {}

          debugPrint('[TeraBoxService] HLS 응답에 유효한 #EXTM3U 세그먼트 없음 (type: $q, 내용: ${bodyText.take(200)})');
        } else {
          debugPrint('[TeraBoxService] HLS 응답 상태 코드: ${streamedRes.statusCode} (type: $q)');
        }
      } catch (e) {
        debugPrint('[TeraBoxService] HLS 스트리밍 엔드포인트($q) 요청 실패: $e');
      } finally {
        client.close();
      }
    }
    return null;
  }
```

---

### 수정 2: `lib/services/baidu_service.dart` — Baidu 역시 타겟 화질 단독 조회로 수정
[`lib/services/baidu_service.dart`](file:///D:/My%20Documents/AI/cloud_media_player/lib/services/baidu_service.dart#L571-L586)의 `_fetchHlsStreamUrl`에서도 사용자가 `480p`나 `720p`를 선택했을 때 `['M3U8_AUTO_720', 'M3U8_AUTO_480', 'M3U8_AUTO_360']`처럼 하위 화질을 후보에 섞어두면, 720p가 거부되었을 때 360p URL을 반환하면서 UI에는 `720p`로 표시되는 동일한 문제가 발생합니다.
* `quality == VideoQuality.q360p` → `['M3U8_AUTO_360']`
* `quality == VideoQuality.q480p` → `['M3U8_AUTO_480']`
* `quality == VideoQuality.q720p` → `['M3U8_AUTO_720']`
* `quality == VideoQuality.q1080p` → `['M3U8_AUTO_1080']`
로 각각 분리하여 요청한 화질만 정확히 테스트하도록 일치시킵니다.

---

### 수정 3: `lib/ui/screens/player_screen.dart` 및 `lib/services/local_stream_proxy.dart` — 원본(Direct) 재생 및 화질 전환 안정화

1. **`_createConfiguredPlayer`의 비동기 초기화 보장**:
   * `_createConfiguredPlayer()`가 `_applyPlayerPlatformProperties(player)`를 완료하기 전에 `standby.open(...)`이 호출되어 `demuxer-lavf-o` 헤더가 꼬이는 현상을 막기 위해, `_tryHotSwapQuality`에서 `await _applyPlayerPlatformProperties(standby);`를 명시적으로 기다린 후 `standby.open(...)`을 호출합니다.
2. **TeraBox/Baidu 원본(Direct) 스트림도 `LocalStreamProxy` 경유 또는 다중 리다이렉트 지원**:
   * 테라박스와 바이두의 `dlink`(원본 직링크)는 쿠키(`ndus` / `BDUSS`), `User-Agent`, `Referer` 헤더가 필수이며 302 리다이렉트가 수반됩니다.
   * `LocalStreamProxy`에서 일반 MP4 스트림 요청 시 `http.Request`가 리다이렉트를 따라가며 인증 헤더를 유지하도록 처리하거나, `TeraBoxService`에서 최종 CDN URL을 다단계(최대 5회)로 완전히 추적한 뒤 전달하도록 수정합니다.
3. **실제 디코딩된 비디오 해상도(`width x height`) 로그 및 검증 추가**:
   * `_tryHotSwapQuality` 및 `_fallbackSinglePlayerSwitch` 완료 시 `player.state.width`와 `player.state.height`를 확인하여, 실제로 전환된 해상도를 로그 및 배너(예: `"화질 전환 완료: 720p (1280x720)"`)에 표시하면 사용자가 실제 화질 변경 여부를 명확히 확인할 수 있습니다.

#### `lib/ui/screens/player_screen.dart` 수정 예시 코드:
```dart
  Future<bool> _tryHotSwapQuality({
    required String playUrl,
    required Map<String, String> headers,
    required VideoQuality targetQuality,
    required int token,
    required bool isFallbackToOriginal,
  }) async {
    final standby = Player(
      configuration: const PlayerConfiguration(
        bufferSize: 64 * 1024 * 1024,
      ),
    );
    // open() 호출 전에 플랫폼 프로퍼티 설정이 완료되도록 await 보장
    await _applyPlayerPlatformProperties(standby);
    final standbyCtrl = _createConfiguredController(standby);
    // ...
```

```dart
      // 화질 전환 완료 배너에 실제 디코딩 해상도 표시
      final actualW = _player.state.width;
      final actualH = _player.state.height;
      final resInfo = (actualW != null && actualH != null && actualW > 0 && actualH > 0)
          ? ' (${actualW}x$actualH)'
          : '';

      if (isFallbackToOriginal) {
        _showNotificationBanner(
          message: '선택한 화질(${targetQuality.label})을 지원하지 않아 원본$resInfo으로 재생됩니다.',
          icon: Icons.warning_amber_rounded,
          iconColor: Colors.orangeAccent,
          duration: const Duration(seconds: 4),
        );
      } else {
        _showNotificationBanner(
          message: '화질 전환 완료: ${targetQuality.label}$resInfo',
          icon: Icons.check_circle_outline,
          iconColor: Colors.greenAccent,
          duration: const Duration(seconds: 2),
        );
      }
```

---

## 5. 요약 정리

| 구분 | 원인 요약 | 해결 방법 |
| :--- | :--- | :--- |
| **1. 480p / 720p 변경 시 화질 고정** | `TeraBoxService._fetchHlsStreamUrl`에서 480p/720p 선택 시 후보 배열을 `['M3U8_AUTO_360', 'M3U8_AUTO_720']`로 설정하여, 루프 첫 번째인 `360p`가 항상 무조건 반환됨 | 각 해상도 선택 시 해당 해상도(`['M3U8_AUTO_480']`, `['M3U8_AUTO_720']`, `['M3U8_AUTO_1080']`)만 단독으로 요청하도록 수정 |
| **2. 미지원 해상도의 무음 폴백** | 상위 해상도가 실패하거나 빈 플레이리스트를 반환할 때 사용자 안내 없이 360p가 캐싱되거나 성공으로 처리됨 | `#EXTM3U`와 `#EXTINF` 존재 여부를 검증하고, 실패 시 `null`을 반환하여 명확한 폴백 배너가 표시되도록 수정 |
| **3. 원본(Direct) 선택 시 10초 멈춤/실패** | `_createConfiguredPlayer`의 비동기 `setProperty` 경쟁 조건 및 테라박스 `dlink` 다중 302 리다이렉트 미추적 | `standby.open()` 전 `_applyPlayerPlatformProperties`를 `await` 처리하고, `dlink` 302 리다이렉트를 다단계로 추적(`Range: bytes=0-0`)하도록 수정 |
