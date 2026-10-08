import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

class OAuthHelper {
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

  /// 로컬 루프백 서버를 열어 브라우저 인증 후 리디렉트된 인가 코드(Auth Code)를 수신합니다.
  static Future<String?> authenticateWithLoopback({
    required String authUrlWithoutParams,
    required Map<String, String> params,
    int port = 8999,
  }) async {
    HttpServer? server;
    try {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    } catch (e) {
      // 포트가 사용 중인 경우 자동 바인드
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    }

    final redirectUri = 'http://localhost:${server.port}/callback';
    params['redirect_uri'] = redirectUri;

    final uri = Uri.parse(authUrlWithoutParams).replace(queryParameters: params);

    // 기본 웹 브라우저에서 인증 URL 실행
    bool launched = false;
    try {
      if (await canLaunchUrl(uri)) {
        launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
      if (!launched) {
        launched = await launchUrl(uri, mode: LaunchMode.platformDefault);
      }
    } catch (_) {
      try {
        launched = await launchUrl(uri);
      } catch (e) {
        await server.close();
        throw Exception('브라우저를 열 수 없습니다: $e');
      }
    }

    if (!launched) {
      await server.close();
      throw Exception('브라우저를 열 수 없습니다: $uri');
    }

    String? authCode;
    try {
      await for (var request in server.timeout(const Duration(minutes: 3))) {
        if (request.uri.path == '/callback') {
          authCode = request.uri.queryParameters['code'];
          final error = request.uri.queryParameters['error'];

          request.response.headers.contentType = ContentType.html;
          if (authCode != null) {
            request.response.write('''
              <html>
                <body style="font-family:sans-serif;text-align:center;padding:50px;background:#121212;color:#ffffff;">
                  <h2 style="color:#4CAF50;">✓ 인증이 성공적으로 완료되었습니다!</h2>
                  <p>이 창을 닫고 클라우드 미디어 플레이어 앱으로 돌아가세요.</p>
                  <script>window.setTimeout(function(){ window.close(); }, 3000);</script>
                </body>
              </html>
            ''');
          } else {
            request.response.write('''
              <html>
                <body style="font-family:sans-serif;text-align:center;padding:50px;background:#121212;color:#ff5252;">
                  <h2>인증 실패</h2>
                  <p>오류: ${error ?? '알 수 없는 오류'}</p>
                </body>
              </html>
            ''');
          }
          await request.response.close();
          break;
        }
      }
    } finally {
      await server.close();
    }

    return authCode;
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

    final res = await http.post(
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

    final res = await http.post(
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
