import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/media_item.dart';
import 'cloud_service_interface.dart';
import 'oauth_helper.dart';

class OneDriveService extends CloudService {
  OneDriveService(super.account, {super.onAccountUpdated});

  static const String defaultClientId = 'd3590ed6-52b3-4102-aeff-aad22ac2ab01'; // Public MS Graph client id fallback
  static const String tokenEndpoint = 'https://login.microsoftonline.com/common/oauth2/v2.0/token';

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
    final url = (folderId == null || folderId == 'root')
        ? 'https://graph.microsoft.com/v1.0/me/drive/root/children?expand=thumbnails'
        : 'https://graph.microsoft.com/v1.0/me/drive/items/$folderId/children?expand=thumbnails';

    final res = await http.get(
      Uri.parse(url),
      headers: await getStreamHeaders(),
    );

    if (res.statusCode != 200) {
      throw Exception('원드라이브 파일 목록 조회 실패 (${res.statusCode}): ${res.body}');
    }

    final data = jsonDecode(res.body);
    final items = (data['value'] as List<dynamic>? ?? []);

    return items.map((f) {
      final isFolder = f.containsKey('folder');
      final size = f['size'] != null ? int.tryParse(f['size'].toString()) : null;
      final downloadUrl = f['@microsoft.graph.downloadUrl'] as String?;
      final thumbnails = f['thumbnails'] as List<dynamic>?;
      String? thumbUrl;
      if (thumbnails != null && thumbnails.isNotEmpty) {
        final t = thumbnails[0];
        thumbUrl = (t['large']?['url'] ?? t['medium']?['url'] ?? t['small']?['url']) as String?;
      }

      final video = f['video'] as Map<String, dynamic>?;
      Duration? duration;
      if (video != null && video['duration'] != null) {
        final ms = int.tryParse(video['duration'].toString());
        if (ms != null && ms > 0) {
          duration = Duration(milliseconds: ms);
        }
      }

      return MediaItem(
        id: f['id'] as String,
        name: f['name'] as String,
        parentId: folderId ?? 'root',
        isFolder: isFolder,
        size: size,
        thumbnailUrl: thumbUrl,
        directStreamUrl: downloadUrl,
        modifiedTime: f['lastModifiedDateTime'] != null
            ? DateTime.tryParse(f['lastModifiedDateTime'] as String)
            : null,
        duration: duration,
      );
    }).toList();
  }

  @override
  Future<String> getStreamUrl(MediaItem item) async {
    await refreshTokensIfNeeded();
    // 1. 이미 다운로드 URL이 캐시되어 있는 경우
    if (item.directStreamUrl != null && item.directStreamUrl!.isNotEmpty) {
      return item.directStreamUrl!;
    }

    // 2. 항목 메타데이터에서 다운로드 URL 새로 요청
    final url = 'https://graph.microsoft.com/v1.0/me/drive/items/${item.id}';
    final res = await http.get(
      Uri.parse(url),
      headers: await getStreamHeaders(),
    );

    if (res.statusCode == 200) {
      final data = jsonDecode(res.body);
      final downloadUrl = data['@microsoft.graph.downloadUrl'] as String?;
      if (downloadUrl != null) return downloadUrl;
    }

    // 대체 스트림 URL
    return 'https://graph.microsoft.com/v1.0/me/drive/items/${item.id}/content';
  }

  @override
  Future<Map<String, String>> getStreamHeaders() async {
    return {
      'Authorization': 'Bearer ${account.accessToken}',
    };
  }

  @override
  Future<String?> getThumbnailUrl(MediaItem item) async {
    if (item.thumbnailUrl != null && item.thumbnailUrl!.isNotEmpty) {
      return item.thumbnailUrl;
    }
    try {
      await refreshTokensIfNeeded();
      final url = 'https://graph.microsoft.com/v1.0/me/drive/items/${item.id}/thumbnails';
      final res = await http.get(Uri.parse(url), headers: await getStreamHeaders());
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final list = data['value'] as List<dynamic>?;
        if (list != null && list.isNotEmpty) {
          final t = list[0];
          return (t['large']?['url'] ?? t['medium']?['url'] ?? t['small']?['url']) as String?;
        }
      }
    } catch (_) {}
    return null;
  }
}
