import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/media_item.dart';
import 'cloud_service_interface.dart';
import 'oauth_helper.dart';

class GoogleDriveService extends CloudService {
  GoogleDriveService(super.account, {super.onAccountUpdated});

  static const String defaultClientId =
      '849319808940-5m9i1p7om6o62e3tgh8c8r6r0k9g7mgh.apps.googleusercontent.com'; // Standard public fallback
  static const String authEndpoint = 'https://accounts.google.com/o/oauth2/v2/auth';
  static const String tokenEndpoint = 'https://oauth2.googleapis.com/token';

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
    final parent = folderId ?? 'root';
    final query = Uri.encodeComponent("'$parent' in parents and trashed = false");
    final url =
        'https://www.googleapis.com/drive/v3/files?q=$query&fields=files(id,name,mimeType,size,thumbnailLink,modifiedTime,videoMediaMetadata)&orderBy=folder,name';

    final res = await http.get(
      Uri.parse(url),
      headers: await getStreamHeaders(),
    );

    if (res.statusCode != 200) {
      throw Exception('구글 드라이브 파일 목록 조회 실패 (${res.statusCode}): ${res.body}');
    }

    final data = jsonDecode(res.body);
    final files = (data['files'] as List<dynamic>? ?? []);

    return files.map((f) {
      final mime = f['mimeType'] as String? ?? '';
      final isFolder = mime == 'application/vnd.google-apps.folder';
      final size = f['size'] != null ? int.tryParse(f['size'].toString()) : null;

      final vMeta = f['videoMediaMetadata'] as Map<String, dynamic>?;
      Duration? duration;
      if (vMeta != null && vMeta['durationMillis'] != null) {
        final ms = int.tryParse(vMeta['durationMillis'].toString());
        if (ms != null && ms > 0) {
          duration = Duration(milliseconds: ms);
        }
      }

      return MediaItem(
        id: f['id'] as String,
        name: f['name'] as String,
        parentId: parent,
        isFolder: isFolder,
        size: size,
        mimeType: mime,
        thumbnailUrl: f['thumbnailLink'] as String?,
        modifiedTime: f['modifiedTime'] != null
            ? DateTime.tryParse(f['modifiedTime'] as String)
            : null,
        duration: duration,
      );
    }).toList();
  }

  @override
  Future<String> getStreamUrl(MediaItem item) async {
    await refreshTokensIfNeeded();
    // Google Drive v3 download direct endpoint with alt=media
    return 'https://www.googleapis.com/drive/v3/files/${item.id}?alt=media';
  }

  @override
  Future<Map<String, String>> getStreamHeaders() async {
    return {
      'Authorization': 'Bearer ${account.accessToken}',
    };
  }

  @override
  Future<String?> getThumbnailUrl(MediaItem item) async {
    try {
      await refreshTokensIfNeeded();
      final url = 'https://www.googleapis.com/drive/v3/files/${item.id}?fields=thumbnailLink';
      final res = await http.get(Uri.parse(url), headers: await getStreamHeaders());
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final link = data['thumbnailLink'] as String?;
        if (link != null && link.isNotEmpty) {
          return link.replaceAll(RegExp(r'=s\d+'), '=s400');
        }
      }
    } catch (_) {}
    return null;
  }
}
