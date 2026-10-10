import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/media_item.dart';
import 'cloud_service_interface.dart';
import 'oauth_helper.dart';

class GoogleDriveService extends CloudService {
  GoogleDriveService(super.account, {super.onAccountUpdated});

  static const String defaultClientId =
      '952086025939-8rgvb7og9u671j4h14pu5kp52db72hve.apps.googleusercontent.com';
  static const String defaultClientSecret = '';
  static const String authEndpoint = 'https://accounts.google.com/o/oauth2/v2/auth';
  static const String tokenEndpoint = 'https://oauth2.googleapis.com/token';

  String get activeClientId => account.customClientId?.isNotEmpty == true
      ? account.customClientId!
      : defaultClientId;

  String? get activeClientSecret => account.customClientSecret?.isNotEmpty == true
      ? account.customClientSecret!
      : defaultClientSecret;

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
      if (activeClientSecret?.isNotEmpty == true) {
        body['client_secret'] = activeClientSecret!;
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

  @override
  Future<bool> renameItem(MediaItem item, String newName) async {
    try {
      await refreshTokensIfNeeded();
      final url = 'https://www.googleapis.com/drive/v3/files/${item.id}';
      final headers = Map<String, String>.from(await getStreamHeaders())..['Content-Type'] = 'application/json';
      final res = await http.patch(Uri.parse(url), headers: headers, body: jsonEncode({'name': newName}));
      return res.statusCode == 200;
    } catch (e) {
      debugPrint('[GoogleDriveService] 이름 변경 실패: $e');
    }
    return false;
  }

  @override
  Future<bool> deleteItem(MediaItem item) async {
    try {
      await refreshTokensIfNeeded();
      final url = 'https://www.googleapis.com/drive/v3/files/${item.id}';
      final res = await http.delete(Uri.parse(url), headers: await getStreamHeaders());
      return res.statusCode == 204 || res.statusCode == 200;
    } catch (e) {
      debugPrint('[GoogleDriveService] 삭제 실패: $e');
    }
    return false;
  }

  @override
  Future<bool> moveItem(
    MediaItem item,
    String targetFolderId, {
    String? newName,
    bool overwrite = false,
  }) async {
    try {
      await refreshTokensIfNeeded();
      final oldParent = item.parentId ?? 'root';
      final url = 'https://www.googleapis.com/drive/v3/files/${item.id}?addParents=$targetFolderId&removeParents=$oldParent';
      final headers = Map<String, String>.from(await getStreamHeaders())..['Content-Type'] = 'application/json';
      final bodyMap = (newName != null && newName.isNotEmpty && newName != item.name)
          ? {'name': newName}
          : null;
      final res = await http.patch(
        Uri.parse(url),
        headers: headers,
        body: bodyMap != null ? jsonEncode(bodyMap) : null,
      );
      return res.statusCode == 200;
    } catch (e) {
      debugPrint('[GoogleDriveService] 이동 실패: $e');
    }
    return false;
  }

  @override
  Future<bool> copyItem(
    MediaItem item,
    String targetFolderId, {
    String? newName,
    bool overwrite = false,
  }) async {
    try {
      await refreshTokensIfNeeded();
      final url = 'https://www.googleapis.com/drive/v3/files/${item.id}/copy';
      final headers = Map<String, String>.from(await getStreamHeaders())..['Content-Type'] = 'application/json';
      final bodyMap = <String, dynamic>{
        'parents': [targetFolderId],
      };
      if (newName != null && newName.isNotEmpty) {
        bodyMap['name'] = newName;
      }
      final res = await http.post(Uri.parse(url), headers: headers, body: jsonEncode(bodyMap));
      return res.statusCode == 200;
    } catch (e) {
      debugPrint('[GoogleDriveService] 복사 실패: $e');
    }
    return false;
  }

  @override
  Future<bool> createFolder(String folderName, {String? parentFolderId}) async {
    try {
      await refreshTokensIfNeeded();
      final parent = (parentFolderId != null && parentFolderId.isNotEmpty) ? parentFolderId : 'root';
      final url = 'https://www.googleapis.com/drive/v3/files';
      final headers = Map<String, String>.from(await getStreamHeaders())..['Content-Type'] = 'application/json';
      final body = jsonEncode({
        'name': folderName,
        'mimeType': 'application/vnd.google-apps.folder',
        'parents': [parent],
      });
      final res = await http.post(Uri.parse(url), headers: headers, body: body);
      return res.statusCode == 200;
    } catch (e) {
      debugPrint('[GoogleDriveService] 새 폴더 생성 실패: $e');
    }
    return false;
  }
}
