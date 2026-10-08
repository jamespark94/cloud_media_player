import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

class OAuthHelper {
  static Completer<String?>? _activeAuthCompleter;

  static String generateRandomString([int length = 64]) {
    final rand = Random.secure();
    final values = List<int>.generate(length, (i) => rand.nextInt(256));
    return base64UrlEncode(values).replaceAll('=', '');
  }

  static String generateCodeChallenge(String verifier) {
    final bytes = ascii.encode(verifier);
    final digest = sha256.convert(bytes);
    return base64UrlEncode(digest.bytes).replaceAll('=', '');
  }

  /// 수동으로 브라우저 주소창의 전체 URL 또는 인가 코드(Auth Code)를 주입받아 대기를 해제합니다.
  static bool submitManualCallback(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return false;

    String? code;
    try {
      final uri = Uri.tryParse(trimmed);
      if (uri != null && uri.queryParameters.containsKey('code')) {
        code = uri.queryParameters['code'];
      }
    } catch (_) {}

    if (code == null && trimmed.contains('code=')) {
      final match = RegExp(r'[?&]code=([^&]+)').firstMatch(trimmed);
      if (match != null) {
        code = Uri.decodeComponent(match.group(1)!);
      }
    }

    code ??= trimmed;

    if (code.isNotEmpty && _activeAuthCompleter != null && !_activeAuthCompleter!.isCompleted) {
      _activeAuthCompleter!.complete(code);
      return true;
    }
    return false;
  }

  /// 현재 진행 중인 OAuth 대기를 취소합니다.
  static void cancelAuthentication() {
    if (_activeAuthCompleter != null && !_activeAuthCompleter!.isCompleted) {
      _activeAuthCompleter!.complete(null);
    }
  }

  /// 로컬 루프백 서버를 열어 브라우저 인증 후 리디렉트된 인가 코드(Auth Code)를 수신합니다.
  static Future<String?> authenticateWithLoopback({
    required String authUrlWithoutParams,
    required Map<String, String> params,
    int port = 8999,
    String redirectPath = '/callback',
  }) async {
    _activeAuthCompleter = Completer<String?>();

    HttpServer? serverIpv4;
    HttpServer? serverIpv6;

    try {
      serverIpv4 = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    } catch (_) {
      try {
        serverIpv4 = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      } catch (e) {
        throw Exception('로컬 루프백 서버 바인드 실패: $e');
      }
    }

    final actualPort = serverIpv4.port;
    try {
      serverIpv6 = await HttpServer.bind(InternetAddress.loopbackIPv6, actualPort);
    } catch (_) {
      // IPv6 지원이 비활성화된 환경에서는 IPv4로만 진행
    }

    final path = redirectPath.startsWith('/') ? redirectPath : '/$redirectPath';
    final redirectUri = 'http://localhost:$actualPort$path';
    params['redirect_uri'] = redirectUri;

    final uri = Uri.parse(authUrlWithoutParams).replace(queryParameters: params);

    void handleRequest(HttpRequest request) async {
      try {
        // 크롬 / 삼성 브라우저 PNA(Private Network Access) 및 CORS 프리플라이트 대응 헤더
        request.response.headers.set('Access-Control-Allow-Origin', '*');
        request.response.headers.set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
        request.response.headers.set('Access-Control-Allow-Headers', '*');
        request.response.headers.set('Access-Control-Allow-Private-Network', 'true');

        if (request.method == 'OPTIONS') {
          request.response.statusCode = HttpStatus.ok;
          await request.response.close();
          return;
        }

        if (request.uri.path == '/favicon.ico') {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
          return;
        }

        final code = request.uri.queryParameters['code'];
        final error = request.uri.queryParameters['error'];

        final isTargetRequest = code != null ||
            error != null ||
            request.uri.path == path ||
            request.uri.path == '/callback' ||
            request.uri.path == '/';

        if (isTargetRequest) {
          request.response.headers.contentType = ContentType.html;
          if (code != null) {
            request.response.write('''
              <!DOCTYPE html>
              <html>
                <head>
                  <meta charset="utf-8">
                  <meta name="viewport" content="width=device-width, initial-scale=1.0">
                  <title>인증 완료</title>
                </head>
                <body style="font-family:sans-serif;text-align:center;padding:50px 20px;background:#121212;color:#ffffff;">
                  <h2 style="color:#4CAF50;">✓ 인증이 성공적으로 완료되었습니다!</h2>
                  <p>이 창을 닫고 클라우드 미디어 플레이어 앱으로 돌아가세요.</p>
                  <script>
                    window.setTimeout(function(){ window.close(); }, 1500);
                  </script>
                </body>
              </html>
            ''');
            await request.response.close();
            if (_activeAuthCompleter != null && !_activeAuthCompleter!.isCompleted) {
              _activeAuthCompleter!.complete(code);
            }
          } else if (error != null) {
            request.response.write('''
              <!DOCTYPE html>
              <html>
                <head>
                  <meta charset="utf-8">
                  <meta name="viewport" content="width=device-width, initial-scale=1.0">
                  <title>인증 실패</title>
                </head>
                <body style="font-family:sans-serif;text-align:center;padding:50px 20px;background:#121212;color:#ff5252;">
                  <h2 style="color:#ff5252;">인증 실패</h2>
                  <p>오류 내용: $error</p>
                </body>
              </html>
            ''');
            await request.response.close();
            if (_activeAuthCompleter != null && !_activeAuthCompleter!.isCompleted) {
              _activeAuthCompleter!.completeError(Exception('OAuth 인증 오류: $error'));
            }
          } else {
            request.response.write('''
              <!DOCTYPE html>
              <html>
                <head><meta charset="utf-8"></head>
                <body style="font-family:sans-serif;text-align:center;padding:40px;background:#121212;color:#ffffff;">
                  <p>인증 진행 중...</p>
                </body>
              </html>
            ''');
            await request.response.close();
          }
        } else {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
        }
      } catch (_) {}
    }

    serverIpv4.listen(handleRequest);
    serverIpv6?.listen(handleRequest);

    // 기본 웹 브라우저 / 커스텀 탭에서 인증 URL 실행
    bool launched = false;
    try {
      // 모바일(Android/iOS)에서는 inAppBrowserView(Chrome Custom Tabs)를 우선 사용하여
      // 삼성 One UI 프로세스 동결(Freezer)을 방지하고 자동 복귀를 지원합니다.
      if (Platform.isAndroid || Platform.isIOS) {
        try {
          launched = await launchUrl(uri, mode: LaunchMode.inAppBrowserView);
        } catch (_) {
          launched = false;
        }
      }
      if (!launched && await canLaunchUrl(uri)) {
        launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
      if (!launched) {
        launched = await launchUrl(uri, mode: LaunchMode.platformDefault);
      }
    } catch (_) {
      try {
        launched = await launchUrl(uri);
      } catch (e) {
        await serverIpv4.close(force: true);
        await serverIpv6?.close(force: true);
        throw Exception('브라우저를 열 수 없습니다: $e');
      }
    }

    if (!launched) {
      await serverIpv4.close(force: true);
      await serverIpv6?.close(force: true);
      throw Exception('브라우저를 열 수 없습니다: $uri');
    }

    String? authCode;
    try {
      authCode = await _activeAuthCompleter!.future.timeout(const Duration(minutes: 5));
    } finally {
      // 커스텀 탭 닫기 시도
      try {
        await closeInAppWebView();
      } catch (_) {}

      // 브라우저가 응답 HTML을 수신할 수 있도록 잠시 대기 후 서버 정리
      await Future.delayed(const Duration(milliseconds: 500));
      await serverIpv4.close(force: true);
      await serverIpv6?.close(force: true);
      _activeAuthCompleter = null;
    }

    return authCode;
  }

  static Future<http.Response> postWithRetry(
    Uri uri, {
    Map<String, String>? headers,
    Object? body,
    int maxAttempts = 8,
  }) async {
    dynamic lastError;
    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        final res = await http.post(uri, headers: headers, body: body);
        return res;
      } on SocketException catch (e) {
        lastError = e;
        if (attempt == maxAttempts) rethrow;
        await Future.delayed(Duration(milliseconds: 1000 + (500 * attempt)));
      } catch (e) {
        lastError = e;
        if (attempt == maxAttempts) rethrow;
        await Future.delayed(Duration(milliseconds: 1000 + (500 * attempt)));
      }
    }
    throw lastError ?? Exception('네트워크 요청 실패: $uri');
  }

  /// Google Drive OAuth 토큰 교환
  static Future<Map<String, dynamic>> exchangeGoogleToken({
    required String code,
    required String redirectUri,
    required String clientId,
    String? clientSecret,
    required String codeVerifier,
  }) async {
    final body = {
      'client_id': clientId,
      'code': code,
      'grant_type': 'authorization_code',
      'redirect_uri': redirectUri,
      'code_verifier': codeVerifier,
    };
    if (clientSecret != null && clientSecret.isNotEmpty) {
      body['client_secret'] = clientSecret;
    }

    final res = await postWithRetry(
      Uri.parse('https://oauth2.googleapis.com/token'),
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: body,
    );

    if (res.statusCode != 200) {
      throw Exception('구글 토큰 발급 실패 (${res.statusCode}): ${res.body}');
    }
    return jsonDecode(res.body);
  }

  /// OneDrive OAuth 토큰 교환
  static Future<Map<String, dynamic>> exchangeOneDriveToken({
    required String code,
    required String redirectUri,
    required String clientId,
    String? clientSecret,
    required String codeVerifier,
  }) async {
    final body = {
      'client_id': clientId,
      'code': code,
      'grant_type': 'authorization_code',
      'redirect_uri': redirectUri,
      'code_verifier': codeVerifier,
    };
    if (clientSecret != null && clientSecret.isNotEmpty) {
      body['client_secret'] = clientSecret;
    }

    final res = await postWithRetry(
      Uri.parse('https://login.microsoftonline.com/common/oauth2/v2.0/token'),
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: body,
    );

    if (res.statusCode != 200) {
      throw Exception('원드라이브 토큰 발급 실패 (${res.statusCode}): ${res.body}');
    }
    return jsonDecode(res.body);
  }
}
