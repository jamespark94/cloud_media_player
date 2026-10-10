import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../models/media_item.dart';
import 'cloud_service_interface.dart';
import 'oauth_helper.dart';

class BoxService extends CloudService {
  BoxService(super.account, {super.onAccountUpdated});

  // Box OAuth 기본 Public Client ID (BYOK 지원)
  static const String defaultClientId = 'd0374ba6pgmaguie02ge15sv1mllndho';
  static const String authEndpoint = 'https://app.box.com/api/oauth2/authorize';
  static const String tokenEndpoint = 'https://app.box.com/api/oauth2/token';

  String get activeClientId => account.customClientId?.isNotEmpty == true
      ? account.customClientId!
      : defaultClientId;

  @override
  Future<bool> refreshTokensIfNeeded() async {
    if (!account.isTokenExpired) return true;
    if (account.refreshToken == null || account.refreshToken!.isEmpty) return false;

    try {
      final body = {
        'client_id': activeClientId,
        'refresh_token': account.refreshToken!,
        'grant_type': 'refresh_token',
      };
      if (account.customClientSecret?.isNotEmpty == true) {
        body['client_secret'] = account.customClientSecret!;
      }

      final res = await OAuthHelper.postWithRetry(
        Uri.parse(tokenEndpoint),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: body,
      );

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        account.accessToken = data['access_token'];
        if (data['refresh_token'] != null && (data['refresh_token'] as String).isNotEmpty) {
          account.refreshToken = data['refresh_token'];
        }
        final expiresIn = data['expires_in'] as int? ?? 3600;
        account.tokenExpiry = DateTime.now().add(Duration(seconds: expiresIn));
        await onAccountUpdated?.call(account);
        return true;
      }
    } catch (_) {}
    return false;
  }

  @override
  Future<List<MediaItem>> listItems({String? folderId}) async {
    await refreshTokensIfNeeded();
    final targetFolderId = (folderId == null || folderId.isEmpty || folderId == 'root') ? '0' : folderId;

    final url = 'https://api.box.com/2.0/folders/$targetFolderId/items?fields=id,type,name,size,modified_at,item_status&limit=1000';

    final res = await http.get(
      Uri.parse(url),
      headers: await getStreamHeaders(),
    );

    if (res.statusCode != 200) {
      throw Exception('Box 파일 목록 조회 실패 (${res.statusCode}): ${res.body}');
    }

    final data = jsonDecode(res.body);
    final entries = (data['entries'] as List<dynamic>? ?? []);

    return entries.map((entry) {
      final type = entry['type'] as String? ?? 'file';
      final isFolder = type == 'folder';
      final id = entry['id'] as String;
      final name = entry['name'] as String? ?? 'Unnamed';
      final size = entry['size'] != null ? int.tryParse(entry['size'].toString()) : null;
      final modifiedAt = entry['modified_at'] != null ? DateTime.tryParse(entry['modified_at'] as String) : null;

      String? thumbUrl;
      if (!isFolder) {
        thumbUrl = 'https://api.box.com/2.0/files/$id/thumbnail.png?min_height=256&min_width=256';
      }

      return MediaItem(
        id: id,
        name: name,
        parentId: targetFolderId,
        isFolder: isFolder,
        size: size,
        thumbnailUrl: thumbUrl,
        modifiedTime: modifiedAt,
      );
    }).toList();
  }

  @override
  Future<String> getStreamUrl(MediaItem item) async {
    await refreshTokensIfNeeded();

    // 이미 직접 스트리밍 링크가 있다면 우선 반환
    if (item.directStreamUrl != null && item.directStreamUrl!.isNotEmpty) {
      return item.directStreamUrl!;
    }

    // Box는 /files/{id}/content 호출 시 302 Found 로 고속 CDN 직링크를 Location 헤더로 전달합니다.
    try {
      final client = HttpClient();
      final request = await client.getUrl(Uri.parse('https://api.box.com/2.0/files/${item.id}/content'));
      request.followRedirects = false;
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${account.accessToken}');

      final response = await request.close();
      final location = response.headers.value(HttpHeaders.locationHeader);
      client.close();

      if (location != null && location.isNotEmpty) {
        return location;
      }
    } catch (_) {}

    return 'https://api.box.com/2.0/files/${item.id}/content';
  }

  @override
  Future<Map<String, String>> getStreamHeaders() async {
    return {
      'Authorization': 'Bearer ${account.accessToken}',
    };
  }

  @override
  Future<String?> getThumbnailUrl(MediaItem item) async {
    if (item.isFolder) return null;
    return 'https://api.box.com/2.0/files/${item.id}/thumbnail.png?min_height=256&min_width=256';
  }
}
