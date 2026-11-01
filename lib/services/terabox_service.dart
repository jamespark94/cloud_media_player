import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/media_item.dart';
import '../models/video_quality.dart';
import 'cloud_service_interface.dart';

class TeraBoxService extends CloudService {
  TeraBoxService(super.account, {super.onAccountUpdated});

  static const String defaultUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
  static const String appId = '250528';

  String? _cachedJsToken;
  DateTime? _jsTokenExpiry;

  // Stream URL 캐시 (fsId -> {url, expiry})
  final Map<String, ({String url, DateTime expiry})> _streamUrlCache = {};

  /// ndus 쿠키 문자열 정규화 (전체 Cookie 문자열 또는 단독 ndus 값 지원)
  static String normalizeNdusCookie(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '';

    // "ndus=XXXX; ..." 패턴 검색
    final match = RegExp(r'(?:^|;\s*)ndus=([^;]+)').firstMatch(trimmed);
    if (match != null) {
      return match.group(1)!.trim();
    }
    // "ndus: XXXX" 형태 처리
    final matchColon = RegExp(r'^ndus\s*:\s*(.+)$', caseSensitive: false).firstMatch(trimmed);
    if (matchColon != null) {
      return matchColon.group(1)!.trim();
    }
    // 단순 토큰 값 그대로 반환 (따옴표 제거)
    return trimmed.replaceAll('"', '').replaceAll("'", '');
  }

  /// 쿠키 헤더 문자열 반환
  String get cookieHeader => 'ndus=${account.accessToken.trim()}';

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
      debugPrint('[TeraBoxService] jsToken 갱신 실패: $e');
    }
    return false;
  }

  /// www.terabox.com/main 페이지에서 jsToken 파싱
  Future<String?> _fetchJsToken() async {
    final urls = [
      'https://www.terabox.com/main',
      'https://www.1024terabox.com/main',
    ];

    for (final url in urls) {
      try {
        final res = await http.get(
          Uri.parse(url),
          headers: {
            'User-Agent': defaultUserAgent,
            'Cookie': cookieHeader,
            'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
            'Referer': 'https://www.terabox.com/',
          },
        );

        if (res.statusCode == 200) {
          final html = res.body;

          // 1. URL 인코딩된 fn 난독화 형태: fn%28%22TOKEN%22%29 (최신 테라박스 규격)
          final mUrlEnc = RegExp(r'fn%28%22([a-zA-Z0-9_]+)%22%29').firstMatch(html);
          if (mUrlEnc != null) {
            return mUrlEnc.group(1);
          }

          // 2. window.jsToken = '...' 패턴
          final m1 = RegExp(r'window\\.jsToken\\s*=\\s*[\x22\x27]([a-zA-Z0-9_]+)[\x22\x27]').firstMatch(html);
          if (m1 != null) {
            return m1.group(1);
          }

          // 3. 'jsToken':'...' 패턴
          final m2 = RegExp(r'[\x22\x27]jsToken[\x22\x27]\\s*:\\s*[\x22\x27]([a-zA-Z0-9_]+)[\x22\x27]').firstMatch(html);
          if (m2 != null) {
            return m2.group(1);
          }

          // 4. fn('...') 일반 난독화 함수 호출 내 토큰 패턴
          final m3 = RegExp(r'fn\\s*\\(\\s*[\x22\x27]([a-zA-Z0-9_]{32,})[\x22\x27]\\s*\\)').firstMatch(html);
          if (m3 != null) {
            return m3.group(1);
          }

          // 5. URL 디코딩 후 fn('...') 추출
          try {
            final decodedHtml = Uri.decodeComponent(html);
            final mDec = RegExp(r'fn\\s*\\(\\s*[\x22\x27]([a-zA-Z0-9_]{32,})[\x22\x27]\\s*\\)').firstMatch(decodedHtml);
            if (mDec != null) {
              return mDec.group(1);
            }
          } catch (_) {}
        }
      } catch (e) {
        debugPrint('[TeraBoxService] $url 접속 오류: $e');
      }
    }
    return null;
  }

  /// 계정 유효성 검증 및 유저 정보 확인 (AddAccountDialog 검증용)
  Future<({bool isValid, String? username, String? error})> verifyAccount() async {
    final tokenOk = await refreshTokensIfNeeded();
    if (!tokenOk) {
      return (
        isValid: false,
        username: null,
        error: 'ndus 쿠키가 올바르지 않거나 만료되었습니다. 다시 확인해 주세요.'
      );
    }

    try {
      final uri = Uri.parse(
        'https://www.terabox.com/api/user/getinfo?app_id=$appId&web=1&channel=dubox&clienttype=0&jsToken=${_cachedJsToken ?? ""}',
      );
      final res = await http.get(
        uri,
        headers: {
          'User-Agent': defaultUserAgent,
          'Cookie': cookieHeader,
          'Referer': 'https://www.terabox.com/',
        },
      );

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (data is Map && (data['errno'] == 0 || data['errno'] == null)) {
          final uname = data['records']?['uname'] ??
              data['records']?['user_name'] ??
              data['username'] ??
              'TeraBox User';
          return (isValid: true, username: uname.toString(), error: null);
        }
      }

      // getinfo 실패 시에도 /api/list 호출 가능 여부로 2차 검증
      final listRes = await http.get(
        Uri.parse(
          'https://www.terabox.com/api/list?app_id=$appId&web=1&channel=dubox&clienttype=0&jsToken=${_cachedJsToken ?? ""}&dir=%2F&num=1&page=1',
        ),
        headers: {
          'User-Agent': defaultUserAgent,
          'Cookie': cookieHeader,
          'Referer': 'https://www.terabox.com/',
        },
      );
      if (listRes.statusCode == 200) {
        final data = jsonDecode(listRes.body);
        if (data is Map && data['errno'] == 0) {
          return (isValid: true, username: 'TeraBox User', error: null);
        }
      }

      return (
        isValid: false,
        username: null,
        error: '테라박스 계정 인증 응답 오류입니다. 쿠키를 다시 확인해 주세요.'
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

    // folderId는 폴더의 실제 경로 (루트는 '/')
    final dirPath = (folderId == null || folderId.isEmpty || folderId == 'root') ? '/' : folderId;

    final uri = Uri.parse('https://www.terabox.com/api/list').replace(
      queryParameters: {
        'app_id': appId,
        'web': '1',
        'channel': 'dubox',
        'clienttype': '0',
        'jsToken': _cachedJsToken ?? '',
        'dir': dirPath,
        'num': '1000',
        'page': '1',
        'order': 'name',
        'desc': '0',
      },
    );

    final res = await http.get(
      uri,
      headers: {
        'User-Agent': defaultUserAgent,
        'Cookie': cookieHeader,
        'Referer': 'https://www.terabox.com/',
      },
    );

    if (res.statusCode != 200) {
      throw Exception('TeraBox 파일 목록 조회 실패 (${res.statusCode}): ${res.body}');
    }

    final data = jsonDecode(res.body);
    if (data is! Map || data['errno'] != 0) {
      final errno = data is Map ? data['errno'] : 'unknown';
      throw Exception('TeraBox API 오류 (errno: $errno)');
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

      // 폴더는 ID를 path 그대로 사용 (하위 탐색 용이)
      // 파일은 fsId와 path를 결합하여 인코딩 (스트리밍 및 자막 매칭용)
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
      throw Exception('유효하지 않은 TeraBox 파일 ID: ${item.id}');
    }

    final cacheKey = '${fsId.isNotEmpty ? fsId : filePath}_${targetQuality.id}';

    // 캐시 확인
    final cached = _streamUrlCache[cacheKey];
    if (cached != null && DateTime.now().isBefore(cached.expiry)) {
      return cached.url;
    }

    // 1. 비디오 파일이고 원본 요청이 아닐 경우, /api/streaming 비공식 API로 HLS(M3U8) 스트림 URL 우선 획득 시도
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
    }

    // 2. HLS 획득 불가 시 filemetas API로 원본 dlink 획득 (폴백)
    // 1. filemetas API로 dlink 획득 (fsids 및 target 동시 대응)
    final metaUri = Uri.parse('https://www.terabox.com/api/filemetas').replace(
      queryParameters: {
        'app_id': appId,
        'web': '1',
        'channel': 'dubox',
        'clienttype': '0',
        'jsToken': _cachedJsToken ?? '',
        'fsids': '["$fsId"]',
        'dlink': '1',
      },
    );

    final res = await http.get(
      metaUri,
      headers: {
        'User-Agent': defaultUserAgent,
        'Cookie': cookieHeader,
        'Referer': 'https://www.terabox.com/',
      },
    );

    String? dlink;
    if (res.statusCode == 200) {
      final data = jsonDecode(res.body);
      if (data is Map && data['info'] is List && (data['info'] as List).isNotEmpty) {
        final info = (data['info'] as List).first;
        dlink = info['dlink'] as String?;
      }
    }

    if (dlink == null || dlink.isEmpty) {
      // 2. target 기반 2차 시도
      final targetUri = Uri.parse('https://www.terabox.com/api/filemetas').replace(
        queryParameters: {
          'app_id': appId,
          'web': '1',
          'channel': 'dubox',
          'clienttype': '0',
          'jsToken': _cachedJsToken ?? '',
          'target': '["$fsId"]',
          'dlink': '1',
        },
      );
      final targetRes = await http.get(targetUri, headers: {
        'User-Agent': defaultUserAgent,
        'Cookie': cookieHeader,
        'Referer': 'https://www.terabox.com/',
      });
      if (targetRes.statusCode == 200) {
        final data = jsonDecode(targetRes.body);
        if (data is Map && data['info'] is List && (data['info'] as List).isNotEmpty) {
          final info = (data['info'] as List).first;
          dlink = info['dlink'] as String?;
        }
      }
    }

    if (dlink == null || dlink.isEmpty) {
      // 3. 다운로드 API 폴백 시도 (fidlist JSON 문자열 규격)
      dlink = 'https://www.terabox.com/api/download?app_id=$appId&web=1&channel=dubox&clienttype=0&jsToken=${_cachedJsToken ?? ""}&fidlist=["$fsId"]';
    }
    // 3. dlink 302 리다이렉트 최종 CDN URL 다단계 해석 (Pre-resolve)
    String finalStreamUrl = dlink;
    try {
      final client = http.Client();
      var currentUrl = dlink;
      for (int i = 0; i < 5; i++) {
        final request = http.Request('GET', Uri.parse(currentUrl))
          ..followRedirects = false
          ..headers.addAll({
            'User-Agent': defaultUserAgent,
            'Cookie': cookieHeader,
            'Referer': 'https://www.terabox.com/',
            'Range': 'bytes=0-0',
          });

        final response = await client.send(request);
        if (response.isRedirect && response.headers['location'] != null) {
          currentUrl = response.headers['location']!;
          finalStreamUrl = currentUrl;
          debugPrint('[TeraBoxService] 302 리다이렉트 ($i): $finalStreamUrl');
        } else {
          break;
        }
      }
      client.close();
    } catch (e) {
      debugPrint('[TeraBoxService] 302 사전 해석 오류 (원래 dlink 사용): $e');
    }

    // 캐시에 3시간 저장
    _streamUrlCache[cacheKey] = (
      url: finalStreamUrl,
      expiry: DateTime.now().add(const Duration(hours: 3)),
    );

    return finalStreamUrl;
  }

  /// /api/streaming 비공식 API로부터 요청한 화질의 HLS 스트림 URL 획득
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

        // 2. 200 OK 응답인 경우 (M3U8 플레이리스트 본문 또는 JSON 응답)
        if (streamedRes.statusCode == 200) {
          final bodyBytes = await streamedRes.stream.toBytes();
          final bodyText = utf8.decode(bodyBytes, allowMalformed: true);

          // 직접 #EXTM3U 플레이리스트를 반환하는 경우에만 스트림 URI 자체를 재생 소스로 사용 (#EXTINF 세그먼트 검증)
          if (bodyText.contains('#EXTM3U') && bodyText.contains('#EXTINF')) {
            return streamUri.toString();
          }

          // JSON 응답인 경우 (errno 검사 및 url, m3u8_url, dlink 필드 등 파싱)
          try {
            final json = jsonDecode(bodyText);
            if (json is Map) {
              if (json['errno'] != null && json['errno'] != 0) {
                debugPrint('[TeraBoxService] HLS 스트리밍 응답 errno: ${json['errno']} (type: $q)');
                continue; // 다음 해상도 시도 또는 폴백
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

          // #EXTM3U가 아니고 유효한 URL도 없는 일반 HTML/에러 페이지인 경우 무시하고 다음 품질 시도
          debugPrint('[TeraBoxService] HLS 응답에 #EXTM3U 세그먼트 또는 유효 URL 없음 (길이: ${bodyText.length})');
        }
      } catch (e) {
        debugPrint('[TeraBoxService] HLS 스트리밍 엔드포인트($q) 요청 실패: $e');
      } finally {
        client.close();
      }
    }
    return null;
  }

  @override
  Future<Map<String, String>> getStreamHeaders() async {
    return {
      'User-Agent': defaultUserAgent,
      'Cookie': cookieHeader,
      'Referer': 'https://www.terabox.com/',
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

    final uri = Uri.parse('https://www.terabox.com/api/filemanager').replace(
      queryParameters: {
        'opera': 'rename',
        'app_id': appId,
        'web': '1',
        'channel': 'dubox',
        'clienttype': '0',
        'jsToken': _cachedJsToken ?? '',
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
        'Referer': 'https://www.terabox.com/',
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

    final uri = Uri.parse('https://www.terabox.com/api/filemanager').replace(
      queryParameters: {
        'opera': 'delete',
        'app_id': appId,
        'web': '1',
        'channel': 'dubox',
        'clienttype': '0',
        'jsToken': _cachedJsToken ?? '',
      },
    );

    final filelist = jsonEncode([path]);

    final res = await http.post(
      uri,
      headers: {
        'User-Agent': defaultUserAgent,
        'Cookie': cookieHeader,
        'Referer': 'https://www.terabox.com/',
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

    final uri = Uri.parse('https://www.terabox.com/api/create').replace(
      queryParameters: {
        'app_id': appId,
        'web': '1',
        'channel': 'dubox',
        'clienttype': '0',
        'jsToken': _cachedJsToken ?? '',
      },
    );

    final res = await http.post(
      uri,
      headers: {
        'User-Agent': defaultUserAgent,
        'Cookie': cookieHeader,
        'Referer': 'https://www.terabox.com/',
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

    final uri = Uri.parse('https://www.terabox.com/api/filemanager').replace(
      queryParameters: {
        'opera': 'move',
        'app_id': appId,
        'web': '1',
        'channel': 'dubox',
        'clienttype': '0',
        'jsToken': _cachedJsToken ?? '',
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
        'Referer': 'https://www.terabox.com/',
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

    final uri = Uri.parse('https://www.terabox.com/api/filemanager').replace(
      queryParameters: {
        'opera': 'copy',
        'app_id': appId,
        'web': '1',
        'channel': 'dubox',
        'clienttype': '0',
        'jsToken': _cachedJsToken ?? '',
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
        'Referer': 'https://www.terabox.com/',
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
