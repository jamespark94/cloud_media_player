import 'mega_service.dart';
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
  String registerStream(CloudService service, MediaItem item, {VideoQuality? quality}) {
    final sessionId = '${DateTime.now().microsecondsSinceEpoch}_${_sessions.length}';
    _sessions[sessionId] = _ActiveStream(service: service, item: item, quality: quality);
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
    try {
      await session.service.refreshTokensIfNeeded();
      final targetUrl = session.quality != null
          ? await session.service.getStreamUrlWithQuality(session.item, session.quality!)
          : await session.service.getStreamUrl(session.item);
      final headers = await session.service.getStreamHeaders();

      debugPrint('[LocalStreamProxy] 스트림 요청: $targetUrl');

      final client = http.Client();
      final method = request.method == 'HEAD' ? 'HEAD' : 'GET';
      final proxyReq = http.Request(method, Uri.parse(targetUrl));

      // 헤더 포워딩
      headers.forEach((k, v) => proxyReq.headers[k] = v);
      // /api/streaming 은 URL 획득 시와 동일한 UA 필요 (Baidu는 PCS UA와 다름)
      if (targetUrl.contains('api/streaming') && session.service.account.type == CloudType.baidu) {
        proxyReq.headers['User-Agent'] = BaiduService.defaultUserAgent;
      }

      final clientRange = request.headers.value(HttpHeaders.rangeHeader);
      if (clientRange != null) {
        proxyReq.headers[HttpHeaders.rangeHeader] = clientRange;
      }

      final proxyRes = await client.send(proxyReq);

      // M3U8 플레이리스트인 경우: 내부 하위 URL들을 로컬 프록시 주소로 재작성(Rewrite)
      final rawContentType = proxyRes.headers['content-type'] ?? '';
      final isM3u8 = targetUrl.contains('.m3u8') ||
          targetUrl.contains('api/streaming') ||
          targetUrl.contains('method=streaming') ||
          rawContentType.contains('mpegurl');

      if (isM3u8 && proxyRes.statusCode == 200 && method != 'HEAD') {
        final bodyBytes = await proxyRes.stream.toBytes();
        final bodyStr = utf8.decode(bodyBytes, allowMalformed: true);

        if (bodyStr.contains('#EXTM3U')) {
          final targetUri = Uri.parse(targetUrl);
          final rewritten = _rewriteM3u8(bodyStr, targetUri, sessionId);

          request.response.statusCode = HttpStatus.ok;
          request.response.headers.set(HttpHeaders.contentTypeHeader, 'application/vnd.apple.mpegurl');
          request.response.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
          request.response.write(rewritten);
          await request.response.close();
          client.close();
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
        await request.response.addStream(proxyRes.stream);
      }
      await request.response.close();
      client.close();
    } catch (e) {
      debugPrint('[LocalStreamProxy] 스트림 에러: $e');
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      } catch (_) {}
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
    try {
      final headers = await session.service.getStreamHeaders();
      final client = http.Client();
      final proxyReq = http.Request(request.method, Uri.parse(rawUrl));

      headers.forEach((k, v) => proxyReq.headers[k] = v);

      final clientRange = request.headers.value(HttpHeaders.rangeHeader);
      if (clientRange != null) {
        proxyReq.headers[HttpHeaders.rangeHeader] = clientRange;
      }

      final proxyRes = await client.send(proxyReq);

      // 하위 m3u8 플레이리스트면 세그먼트 URL도 프록시로 재작성
      final ct = proxyRes.headers['content-type'] ?? '';
      if (request.method != 'HEAD' &&
          proxyRes.statusCode == 200 &&
          (rawUrl.contains('.m3u8') ||
              rawUrl.contains('api/streaming') ||
              rawUrl.contains('method=streaming') ||
              ct.contains('mpegurl'))) {
        final bytes = await proxyRes.stream.toBytes();
        final text = utf8.decode(bytes, allowMalformed: true);
        if (text.trimLeft().startsWith('#EXTM3U')) {
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.set(HttpHeaders.contentTypeHeader, 'application/vnd.apple.mpegurl');
          request.response.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
          request.response.write(_rewriteM3u8(text, Uri.parse(rawUrl), sessionId));
          await request.response.close();
          client.close();
          return;
        }
        request.response.statusCode = proxyRes.statusCode;
        if (ct.isNotEmpty) request.response.headers.set(HttpHeaders.contentTypeHeader, ct);
        request.response.add(bytes);
        await request.response.close();
        client.close();
        return;
      }

      request.response.statusCode = proxyRes.statusCode;
      const skip = {'transfer-encoding', 'content-encoding', 'connection'};
      proxyRes.headers.forEach((k, v) {
        if (!skip.contains(k.toLowerCase())) {
          request.response.headers.set(k, v);
        }
      });

      if (request.method != 'HEAD') {
        await request.response.addStream(proxyRes.stream);
      }
      await request.response.close();
      client.close();
    } catch (e) {
      debugPrint('[LocalStreamProxy] HLS 세그먼트 전달 실패: $e');
      try {
        request.response.statusCode = HttpStatus.badGateway;
        await request.response.close();
      } catch (_) {}
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
  _ActiveStream({required this.service, required this.item, this.quality});
}

