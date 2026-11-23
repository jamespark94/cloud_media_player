import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';

class _RelayTarget {
  final String url;
  final Map<String, String> headers;
  final DateTime createdAt;

  _RelayTarget({
    required this.url,
    required this.headers,
  }) : createdAt = DateTime.now();
}

/// `ffmpeg_kit_flutter_new_min`은 경량 FFmpeg(TLS/OpenSSL 미포함)이므로,
/// `https://` 클라우드 스트림 및 인증 헤더(`Authorization`, `Cookie` 등)를
/// 안전한 Loopback HTTP(`http://127.0.0.1:<port>/relay`)로 중계합니다.
///
/// 기존 비디오 플레이어용 `LocalStreamProxy`와 완전히 분리되어 동작합니다.
class LocalHttpAudioRelay {
  static final LocalHttpAudioRelay instance = LocalHttpAudioRelay._();
  LocalHttpAudioRelay._();

  HttpServer? _server;
  HttpClient? _client;
  final Map<String, _RelayTarget> _targets = {};
  int _seq = 0;

  bool get isRunning => _server != null;

  Future<void> ensureStarted() async {
    if (_server != null) return;
    _client ??= HttpClient()
      ..autoUncompress = false
      ..connectionTimeout = const Duration(seconds: 12);
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen(_handleRequest);
    debugPrint('[LocalHttpAudioRelay] 시작됨: 127.0.0.1:${_server!.port}');
  }

  /// 원격 URL과 인증 헤더를 등록하고 FFmpeg가 바로 읽을 수 있는 로컬 HTTP URL을 반환합니다.
  Future<String> register({
    required String url,
    required Map<String, String> headers,
  }) async {
    await ensureStarted();
    final token = '${DateTime.now().microsecondsSinceEpoch}_${++_seq}';
    _targets[token] = _RelayTarget(
      url: url,
      headers: Map<String, String>.from(headers),
    );
    return 'http://127.0.0.1:${_server!.port}/relay?token=$token';
  }

  void unregister(String? relayUrl) {
    if (relayUrl == null || !relayUrl.contains('token=')) return;
    try {
      final token = Uri.parse(relayUrl).queryParameters['token'];
      if (token != null) {
        _targets.remove(token);
      }
    } catch (_) {}
  }

  Future<void> dispose() async {
    _targets.clear();
    final srv = _server;
    _server = null;
    try {
      await srv?.close(force: true);
    } catch (_) {}
    try {
      _client?.close(force: true);
    } catch (_) {}
    _client = null;
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final token = request.uri.queryParameters['token'];
    final target = token != null ? _targets[token] : null;
    if (target == null) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close().catchError((_) {});
      return;
    }

    HttpClientRequest? upstreamReq;
    HttpClientResponse? upstreamRes;
    try {
      final client = _client;
      if (client == null) {
        request.response.statusCode = HttpStatus.serviceUnavailable;
        await request.response.close().catchError((_) {});
        return;
      }

      final uri = Uri.parse(target.url);
      upstreamReq = request.method == 'HEAD'
          ? await client.headUrl(uri)
          : await client.getUrl(uri);
      upstreamReq.followRedirects = true;
      upstreamReq.maxRedirects = 6;

      target.headers.forEach((k, v) {
        upstreamReq!.headers.set(k, v);
      });

      final range = request.headers.value(HttpHeaders.rangeHeader);
      if (range != null && range.isNotEmpty) {
        upstreamReq.headers.set(HttpHeaders.rangeHeader, range);
      }

      upstreamRes =
          await upstreamReq.close().timeout(const Duration(seconds: 15));

      request.response.statusCode = upstreamRes.statusCode;
      request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');

      final ct = upstreamRes.headers.value(HttpHeaders.contentTypeHeader);
      if (ct != null && ct.isNotEmpty) {
        request.response.headers.set(HttpHeaders.contentTypeHeader, ct);
      }
      final cr = upstreamRes.headers.value(HttpHeaders.contentRangeHeader);
      if (cr != null && cr.isNotEmpty) {
        request.response.headers.set(HttpHeaders.contentRangeHeader, cr);
      }
      if (upstreamRes.contentLength >= 0) {
        request.response.contentLength = upstreamRes.contentLength;
      }
      request.response.bufferOutput = false;

      if (request.method != 'HEAD') {
        await request.response.addStream(upstreamRes);
      }
      await request.response.close();
    } catch (_) {
      // FFmpeg가 -t 구간 추출 후 소켓을 조기 종료할 때 발생하는 정상 Pipe 단절 무시
      try {
        await request.response.close();
      } catch (_) {}
    }
  }
}
