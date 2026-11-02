import 'mega_service.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/media_item.dart';
import '../models/video_quality.dart';
import '../models/cloud_account.dart';
import 'baidu_service.dart';
import 'cloud_service_interface.dart';

class LocalStreamProxy {
  static LocalStreamProxy? _instance;
  HttpServer? _server;
  int? get port => _server?.port;

  static LocalStreamProxy get instance => _instance ??= LocalStreamProxy._();
  LocalStreamProxy._();

  final http.Client _segmentClient = http.Client();
  final _Gate _segmentGate = _Gate(2);

  // Active streaming session registry
  final Map<String, _ActiveStream> _sessions = {};

  Future<void> start() async {
    if (_server != null) return;
    try {
      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _server!.listen(_handleRequest);
      debugPrint('[LocalStreamProxy] 서버 시작됨: 127.0.0.1:${_server!.port}');
    } catch (e) {
      debugPrint('[LocalStreamProxy] 서버 시작 실패: $e');
    }
  }

  Future<void> stop() async {
    await _server?.close();
    _server = null;
    _sessions.clear();
  }

  /// 미디어 아이템에 대한 로컬 프록시 스트리밍 URL을 등록하고 반환합니다.
  String registerStream(CloudService service, MediaItem item, {VideoQuality? quality, String? initialUrl}) {
    final sessionId = '${DateTime.now().microsecondsSinceEpoch}_${_sessions.length}';
    final s = _ActiveStream(service: service, item: item, quality: quality);
    if (initialUrl != null && initialUrl.isNotEmpty) {
      s.cachedStreamUrl = initialUrl;
      s.streamUrlExpiry = DateTime.now().add(const Duration(minutes: 10));
    }
    _sessions[sessionId] = s;
    return 'http://127.0.0.1:${_server!.port}/stream?session=$sessionId';
  }

  /// 프록시 세션을 안전하게 정리합니다.
  void unregisterStream(String? streamUrl) {
    if (streamUrl == null || !streamUrl.contains('session=')) return;
    try {
      final uri = Uri.parse(streamUrl);
      final sessionId = uri.queryParameters['session'];
      if (sessionId != null) {
        _sessions.remove(sessionId);
        debugPrint('[LocalStreamProxy] 스트림 세션 등록 해제: $sessionId');
      }
    } catch (_) {}
  }

  void _handleRequest(HttpRequest request) async {
    // 1. 하위 M3U8 또는 세그먼트(.ts) 프록시 요청 처리
    if (request.uri.path == '/hls_segment') {
      await _handleHlsSegment(request);
      return;
    }

    final sessionId = request.uri.queryParameters['session'];
    if (sessionId == null || !_sessions.containsKey(sessionId)) {
      request.response.statusCode = HttpStatus.notFound;
      request.response.write('Stream session not found');
      await request.response.close();
      return;
    }

    final session = _sessions[sessionId]!;
    if (session.service is MegaService) {
      await _handleMegaStream(request, session.service as MegaService, session.item);
      return;
    }

    final sw = Stopwatch()..start();
    http.Client? client;
    try {
      String targetUrl;
      final now = DateTime.now();
      if (session.cachedStreamUrl != null &&
          session.streamUrlExpiry != null &&
          now.isBefore(session.streamUrlExpiry!)) {
        targetUrl = session.cachedStreamUrl!;
      } else {
        await session.service.refreshTokensIfNeeded().timeout(const Duration(seconds: 10));
        targetUrl = session.quality != null
            ? await session.service.getStreamUrlWithQuality(session.item, session.quality!).timeout(const Duration(seconds: 15))
            : await session.service.getStreamUrl(session.item).timeout(const Duration(seconds: 15));
        session.cachedStreamUrl = targetUrl;
        session.streamUrlExpiry = now.add(const Duration(minutes: 10));
      }

      final headers = await session.service.getStreamHeaders();

      final clientRange = request.headers.value(HttpHeaders.rangeHeader);
      debugPrint('[LocalStreamProxy] 스트림 요청: $targetUrl | Range: $clientRange');

      client = http.Client();
      final method = request.method == 'HEAD' ? 'HEAD' : 'GET';
      final proxyReq = http.Request(method, Uri.parse(targetUrl));

      // 헤더 포워딩
      headers.forEach((k, v) => proxyReq.headers[k] = v);
      // /api/streaming 은 URL 획득 시와 동일한 UA 필요 (Baidu는 PCS UA와 다름)
      if (targetUrl.contains('api/streaming') && session.service.account.type == CloudType.baidu) {
        proxyReq.headers['User-Agent'] = BaiduService.defaultUserAgent;
      }

      if (clientRange != null) {
        proxyReq.headers[HttpHeaders.rangeHeader] = clientRange;
      }

      final proxyRes = await client.send(proxyReq).timeout(const Duration(seconds: 15));
      debugPrint('[LocalStreamProxy] 상류 응답: ${proxyRes.statusCode} (${sw.elapsedMilliseconds}ms) | URL: $targetUrl');

      // 상류 4xx/5xx 에러 처리
      if (proxyRes.statusCode >= 400) {
        debugPrint('[LocalStreamProxy] 상류 오류 상태코드: ${proxyRes.statusCode} | URL: $targetUrl');
        request.response.statusCode = proxyRes.statusCode >= 500 ? HttpStatus.badGateway : proxyRes.statusCode;
        await request.response.close();
        return;
      }

      // M3U8 플레이리스트인 경우: 내부 하위 URL들을 로컬 프록시 주소로 재작성(Rewrite)
      final rawContentType = proxyRes.headers['content-type'] ?? '';
      final isM3u8 = targetUrl.contains('.m3u8') ||
          targetUrl.contains('api/streaming') ||
          targetUrl.contains('method=streaming') ||
          rawContentType.contains('mpegurl');

      if (isM3u8 && proxyRes.statusCode == 200 && method != 'HEAD') {
        // 단기 M3U8 캐시가 있으면(mpv의 1초 내 연속 2회 요청) 즉시 반환
        if (session.cachedM3u8Body != null &&
            session.cachedM3u8Expiry != null &&
            now.isBefore(session.cachedM3u8Expiry!)) {
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.set(HttpHeaders.contentTypeHeader, 'application/vnd.apple.mpegurl');
          request.response.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
          request.response.write(session.cachedM3u8Body!);
          await request.response.close();
          debugPrint('[LocalStreamProxy] M3U8 플레이리스트 캐시 반환 (${sw.elapsedMilliseconds}ms)');
          return;
        }

        final bodyBytes = await proxyRes.stream.toBytes().timeout(const Duration(seconds: 15));
        final bodyStr = utf8.decode(bodyBytes, allowMalformed: true);

        if (bodyStr.contains('#EXTM3U')) {
          final targetUri = Uri.parse(targetUrl);
          final rewritten = _rewriteM3u8(bodyStr, targetUri, sessionId);

          session.cachedM3u8Body = rewritten;
          session.cachedM3u8Expiry = DateTime.now().add(const Duration(seconds: 10));

          request.response.statusCode = HttpStatus.ok;
          request.response.headers.set(HttpHeaders.contentTypeHeader, 'application/vnd.apple.mpegurl');
          request.response.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
          request.response.write(rewritten);
          await request.response.close();
          debugPrint('[LocalStreamProxy] M3U8 플레이리스트 재작성 및 반환 완료 (${sw.elapsedMilliseconds}ms)');
          return;
        }
      }

      // 클라이언트 응답 헤더 세팅
      request.response.statusCode = proxyRes.statusCode;

      // 1. 탐색(Seek) 지원 필수 알림
      request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');

      // 2. Content-Type 전달
      final contentType = proxyRes.headers['content-type'];
      if (contentType != null && contentType.isNotEmpty) {
        request.response.headers.set(HttpHeaders.contentTypeHeader, contentType);
      } else if (isM3u8) {
        request.response.headers.set(HttpHeaders.contentTypeHeader, 'application/vnd.apple.mpegurl');
      } else {
        request.response.headers.set(HttpHeaders.contentTypeHeader, 'video/mp4');
      }

      // 3. Content-Range 전달 (HTTP 206 Partial Content 필수)
      final contentRange = proxyRes.headers['content-range'];
      if (contentRange != null && contentRange.isNotEmpty) {
        request.response.headers.set(HttpHeaders.contentRangeHeader, contentRange);
      }

      // 4. Content-Length 설정
      if (proxyRes.contentLength != null && proxyRes.contentLength! >= 0) {
        request.response.contentLength = proxyRes.contentLength!;
      }

      request.response.bufferOutput = false;

      // 5. 바이트 스트림 파이핑
      if (method != 'HEAD') {
        final timeoutStream = proxyRes.stream.timeout(const Duration(seconds: 25));
        await request.response.addStream(timeoutStream);
      }
      await request.response.close();
      debugPrint('[LocalStreamProxy] 스트림 파이핑 완료 (${sw.elapsedMilliseconds}ms)');
    } catch (e) {
      debugPrint('[LocalStreamProxy] 스트림 에러 (${sw.elapsedMilliseconds}ms): $e');
      try {
        request.response.statusCode = HttpStatus.gatewayTimeout;
        await request.response.close();
      } catch (_) {}
    } finally {
      client?.close();
    }
  }

  /// M3U8 플레이리스트 내의 세그먼트/서브 m3u8 URL을 로컬 프록시 주소로 변환
  String _rewriteM3u8(String m3u8Content, Uri baseUri, String sessionId) {
    final lines = m3u8Content.split('\n');
    final output = <String>[];

    for (var line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        output.add(line);
        continue;
      }
      if (trimmed.startsWith('#')) {
        // #EXT-X-KEY:METHOD=...,URI="..." 처리
        if (trimmed.startsWith('#EXT-X-KEY:')) {
          final uriMatch = RegExp(r'URI="([^"]+)"').firstMatch(trimmed);
          if (uriMatch != null) {
            final keyUriStr = uriMatch.group(1)!;
            final resolvedKeyUri = baseUri.resolve(keyUriStr).toString();
            final proxiedKeyUri = 'http://127.0.0.1:${_server!.port}/hls_segment?session=$sessionId&url=${Uri.encodeComponent(resolvedKeyUri)}';
            line = line.replaceFirst(keyUriStr, proxiedKeyUri);
          }
        }
        output.add(line);
      } else {
        // 상대 경로 또는 절대 경로 URL을 절대 URL로 정규화 후 로컬 프록시로 감쌈
        final resolvedUri = baseUri.resolve(trimmed).toString();
        final proxiedUrl = 'http://127.0.0.1:${_server!.port}/hls_segment?session=$sessionId&url=${Uri.encodeComponent(resolvedUri)}';
        output.add(proxiedUrl);
      }
    }

    return output.join('\n');
  }

  /// HLS 개별 청크(.ts) 또는 키 파일 요청을 올바른 인증 헤더와 함께 원본 서버로 전달
  Future<void> _handleHlsSegment(HttpRequest request) async {
    final sessionId = request.uri.queryParameters['session'];
    final rawUrl = request.uri.queryParameters['url'];

    if (sessionId == null || rawUrl == null || !_sessions.containsKey(sessionId)) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    final session = _sessions[sessionId]!;
    final sw = Stopwatch()..start();
    http.Client? client;
    try {
      final headers = await session.service.getStreamHeaders();

      // Baidu HLS 세그먼트/하위 플레이리스트 UA 분기
      // pan.baidu.com(api/streaming)은 defaultUserAgent, d.pcs.baidu.com은 pcsUserAgent(LogStatistic)
      if (session.service.account.type == CloudType.baidu) {
        if (rawUrl.contains('pan.baidu.com')) {
          headers['User-Agent'] = BaiduService.defaultUserAgent;
        } else if (rawUrl.contains('pcs.baidu.com')) {
          headers['User-Agent'] = BaiduService.pcsUserAgent;
        }
      }

      final clientRange = request.headers.value(HttpHeaders.rangeHeader);
      debugPrint('[LocalStreamProxy] HLS 세그먼트 요청: $rawUrl | Range: $clientRange');

      // 바이두 백업 CDN 호스트(backhost) 목록 파싱 및 세션 누적 기억
      final uriParsed = Uri.parse(rawUrl);
      final backhostParam = uriParsed.queryParameters['backhost'];
      final List<String> backhosts = List<String>.from(session.knownBackhosts);
      if (backhostParam != null && backhostParam.isNotEmpty) {
        try {
          final decoded = jsonDecode(backhostParam);
          if (decoded is List) {
            for (final h in decoded) {
              if (h is String && h.isNotEmpty && !backhosts.contains(h)) {
                backhosts.add(h);
                if (!session.knownBackhosts.contains(h)) {
                  session.knownBackhosts.add(h);
                }
              }
            }
          }
        } catch (_) {}
      }

      // 동시 요청 수 제한 + 짧은 타임아웃(3.5~5초) + 백업 CDN(backhost) 자동 전환 재시도
      http.StreamedResponse? proxyResMaybe;
      Object? lastErr;
      await _segmentGate.acquire();
      try {
        for (var attempt = 1; attempt <= 3; attempt++) {
          Uri targetUri = uriParsed;
          // 세션에서 이미 검증된 고속 CDN 호스트가 있거나 2차 이상 재시도인 경우 즉시 백업 CDN(nv4.baidupcs.com 등)으로 전환
          String? hostToUse;
          if (attempt == 1 && session.preferredCdnHost != null) {
            hostToUse = session.preferredCdnHost;
          } else if (attempt > 1 && backhosts.isNotEmpty) {
            final idx = (attempt - (session.preferredCdnHost != null ? 1 : 2)) % backhosts.length;
            hostToUse = backhosts[idx < 0 ? 0 : idx];
          }

          if (hostToUse != null && hostToUse != targetUri.host) {
            targetUri = targetUri.replace(host: hostToUse);
            debugPrint('[LocalStreamProxy] HLS 백업 CDN 전환 ($hostToUse, 시도 $attempt/3): $targetUri');
          }

          final proxyReq = http.Request(request.method, targetUri);
          headers.forEach((k, v) => proxyReq.headers[k] = v);
          if (clientRange != null) {
            proxyReq.headers[HttpHeaders.rangeHeader] = clientRange;
          }
          try {
            // 빠른 타임아웃 (1차: 4초, 2~3차: 5초)으로 죽은 노드에서 신속 탈출
            final timeoutSec = attempt == 1 ? 4 : 5;
            final res = await _segmentClient.send(proxyReq).timeout(Duration(seconds: timeoutSec));

            // antpcdn P2P 노드로의 302 리다이렉트 발생 시 연결 끊김 방지를 위해 즉시 다음 백업 호스트로 전환
            if (res.isRedirect || res.statusCode == HttpStatus.movedPermanently || res.statusCode == HttpStatus.found) {
              final loc = res.headers['location'];
              if (loc != null && loc.contains('antpcdn.com')) {
                debugPrint('[LocalStreamProxy] antpcdn P2P 리다이렉트 감지 -> 안정적인 Baidu CDN으로 재전환 ($loc)');
                throw const SocketException('Avoid antpcdn p2p redirect');
              }
            }

            proxyResMaybe = res;
            if (hostToUse != null && hostToUse.contains('baidupcs.com')) {
              session.preferredCdnHost = hostToUse;
            }
            break;
          } catch (e) {
            lastErr = e;
            debugPrint('[LocalStreamProxy] HLS 상류 요청 재시도 $attempt/3 (${sw.elapsedMilliseconds}ms): $e');
          }
        }
      } finally {
        _segmentGate.release();
      }
      if (proxyResMaybe == null) throw lastErr ?? TimeoutException('upstream');
      final proxyRes = proxyResMaybe;
      debugPrint('[LocalStreamProxy] HLS 상류 응답: ${proxyRes.statusCode} (${sw.elapsedMilliseconds}ms)');

      if (proxyRes.statusCode >= 400) {
        debugPrint('[LocalStreamProxy] HLS 상류 에러: ${proxyRes.statusCode} | URL: $rawUrl');
        request.response.statusCode = proxyRes.statusCode >= 500 ? HttpStatus.badGateway : proxyRes.statusCode;
        await request.response.close();
        return;
      }

      // 하위 m3u8 플레이리스트면 세그먼트 URL도 프록시로 재작성
      final ct = proxyRes.headers['content-type'] ?? '';
      if (request.method != 'HEAD' &&
          proxyRes.statusCode == 200 &&
          (rawUrl.contains('.m3u8') ||
              rawUrl.contains('api/streaming') ||
              rawUrl.contains('method=streaming') ||
              ct.contains('mpegurl'))) {
        final bytes = await proxyRes.stream.toBytes().timeout(const Duration(seconds: 15));
        final text = utf8.decode(bytes, allowMalformed: true);
        if (text.trimLeft().startsWith('#EXTM3U')) {
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.set(HttpHeaders.contentTypeHeader, 'application/vnd.apple.mpegurl');
          request.response.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
          request.response.write(_rewriteM3u8(text, Uri.parse(rawUrl), sessionId));
          await request.response.close();
          debugPrint('[LocalStreamProxy] HLS 하위 플레이리스트 재작성 반환 완료 (${sw.elapsedMilliseconds}ms)');
          return;
        }
        request.response.statusCode = proxyRes.statusCode;
        if (ct.isNotEmpty) request.response.headers.set(HttpHeaders.contentTypeHeader, ct);
        request.response.add(bytes);
        await request.response.close();
        return;
      }

      request.response.statusCode = proxyRes.statusCode;
      // Content-Disposition 등 비ASCII 한글 파일명 헤더로 인한 FormatException 방지
      // HLS 세그먼트 전송 및 탐색(Seek)에 필수적인 안전한 헤더만 선택적 전달
      const allowedHeaders = {
        'content-type',
        'content-length',
        'content-range',
        'accept-ranges',
        'last-modified',
        'etag',
        'cache-control',
        'access-control-allow-origin',
      };
      proxyRes.headers.forEach((k, v) {
        final lower = k.toLowerCase();
        if (allowedHeaders.contains(lower)) {
          try {
            request.response.headers.set(k, v);
          } catch (headerErr) {
            debugPrint('[LocalStreamProxy] 헤더 복사 무시 ($k): $headerErr');
          }
        }
      });

      if (request.method != 'HEAD') {
        // 청크 스트리밍 시 데이터 수신 타임아웃을 30초로 설정 (Baidu 트랜스코딩 세그먼트 버퍼 지연 대비)
        final timeoutStream = proxyRes.stream.timeout(const Duration(seconds: 30));
        await request.response.addStream(timeoutStream);
      }
      await request.response.close();
      debugPrint('[LocalStreamProxy] HLS 세그먼트 전송 완료 (${sw.elapsedMilliseconds}ms)');
    } catch (e) {
      debugPrint('[LocalStreamProxy] HLS 세그먼트 전달 실패 (${sw.elapsedMilliseconds}ms): $e');
      try {
        request.response.statusCode = HttpStatus.badGateway;
        await request.response.close();
      } catch (_) {}
    } finally {
      client?.close();
    }
  }

  Future<void> _handleMegaStream(HttpRequest request, MegaService megaService, MediaItem item) async {
    try {
      final method = request.method;
      final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
      int? start;
      int? end;

      final totalSize = item.size ?? 0;

      if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
        final parts = rangeHeader.substring(6).split('-');
        if (parts.isNotEmpty && parts[0].isNotEmpty) {
          start = int.tryParse(parts[0]);
        }
        if (parts.length > 1 && parts[1].isNotEmpty) {
          end = int.tryParse(parts[1]);
        }
      }

      final actualStart = start ?? 0;
      final actualEnd = (end != null && end < totalSize) ? end : (totalSize > 0 ? totalSize - 1 : null);
      final contentLength = actualEnd != null ? (actualEnd - actualStart + 1) : null;

      request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      request.response.headers.set(HttpHeaders.contentTypeHeader, 'video/mp4');

      if (rangeHeader != null && totalSize > 0) {
        request.response.statusCode = HttpStatus.partialContent;
        final endDisplay = actualEnd ?? (totalSize - 1);
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes ' + actualStart.toString() + '-' + endDisplay.toString() + '/' + totalSize.toString(),
        );
      } else {
        request.response.statusCode = HttpStatus.ok;
      }

      if (contentLength != null && contentLength >= 0) {
        request.response.contentLength = contentLength;
      }

      request.response.bufferOutput = false;

      if (method != 'HEAD') {
        final stream = await megaService.openDecryptedRangeStream(
          item: item,
          start: actualStart,
          end: actualEnd,
        );
        await request.response.addStream(stream);
      }

      await request.response.close();
    } catch (e) {
      debugPrint('[LocalStreamProxy] MEGA 스트림 처리 오류: ' + e.toString());
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      } catch (_) {}
    }
  }
}

class _ActiveStream {
  final CloudService service;
  final MediaItem item;
  final VideoQuality? quality;
  String? cachedStreamUrl;
  DateTime? streamUrlExpiry;
  String? cachedM3u8Body;
  DateTime? cachedM3u8Expiry;
  List<String> knownBackhosts = [];
  String? preferredCdnHost;

  _ActiveStream({required this.service, required this.item, this.quality});
}

/// 동시 실행 수를 제한하는 간단한 세마포어
class _Gate {
  _Gate(this._max);
  final int _max;
  int _running = 0;
  final List<Completer<void>> _waiters = [];

  Future<void> acquire() async {
    if (_running < _max) {
      _running++;
      return;
    }
    final c = Completer<void>();
    _waiters.add(c);
    await c.future;
  }

  void release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
    } else {
      _running--;
    }
  }
}