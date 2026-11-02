import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/media_item.dart';
import '../models/video_quality.dart';
import 'cloud_service_interface.dart';

class BaiduService extends CloudService {
  BaiduService(super.account, {super.onAccountUpdated});

  static const String defaultUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
  // 바이두 PCS / dlink 다운로드 전용 User-Agent (403 Forbidden 방지용)
  static const String pcsUserAgent = 'LogStatistic';
  static const String appId = '250528';

  String? _cachedJsToken;
  DateTime? _jsTokenExpiry;

  // Stream URL 캐시 (fsId -> {url, expiry})
  final Map<String, ({String url, DateTime expiry})> _streamUrlCache = {};

  // pan.baidu.com api/streaming 엔드포인트의 errno -6 (권한 없음) 연속 발생 상태 캐시
  // 연속 2회 이상 발생 시 불필요한 왕복 지연을 방지하고 고속 PCS 엔드포인트로 즉각 우회
  DateTime? _panStreamingUnavailableUntil;

  /// Baidu 쿠키 문자열 정규화
  /// BDUSS 단독 값 또는 'BDUSS=xxx; STOKEN=yyy; ...' 형태 전체 헤더 문자열 지원
  static String normalizeBaiduCookie(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '';

    // 쿠키 쌍들을 파싱
    if (trimmed.contains('=')) {
      String? bduss;
      String? stoken;
      String? baiduid;

      final pairs = trimmed.split(';');
      for (final pair in pairs) {
        final p = pair.trim();
        if (p.isEmpty) continue;
        final eqIdx = p.indexOf('=');
        if (eqIdx > 0) {
          final key = p.substring(0, eqIdx).trim();
          final val = p.substring(eqIdx + 1).trim();
          if (key.toUpperCase() == 'BDUSS') {
            bduss = val;
          } else if (key.toUpperCase() == 'STOKEN') {
            stoken = val;
          } else if (key.toUpperCase() == 'BAIDUID') {
            baiduid = val;
          }
        }
      }

      if (bduss != null && bduss.isNotEmpty) {
        final result = StringBuffer('BDUSS=$bduss');
        if (stoken != null && stoken.isNotEmpty) {
          result.write('; STOKEN=$stoken');
        }
        if (baiduid != null && baiduid.isNotEmpty) {
          result.write('; BAIDUID=$baiduid');
        }
        return result.toString();
      }
    }

    // 콜론 형태 (예: "BDUSS: XXXX")
    final matchColon = RegExp(r'^BDUSS\s*:\s*(.+)$', caseSensitive: false).firstMatch(trimmed);
    if (matchColon != null) {
      return 'BDUSS=${matchColon.group(1)!.trim()}';
    }

    // 단순 토큰 문자열만 들어온 경우
    final cleanToken = trimmed.replaceAll('"', '').replaceAll("'", '');
    return 'BDUSS=$cleanToken';
  }

  /// 쿠키 헤더 문자열 반환
  String get cookieHeader {
    final token = account.accessToken.trim();
    String baseCookie;
    if (token.contains('=')) {
      baseCookie = token;
    } else {
      baseCookie = 'BDUSS=$token';
    }
    // pan.baidu.com 웹 API 인증에 필수적인 PANWEB=1 쿠키 주입
    if (!baseCookie.contains('PANWEB=')) {
      baseCookie = 'PANWEB=1; $baseCookie';
    }
    return baseCookie;
  }

  /// jsToken 획득 및 유효성 확인
  @override
  Future<bool> refreshTokensIfNeeded() async {
    if (account.accessToken.isEmpty) return false;

    if (_cachedJsToken != null &&
        _jsTokenExpiry != null &&
        DateTime.now().isBefore(_jsTokenExpiry!)) {
      return true;
    }

    try {
      final token = await _fetchJsToken();
      if (token != null && token.isNotEmpty) {
        _cachedJsToken = token;
        _jsTokenExpiry = DateTime.now().add(const Duration(hours: 4));
        account.refreshToken = token;
        account.tokenExpiry = _jsTokenExpiry;
        await onAccountUpdated?.call(account);
        return true;
      }
    } catch (e) {
      debugPrint('[BaiduService] jsToken 갱신 시도 오류: $e');
    }

    // 바이두는 jsToken 없이도 BDUSS 쿠키만으로 많은 API가 작동하므로 true 반환
    return account.accessToken.isNotEmpty;
  }

  /// pan.baidu.com 페이지에서 jsToken 파싱 시도
  Future<String?> _fetchJsToken() async {
    final urls = [
      'https://pan.baidu.com/disk/main',
      'https://pan.baidu.com/disk/home',
    ];

    for (final url in urls) {
      try {
        final res = await http.get(
          Uri.parse(url),
          headers: {
            'User-Agent': defaultUserAgent,
            'Cookie': cookieHeader,
            'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
            'Referer': 'https://pan.baidu.com/',
          },
        );

        if (res.statusCode == 200) {
          final html = res.body;

          // 1. fn%28%22TOKEN%22%29
          final mUrlEnc = RegExp(r'fn%28%22([a-zA-Z0-9_]+)%22%29').firstMatch(html);
          if (mUrlEnc != null) {
            return mUrlEnc.group(1);
          }

          // 2. window.jsToken = '...'
          final m1 = RegExp(r'window\.jsToken\s*=\\s*[\x22\x27]([a-zA-Z0-9_]+)[\x22\x27]').firstMatch(html);
          if (m1 != null) {
            return m1.group(1);
          }

          // 3. 'jsToken':'...'
          final m2 = RegExp(r'[\x22\x27]jsToken[\x22\x27]\s*:\s*[\x22\x27]([a-zA-Z0-9_]+)[\x22\x27]').firstMatch(html);
          if (m2 != null) {
            return m2.group(1);
          }

          // 4. fn('...')
          final m3 = RegExp(r'fn\s*\(\s*[\x22\x27]([a-zA-Z0-9_]{32,})[\x22\x27]\s*\)').firstMatch(html);
          if (m3 != null) {
            return m3.group(1);
          }

          // 5. URL 디코딩 후 fn('...')
          try {
            final decodedHtml = Uri.decodeComponent(html);
            final mDec = RegExp(r'fn\s*\(\s*[\x22\x27]([a-zA-Z0-9_]{32,})[\x22\x27]\s*\)').firstMatch(decodedHtml);
            if (mDec != null) {
              return mDec.group(1);
            }
          } catch (_) {}
        }
      } catch (e) {
        debugPrint('[BaiduService] $url 접속 오류: $e');
      }
    }
    return null;
  }

  /// 계정 유효성 검증 및 유저 정보 확인 (AddAccountDialog 검증용)
  Future<({bool isValid, String? username, String? error})> verifyAccount() async {
    await refreshTokensIfNeeded();

    try {
      // 1차 시도: pan.baidu.com xpan uinfo API
      final uri = Uri.parse('https://pan.baidu.com/rest/2.0/xpan/nas?method=uinfo');
      final res = await http.get(
        uri,
        headers: {
          'User-Agent': defaultUserAgent,
          'Cookie': cookieHeader,
          'Referer': 'https://pan.baidu.com/',
        },
      );

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (data is Map && (data['errno'] == 0 || data['errno'] == null)) {
          final uname = data['baidu_name'] ??
              data['netdisk_name'] ??
              data['username'] ??
              'Baidu User';
          return (isValid: true, username: uname.toString(), error: null);
        }
      }

      // 2차 시도: /api/list 루트 디렉터리 호출로 계정 유효성 검증
      final listUri = Uri.parse('https://pan.baidu.com/api/list').replace(
        queryParameters: {
          'app_id': appId,
          'web': '1',
          'channel': 'chunlei',
          'clienttype': '0',
          if (_cachedJsToken != null && _cachedJsToken!.isNotEmpty) 'jsToken': _cachedJsToken!,
          'dir': '/',
          'num': '1',
          'page': '1',
        },
      );

      final listRes = await http.get(
        listUri,
        headers: {
          'User-Agent': defaultUserAgent,
          'Cookie': cookieHeader,
          'Referer': 'https://pan.baidu.com/',
        },
      );

      if (listRes.statusCode == 200) {
        final data = jsonDecode(listRes.body);
        if (data is Map && data['errno'] == 0) {
          return (isValid: true, username: 'Baidu User', error: null);
        }
      }

      return (
        isValid: false,
        username: null,
        error: '바이두 계정 인증 응답 오류입니다. BDUSS 쿠키를 다시 확인해 주세요.'
      );
    } catch (e) {
      return (
        isValid: false,
        username: null,
        error: '연결 실패: $e'
      );
    }
  }

  /// 폴더 내 항목 조회
  @override
  Future<List<MediaItem>> listItems({String? folderId}) async {
    await refreshTokensIfNeeded();

    final dirPath = (folderId == null || folderId.isEmpty || folderId == 'root') ? '/' : folderId;

    final queryParams = {
      'app_id': appId,
      'web': '1',
      'channel': 'chunlei',
      'clienttype': '0',
      if (_cachedJsToken != null && _cachedJsToken!.isNotEmpty) 'jsToken': _cachedJsToken!,
      'dir': dirPath,
      'num': '1000',
      'page': '1',
      'order': 'name',
      'desc': '0',
    };

    final uri = Uri.parse('https://pan.baidu.com/api/list').replace(
      queryParameters: queryParams,
    );

    final res = await http.get(
      uri,
      headers: {
        'User-Agent': defaultUserAgent,
        'Cookie': cookieHeader,
        'Referer': 'https://pan.baidu.com/',
      },
    );

    if (res.statusCode != 200) {
      throw Exception('Baidu 파일 목록 조회 실패 (${res.statusCode}): ${res.body}');
    }

    final data = jsonDecode(res.body);
    if (data is! Map || data['errno'] != 0) {
      final errno = data is Map ? data['errno'] : 'unknown';
      throw Exception('Baidu API 오류 (errno: $errno)');
    }

    final list = data['list'] as List<dynamic>? ?? [];

    return list.map((item) {
      final isDir = (item['isdir'] == 1 || item['isdir'] == '1');
      final path = item['path'] as String? ?? '';
      final fsId = item['fs_id']?.toString() ?? '';
      final name = item['server_filename'] as String? ?? (path.split('/').last);
      final size = item['size'] != null ? int.tryParse(item['size'].toString()) : null;

      DateTime? modifiedTime;
      if (item['server_mtime'] != null) {
        final sec = int.tryParse(item['server_mtime'].toString());
        if (sec != null && sec > 0) {
          modifiedTime = DateTime.fromMillisecondsSinceEpoch(sec * 1000);
        }
      }

      String? thumbnail;
      final thumbs = item['thumbs'];
      if (thumbs is Map) {
        thumbnail = thumbs['url3'] as String? ?? thumbs['url2'] as String? ?? thumbs['url1'] as String?;
      }

      final itemId = isDir ? path : '$fsId|$path';

      return MediaItem(
        id: itemId,
        name: name,
        parentId: dirPath,
        isFolder: isDir,
        size: size,
        modifiedTime: modifiedTime,
        thumbnailUrl: thumbnail,
      );
    }).toList();
  }

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

  /// 무료 계정 대역폭을 고려해 초기 재생 시 360p(빠른 로딩) 권장
  @override
  VideoQuality getDefaultPlaybackQuality() => VideoQuality.q360p;

  /// 다른 화질 스트림 URL을 백그라운드에서 사전 조회/캐싱합니다.
  @override
  Future<void> prefetchQualities(MediaItem item, List<VideoQuality> qualities) async {
    for (final q in qualities) {
      if (q.isOriginal) continue;
      try {
        await _resolveStreamUrl(item, q);
      } catch (_) {}
    }
  }

  /// 특정 화질 HLS 또는 원본 스트리밍 URL 반환
  @override
  Future<String> getStreamUrlWithQuality(MediaItem item, VideoQuality quality) async {
    return _resolveStreamUrl(item, quality);
  }

  /// 기본 미디어 스트리밍 URL 반환 (기본 권장 화질 적용)
  @override
  Future<String> getStreamUrl(MediaItem item) async {
    return _resolveStreamUrl(item, getDefaultPlaybackQuality());
  }

  Future<String> _resolveStreamUrl(MediaItem item, VideoQuality targetQuality) async {
    await refreshTokensIfNeeded();
    final fsId = _extractFsId(item.id);
    final filePath = _extractPath(item.id);

    if (fsId.isEmpty && filePath.isEmpty) {
      throw Exception('유효하지 않은 Baidu 파일 ID: ${item.id}');
    }

    final cacheKey = '${fsId.isNotEmpty ? fsId : filePath}_${targetQuality.id}';

    // 캐시 확인
    final cached = _streamUrlCache[cacheKey];
    if (cached != null && DateTime.now().isBefore(cached.expiry)) {
      return cached.url;
    }

    // 1. 비디오 파일이고 원본 요청이 아닐 경우, 바이두 HLS(M3U8) 스트리밍 시도 (자막 파일은 직링크 다운로드)
    if (!targetQuality.isOriginal && !item.isSubtitle && filePath.isNotEmpty && filePath != fsId) {
      final hlsUrl = await _fetchHlsStreamUrl(filePath, fsId, targetQuality);
      if (hlsUrl != null && hlsUrl.isNotEmpty) {
        debugPrint('[BaiduService] HLS (${targetQuality.id}) 스트림 URL 획득 성공: $hlsUrl');
        _streamUrlCache[cacheKey] = (
          url: hlsUrl,
          expiry: DateTime.now().add(const Duration(hours: 3)),
        );
        return hlsUrl;
      }
    }

    String? directUrl;

    // 2. PCS locatedownload API 시도 (안정적인 고속 직링크)
    if (filePath.isNotEmpty) {
      try {
        final pcsUri = Uri.parse(
          'https://d.pcs.baidu.com/rest/2.0/pcs/file?method=locatedownload&app_id=$appId&path=${Uri.encodeComponent(filePath)}&ver=2.0&dtype=1&esl=1',
        );
        final pcsRes = await http.get(
          pcsUri,
          headers: {
            'User-Agent': pcsUserAgent,
            'Cookie': cookieHeader,
            'Referer': 'https://pan.baidu.com/',
          },
        );

        if (pcsRes.statusCode == 200) {
          final data = jsonDecode(pcsRes.body);
          if (data is Map) {
            final urls = data['urls'];
            if (urls is List && urls.isNotEmpty && urls[0] is Map) {
              directUrl = urls[0]['url'] as String?;
            } else if (data['server'] != null && data['path'] != null) {
              directUrl = '${data['server']}${data['path']}';
            }
          }
        }
      } catch (e) {
        debugPrint('[BaiduService] PCS locatedownload 시도 실패: $e');
      }
    }

    // 3. pan.baidu.com /api/filemetas API 시도 (dlink 추출)
    if ((directUrl == null || directUrl.isEmpty) && fsId.isNotEmpty) {
      try {
        final metaUri = Uri.parse('https://pan.baidu.com/api/filemetas').replace(
          queryParameters: {
            'app_id': appId,
            'web': '1',
            'channel': 'chunlei',
            'clienttype': '0',
            if (_cachedJsToken != null && _cachedJsToken!.isNotEmpty) 'jsToken': _cachedJsToken!,
            'fsids': '[$fsId]',
            'dlink': '1',
          },
        );

        final metaRes = await http.get(
          metaUri,
          headers: {
            'User-Agent': defaultUserAgent,
            'Cookie': cookieHeader,
            'Referer': 'https://pan.baidu.com/',
          },
        );

        if (metaRes.statusCode == 200) {
          final data = jsonDecode(metaRes.body);
          if (data is Map && data['info'] is List && (data['info'] as List).isNotEmpty) {
            final info = (data['info'] as List).first;
            directUrl = info['dlink'] as String?;
          }
        }
      } catch (e) {
        debugPrint('[BaiduService] filemetas dlink 시도 실패: $e');
      }
    }

    // 4. 폴백: /api/download API
    if (directUrl == null || directUrl.isEmpty) {
      if (fsId.isNotEmpty) {
        directUrl = 'https://pan.baidu.com/api/download?app_id=$appId&web=1&channel=chunlei&clienttype=0&jsToken=${_cachedJsToken ?? ""}&fidlist=[$fsId]';
      } else {
        throw Exception('Baidu 파일 스트리밍 URL 생성에 실패했습니다.');
      }
    }

    // 5. 302 리다이렉트 최종 CDN URL 해석 (Pre-resolve)
    String finalStreamUrl = directUrl;
    try {
      final client = http.Client();
      final request = http.Request('GET', Uri.parse(directUrl))
        ..followRedirects = false
        ..headers.addAll({
          'User-Agent': defaultUserAgent,
          'Cookie': cookieHeader,
          'Referer': 'https://pan.baidu.com/',
        });

      final response = await client.send(request);
      if (response.isRedirect && response.headers['location'] != null) {
        finalStreamUrl = response.headers['location']!;
        debugPrint('[BaiduService] 302 리다이렉트 CDN URL 해석 성공');
      }
      client.close();
    } catch (e) {
      debugPrint('[BaiduService] 302 사전 해석 오류 (원래 directUrl 사용): $e');
    }

    // 캐시에 3시간 저장
    _streamUrlCache[cacheKey] = (
      url: finalStreamUrl,
      expiry: DateTime.now().add(const Duration(hours: 3)),
    );

    return finalStreamUrl;
  }

  /// 자막 및 파일 다운로드 시 다중 User-Agent 및 엔드포인트 폴백 지원
  @override
  Future<Uint8List> downloadBytes(MediaItem item) async {
    await refreshTokensIfNeeded();
    final fsId = _extractFsId(item.id);
    final filePath = _extractPath(item.id);

    // 1. 후보 스트림 URL 목록 수집
    final candidateUrls = <String>[];
    if (filePath.isNotEmpty) {
      candidateUrls.add(
        'https://d.pcs.baidu.com/rest/2.0/pcs/file?method=download&app_id=$appId&path=${Uri.encodeComponent(filePath)}',
      );
    }
    if (fsId.isNotEmpty) {
      candidateUrls.add(
        'https://pan.baidu.com/api/download?app_id=$appId&web=1&channel=chunlei&clienttype=0&jsToken=${_cachedJsToken ?? ""}&fidlist=[$fsId]',
      );
    }
    // 자막이 아닌 일반 미디어인 경우에만 추가 폴백으로 getStreamUrl 시도 (불필요한 HLS 변환 및 302 리다이렉트 지연 방지)
    if (!item.isSubtitle) {
      try {
        final streamUrl = await getStreamUrl(item);
        if (streamUrl.isNotEmpty && !candidateUrls.contains(streamUrl)) {
          candidateUrls.add(streamUrl);
        }
      } catch (_) {}
    }

    // 2. 다중 헤더 및 URL 조합으로 다운로드 시도
    final userAgents = [
      defaultUserAgent,
      pcsUserAgent,
      'netdisk;12.1.2;android;android-android;12;SM-A908N',
    ];

    for (final url in candidateUrls) {
      for (final ua in userAgents) {
        try {
          final res = await http.get(
            Uri.parse(url),
            headers: {
              'User-Agent': ua,
              'Cookie': cookieHeader,
              'Referer': 'https://pan.baidu.com/',
              'Accept': '*/*',
            },
          );

          if (res.statusCode == 200 && res.bodyBytes.isNotEmpty) {
            final sample = String.fromCharCodes(res.bodyBytes.take(100)).trim().toLowerCase();
            // HTML 에러 또는 JSON 에러가 아닐 때 성공
            if (!sample.contains('<!doctype') && !sample.contains('<html') && !(sample.startsWith('{') && sample.contains('errno'))) {
              debugPrint('[BaiduService] 자막/파일 다운로드 성공: ${item.name} (${res.bodyBytes.length} bytes, UA: $ua)');
              return res.bodyBytes;
            }
          }
        } catch (_) {}
      }
    }

    throw Exception('Baidu 파일 다운로드 실패: 모든 엔드포인트 거부 (403)');
  }

  /// /api/streaming 또는 PCS streaming API로부터 HLS 스트림 URL 획득 시도
  Future<String?> _fetchHlsStreamUrl(String filePath, String fsId, [VideoQuality? quality]) async {
    List<String> qualities;
    if (quality != null) {
      if (quality == VideoQuality.q360p) {
        qualities = ['M3U8_AUTO_360'];
      } else if (quality == VideoQuality.q480p) {
        qualities = ['M3U8_AUTO_480'];
      } else if (quality == VideoQuality.q720p) {
        qualities = ['M3U8_AUTO_720'];
      } else if (quality == VideoQuality.q1080p) {
        qualities = ['M3U8_AUTO_1080'];
      } else {
        qualities = ['M3U8_AUTO_360'];
      }
    } else {
      qualities = ['M3U8_AUTO_360'];
    }

    // 1차 우선: PCS REST streaming API 시도 (BDUSS 전용 고속 엔드포인트 - errno -6 왕복 지연 13초 방지)
    for (final q in qualities) {
      final pcsStreamingUri = Uri.parse(
        'https://d.pcs.baidu.com/rest/2.0/pcs/file?method=streaming&app_id=$appId&path=${Uri.encodeComponent(filePath)}&type=$q',
      );

      final client = http.Client();
      try {
        final req = http.Request('GET', pcsStreamingUri)
          ..followRedirects = false
          ..headers.addAll({
            'User-Agent': pcsUserAgent,
            'Cookie': cookieHeader,
          });

        final streamedRes = await client.send(req).timeout(const Duration(seconds: 7));

        if (streamedRes.isRedirect && streamedRes.headers['location'] != null) {
          final location = streamedRes.headers['location']!;
          if (location.isNotEmpty) {
            debugPrint('[BaiduService] PCS HLS 302 발견: $location');
            return location;
          }
        }

        if (streamedRes.statusCode == 200) {
          final bodyBytes = await streamedRes.stream.toBytes().timeout(const Duration(seconds: 7));
          final bodyText = utf8.decode(bodyBytes, allowMalformed: true);
          if (bodyText.contains('#EXTM3U')) {
            debugPrint('[BaiduService] PCS HLS 플레이리스트 획득 성공 ($q)');
            return pcsStreamingUri.toString();
          }
        }
      } catch (e) {
        debugPrint('[BaiduService] PCS HLS 요청 실패 ($q): $e');
      } finally {
        client.close();
      }
    }

    // 2차 폴백: pan.baidu.com api/streaming 시도
    final isPanStreamingTemporarilyDisabled = _panStreamingUnavailableUntil != null &&
        DateTime.now().isBefore(_panStreamingUnavailableUntil!);

    if (!isPanStreamingTemporarilyDisabled) {
      final clientConfigs = [
        {'clienttype': '0', 'channel': 'chunlei', 'web': '1'},
        {'clienttype': '1', 'channel': 'baiduyun', 'web': '0'},
      ];

      for (final cfg in clientConfigs) {
        for (final q in qualities) {
          final query = <String, String>{
            'app_id': appId,
            'web': cfg['web']!,
            'channel': cfg['channel']!,
            'clienttype': cfg['clienttype']!,
            'isplayer': '1',
            'check_blue': '1',
            'type': q,
            'path': filePath,
            'vip': '0',
            if (fsId.isNotEmpty) 'fsid': fsId,
            if (cfg['clienttype'] == '0' && _cachedJsToken != null && _cachedJsToken!.isNotEmpty)
              'jsToken': _cachedJsToken!,
          };

          final streamUri = Uri.parse('https://pan.baidu.com/api/streaming').replace(
            queryParameters: query,
          );

          final client = http.Client();
          try {
            final req = http.Request('GET', streamUri)
              ..followRedirects = false
              ..headers.addAll({
                'User-Agent': defaultUserAgent,
                'Cookie': cookieHeader,
                'Referer': 'https://pan.baidu.com/disk/main',
                'Accept': '*/*',
              });

            final streamedRes = await client.send(req).timeout(const Duration(seconds: 6));

            if (streamedRes.isRedirect && streamedRes.headers['location'] != null) {
              final location = streamedRes.headers['location']!;
              if (location.isNotEmpty) {
                return location;
              }
            }

            if (streamedRes.statusCode == 200) {
              final bodyBytes = await streamedRes.stream.toBytes().timeout(const Duration(seconds: 6));
              final bodyText = utf8.decode(bodyBytes, allowMalformed: true);

              if (bodyText.contains('#EXTM3U')) {
                return streamUri.toString();
              }

              try {
                final json = jsonDecode(bodyText);
                if (json is Map) {
                  if (json['errno'] != null && json['errno'] != 0) {
                    debugPrint('[BaiduService] HLS 응답 errno: ${json['errno']} (type: $q, client: ${cfg['clienttype']}, body: $bodyText)');
                    if (json['errno'] == -6) {
                      _panStreamingUnavailableUntil = DateTime.now().add(const Duration(minutes: 30));
                      debugPrint('[BaiduService] errno -6 감지: 향후 30분간 PCS 엔드포인트로 즉시 우회');
                    }
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
            }
          } catch (e) {
            debugPrint('[BaiduService] HLS 스트리밍 엔드포인트($q) 요청 실패: $e');
          } finally {
            client.close();
          }

          if (_panStreamingUnavailableUntil != null && DateTime.now().isBefore(_panStreamingUnavailableUntil!)) {
            break;
          }
        }

        if (_panStreamingUnavailableUntil != null && DateTime.now().isBefore(_panStreamingUnavailableUntil!)) {
          break;
        }
      }
    }

    return null;
  }

  @override
  Future<Map<String, String>> getStreamHeaders() async {
    return {
      'User-Agent': pcsUserAgent, // 'LogStatistic'
      'Cookie': cookieHeader,
      'Referer': 'https://pan.baidu.com/',
    };
  }

  @override
  Future<String?> getThumbnailUrl(MediaItem item) async {
    return item.thumbnailUrl;
  }

  /// 파일/폴더 이름 변경
  @override
  Future<bool> renameItem(MediaItem item, String newName) async {
    await refreshTokensIfNeeded();
    final path = _extractPath(item.id);

    final uri = Uri.parse('https://pan.baidu.com/api/filemanager').replace(
      queryParameters: {
        'opera': 'rename',
        'async': '0',
        'onnest': 'fail',
        'app_id': appId,
        'web': '1',
        'channel': 'chunlei',
        'clienttype': '0',
        if (_cachedJsToken != null && _cachedJsToken!.isNotEmpty) 'jsToken': _cachedJsToken!,
      },
    );

    final filelist = jsonEncode([
      {'path': path, 'newname': newName}
    ]);

    final res = await http.post(
      uri,
      headers: {
        'User-Agent': defaultUserAgent,
        'Cookie': cookieHeader,
        'Referer': 'https://pan.baidu.com/',
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: {'filelist': filelist},
    );

    if (res.statusCode == 200) {
      final data = jsonDecode(res.body);
      return data is Map && data['errno'] == 0;
    }
    return false;
  }

  /// 파일/폴더 삭제
  @override
  Future<bool> deleteItem(MediaItem item) async {
    await refreshTokensIfNeeded();
    final path = _extractPath(item.id);

    final uri = Uri.parse('https://pan.baidu.com/api/filemanager').replace(
      queryParameters: {
        'opera': 'delete',
        'async': '0',
        'onnest': 'fail',
        'app_id': appId,
        'web': '1',
        'channel': 'chunlei',
        'clienttype': '0',
        if (_cachedJsToken != null && _cachedJsToken!.isNotEmpty) 'jsToken': _cachedJsToken!,
      },
    );

    final filelist = jsonEncode([path]);

    final res = await http.post(
      uri,
      headers: {
        'User-Agent': defaultUserAgent,
        'Cookie': cookieHeader,
        'Referer': 'https://pan.baidu.com/',
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: {'filelist': filelist},
    );

    if (res.statusCode == 200) {
      final data = jsonDecode(res.body);
      return data is Map && data['errno'] == 0;
    }
    return false;
  }

  /// 새 폴더 생성
  @override
  Future<bool> createFolder(String folderName, {String? parentFolderId}) async {
    await refreshTokensIfNeeded();
    final parentPath = (parentFolderId == null || parentFolderId.isEmpty || parentFolderId == 'root') ? '/' : parentFolderId;
    final fullPath = parentPath.endsWith('/') ? '$parentPath$folderName' : '$parentPath/$folderName';

    final uri = Uri.parse('https://pan.baidu.com/api/create').replace(
      queryParameters: {
        'app_id': appId,
        'web': '1',
        'channel': 'chunlei',
        'clienttype': '0',
        if (_cachedJsToken != null && _cachedJsToken!.isNotEmpty) 'jsToken': _cachedJsToken!,
      },
    );

    final res = await http.post(
      uri,
      headers: {
        'User-Agent': defaultUserAgent,
        'Cookie': cookieHeader,
        'Referer': 'https://pan.baidu.com/',
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: {
        'path': fullPath,
        'isdir': '1',
        'size': '',
        'block_list': '[]',
      },
    );

    if (res.statusCode == 200) {
      final data = jsonDecode(res.body);
      return data is Map && data['errno'] == 0;
    }
    return false;
  }

  /// 파일/폴더 이동
  @override
  Future<bool> moveItem(MediaItem item, String targetFolderId, {String? newName, bool overwrite = false}) async {
    await refreshTokensIfNeeded();
    final srcPath = _extractPath(item.id);
    final targetDest = (targetFolderId.isEmpty || targetFolderId == 'root') ? '/' : targetFolderId;

    final uri = Uri.parse('https://pan.baidu.com/api/filemanager').replace(
      queryParameters: {
        'opera': 'move',
        'async': '0',
        'onnest': 'fail',
        'app_id': appId,
        'web': '1',
        'channel': 'chunlei',
        'clienttype': '0',
        if (_cachedJsToken != null && _cachedJsToken!.isNotEmpty) 'jsToken': _cachedJsToken!,
      },
    );

    final filelist = jsonEncode([
      {
        'path': srcPath,
        'dest': targetDest,
        'newname': newName ?? item.name,
        'ondup': overwrite ? 'overwrite' : 'newcopy',
      }
    ]);

    final res = await http.post(
      uri,
      headers: {
        'User-Agent': defaultUserAgent,
        'Cookie': cookieHeader,
        'Referer': 'https://pan.baidu.com/',
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: {'filelist': filelist},
    );

    if (res.statusCode == 200) {
      final data = jsonDecode(res.body);
      return data is Map && data['errno'] == 0;
    }
    return false;
  }

  /// 파일/폴더 복사
  @override
  Future<bool> copyItem(MediaItem item, String targetFolderId, {String? newName, bool overwrite = false}) async {
    await refreshTokensIfNeeded();
    final srcPath = _extractPath(item.id);
    final targetDest = (targetFolderId.isEmpty || targetFolderId == 'root') ? '/' : targetFolderId;

    final uri = Uri.parse('https://pan.baidu.com/api/filemanager').replace(
      queryParameters: {
        'opera': 'copy',
        'async': '0',
        'onnest': 'fail',
        'app_id': appId,
        'web': '1',
        'channel': 'chunlei',
        'clienttype': '0',
        if (_cachedJsToken != null && _cachedJsToken!.isNotEmpty) 'jsToken': _cachedJsToken!,
      },
    );

    final filelist = jsonEncode([
      {
        'path': srcPath,
        'dest': targetDest,
        'newname': newName ?? item.name,
        'ondup': overwrite ? 'overwrite' : 'newcopy',
      }
    ]);

    final res = await http.post(
      uri,
      headers: {
        'User-Agent': defaultUserAgent,
        'Cookie': cookieHeader,
        'Referer': 'https://pan.baidu.com/',
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: {'filelist': filelist},
    );

    if (res.statusCode == 200) {
      final data = jsonDecode(res.body);
      return data is Map && data['errno'] == 0;
    }
    return false;
  }

  String _extractFsId(String id) {
    if (id.contains('|')) {
      return id.split('|').first;
    }
    return id;
  }

  String _extractPath(String id) {
    if (id.contains('|')) {
      final parts = id.split('|');
      return parts.sublist(1).join('|');
    }
    return id;
  }
}
