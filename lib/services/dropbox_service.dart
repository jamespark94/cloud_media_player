import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/media_item.dart';
import 'cloud_service_interface.dart';
import 'oauth_helper.dart';

class DropboxService extends CloudService {
  DropboxService(super.account, {super.onAccountUpdated});

  // Dropbox OAuth 기본 Public Client ID (BYOK 지원)
  static const String defaultClientId = '5jcck7diasz0rqy';
  static const String authEndpoint = 'https://www.dropbox.com/oauth2/authorize';
  static const String tokenEndpoint = 'https://api.dropboxapi.com/oauth2/token';

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
        final expiresIn = data['expires_in'] as int? ?? 14400;
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
    final targetPath = (folderId == null || folderId == 'root' || folderId == '/' || folderId.isEmpty)
        ? ''
        : folderId;

    final url = 'https://api.dropboxapi.com/2/files/list_folder';
    final body = jsonEncode({
      'path': targetPath,
      'recursive': false,
      'include_media_info': true,
      'include_deleted': false,
    });

    final res = await http.post(
      Uri.parse(url),
      headers: {
        'Authorization': 'Bearer ${account.accessToken}',
        'Content-Type': 'application/json',
      },
      body: body,
    );

    if (res.statusCode != 200) {
      throw Exception('Dropbox 파일 목록 조회 실패 (${res.statusCode}): ${res.body}');
    }

    final data = jsonDecode(res.body);
    final entries = (data['entries'] as List<dynamic>? ?? []);

    return entries.map((entry) {
      final tag = entry['.tag'] as String? ?? 'file';
      final isFolder = tag == 'folder';
      final pathLower = entry['path_lower'] as String? ?? entry['id'] as String;
      final name = entry['name'] as String? ?? 'Unnamed';
      final size = entry['size'] != null ? int.tryParse(entry['size'].toString()) : null;
      final serverModified = entry['server_modified'] != null
          ? DateTime.tryParse(entry['server_modified'] as String)
          : null;

      Duration? duration;
      final mediaInfo = entry['media_info'] as Map<String, dynamic>?;
      if (mediaInfo != null) {
        final meta = mediaInfo['metadata'] as Map<String, dynamic>?;
        final durMs = meta?['duration'] as int?;
        if (durMs != null && durMs > 0) {
          duration = Duration(milliseconds: durMs);
        }
      }

      return MediaItem(
        id: pathLower,
        name: name,
        parentId: targetPath.isEmpty ? 'root' : targetPath,
        isFolder: isFolder,
        size: size,
        modifiedTime: serverModified,
        duration: duration,
      );
    }).toList();
  }

  @override
  Future<String> getStreamUrl(MediaItem item) async {
    await refreshTokensIfNeeded();

    // 1. 이미 캐시된 직링크가 유효한 경우
    if (item.directStreamUrl != null && item.directStreamUrl!.isNotEmpty) {
      return item.directStreamUrl!;
    }

    // 2. Dropbox 임시 직링크 API 요청 (4시간 유효, CDN 직접 스트리밍 및 Range 헤더 완벽 지원)
    final url = 'https://api.dropboxapi.com/2/files/get_temporary_link';
    final res = await http.post(
      Uri.parse(url),
      headers: {
        'Authorization': 'Bearer ${account.accessToken}',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'path': item.id}),
    );

    if (res.statusCode == 200) {
      final data = jsonDecode(res.body);
      final link = data['link'] as String?;
      if (link != null && link.isNotEmpty) {
        return link;
      }
    }

    // 폴백
    return 'https://content.dropboxapi.com/2/files/download';
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
    return null;
  }
}
