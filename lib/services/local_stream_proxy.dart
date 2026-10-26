import 'dart:io';
import 'package:http/http.dart' as http;
import 'cloud_service_interface.dart';
import '../models/media_item.dart';

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
    } catch (_) {}
  }

  Future<void> stop() async {
    await _server?.close();
    _server = null;
    _sessions.clear();
  }

  /// 미디어 아이템에 대한 로컬 프록시 스트리밍 URL을 등록하고 반환합니다.
  String registerStream(CloudService service, MediaItem item) {
    final sessionId = '${item.id}_${DateTime.now().millisecondsSinceEpoch}';
    _sessions[sessionId] = _ActiveStream(service: service, item: item);
    return 'http://127.0.0.1:${_server!.port}/stream?session=$sessionId';
  }

  void _handleRequest(HttpRequest request) async {
    final sessionId = request.uri.queryParameters['session'];
    if (sessionId == null || !_sessions.containsKey(sessionId)) {
      request.response.statusCode = HttpStatus.notFound;
      request.response.write('Stream session not found');
      await request.response.close();
      return;
    }

    final session = _sessions[sessionId]!;
    try {
      await session.service.refreshTokensIfNeeded();
      final targetUrl = await session.service.getStreamUrl(session.item);
      final headers = await session.service.getStreamHeaders();

      final client = http.Client();
      final method = request.method == 'HEAD' ? 'HEAD' : 'GET';
      final proxyReq = http.Request(method, Uri.parse(targetUrl));

      // 헤더 포워딩
      headers.forEach((k, v) => proxyReq.headers[k] = v);

      final clientRange = request.headers.value(HttpHeaders.rangeHeader);
      if (clientRange != null) {
        proxyReq.headers[HttpHeaders.rangeHeader] = clientRange;
      }

      final proxyRes = await client.send(proxyReq);

      // 클라이언트 응답 헤더 세팅
      request.response.statusCode = proxyRes.statusCode;

      // 1. 탐색(Seek) 지원 필수 알림
      request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');

      // 2. Content-Type 전달
      final contentType = proxyRes.headers['content-type'];
      if (contentType != null && contentType.isNotEmpty) {
        request.response.headers.set(HttpHeaders.contentTypeHeader, contentType);
      } else if (targetUrl.contains('.m3u8') || targetUrl.contains('api/streaming')) {
        request.response.headers.set(HttpHeaders.contentTypeHeader, 'application/vnd.apple.mpegurl');
      } else {
        request.response.headers.set(HttpHeaders.contentTypeHeader, 'video/mp4');
      }

      // 3. Content-Range 전달 (HTTP 206 Partial Content 필수)
      final contentRange = proxyRes.headers['content-range'];
      if (contentRange != null && contentRange.isNotEmpty) {
        request.response.headers.set(HttpHeaders.contentRangeHeader, contentRange);
      }

      // 4. Content-Length 설정 (chunked encoding 방지하여 mpv가 재생 길이를 정상 인식하도록 함)
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
  _ActiveStream({required this.service, required this.item});
}
