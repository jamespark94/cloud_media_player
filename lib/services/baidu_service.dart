import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/media_item.dart';
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
    if (token.contains('=')) {
      return token;
    }
    return 'BDUSS=$token';
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

  /// 미디어 스트리밍 URL 반환 (HLS 우선 시도 -> PCS locatedownload -> filemetas dlink -> 302 Pre-resolution)
  @override
  Future<String> getStreamUrl(MediaItem item) async {
    await refreshTokensIfNeeded();

    final fsId = _extractFsId(item.id);
    final filePath = _extractPath(item.id);

    if (fsId.isEmpty && filePath.isEmpty) {
      throw Exception('유효하지 않은 Baidu 파일 ID: ${item.id}');
    }

    final cacheKey = fsId.isNotEmpty ? fsId : filePath;

    // 캐시 확인
    final cached = _streamUrlCache[cacheKey];
    if (cached != null && DateTime.now().isBefore(cached.expiry)) {
      return cached.url;
    }

    // 1. 바이두 /api/streaming HLS(M3U8) 어댑티브 스트리밍 우선 시도
    if (filePath.isNotEmpty && filePath != fsId) {
      final hlsUrl = await _fetchHlsStreamUrl(filePath, fsId);
      if (hlsUrl != null && hlsUrl.isNotEmpty) {
        debugPrint('[BaiduService] HLS 스트림 URL 획득 성공: $hlsUrl');
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
          'User-Agent': pcsUserAgent,
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

  /// /api/streaming API로부터 HLS 스트림 URL 획득 시도
  Future<String?> _fetchHlsStreamUrl(String filePath, String fsId) async {
    final qualities = ['M3U8_AUTO_720', 'M3U8_AUTO_480', 'M3U8_AUTO_360'];

    for (final quality in qualities) {
      final streamUri = Uri.parse('https://pan.baidu.com/api/streaming').replace(
        queryParameters: {
          'app_id': appId,
          'web': '1',
          'channel': 'chunlei',
          'clienttype': '0',
          'isplayer': '1',
          'check_blue': '1',
          'type': quality,
          'path': filePath,
          if (fsId.isNotEmpty) 'fsid': fsId,
          if (_cachedJsToken != null && _cachedJsToken!.isNotEmpty) 'jsToken': _cachedJsToken!,
        },
      );

      try {
        final client = http.Client();
        final req = http.Request('GET', streamUri)
          ..followRedirects = false
          ..headers.addAll({
            'User-Agent': defaultUserAgent,
            'Cookie': cookieHeader,
            'Referer': 'https://pan.baidu.com/',
            'Accept': '*/*',
          });

        final streamedRes = await client.send(req);
        client.close();

        if (streamedRes.isRedirect && streamedRes.headers['location'] != null) {
          final location = streamedRes.headers['location']!;
          if (location.isNotEmpty) {
            return location;
          }
        }

        if (streamedRes.statusCode == 200) {
          final bodyBytes = await streamedRes.stream.toBytes();
          final bodyText = utf8.decode(bodyBytes, allowMalformed: true);

          if (bodyText.contains('#EXTM3U')) {
            return streamUri.toString();
          }

          try {
            final json = jsonDecode(bodyText);
            if (json is Map) {
              if (json['errno'] != null && json['errno'] != 0) {
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
        debugPrint('[BaiduService] HLS 스트리밍 엔드포인트($quality) 요청 실패: $e');
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
