import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/media_item.dart';
import 'cloud_service_interface.dart';
import 'google_auth_manager.dart';
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
      : (activeClientId == defaultClientId ? defaultClientSecret : null);

  bool get _preferNativeSignIn =>
      (!kIsWeb && (Platform.isAndroid || Platform.isIOS) && (account.customClientId == null || account.customClientId!.isEmpty)) ||
      account.refreshToken == null ||
      account.refreshToken!.isEmpty ||
      account.refreshToken == 'google_sign_in';

  /// 네이티브 GoogleSignIn 또는 OAuth Refresh Token을 통해 토큰을 최신 상태로 유지
  @override
  Future<bool> refreshTokensIfNeeded() async {
    // 1. 모바일(Android/iOS) 또는 네이티브 GoogleSignIn 계정인 경우 GoogleAuthManager 최우선 사용
    if (_preferNativeSignIn) {
      try {
        final token = await GoogleAuthManager().getAccessToken();
        if (token != null && token.isNotEmpty) {
          account.accessToken = token;
          account.refreshToken = 'google_sign_in';
          account.tokenExpiry = DateTime.now().add(const Duration(minutes: 50));
          await onAccountUpdated?.call(account);
          return true;
        }
      } catch (e) {
        debugPrint('[GoogleDriveService] GoogleAuthManager token check: $e');
      }
    }

    if (!account.isTokenExpired && account.accessToken.isNotEmpty) return true;

    // 2. OAuth Refresh Token이 있는 경우 (PC 또는 커스텀 API 키 루프백 방식)
    if (account.refreshToken != null &&
        account.refreshToken!.isNotEmpty &&
        account.refreshToken != 'google_sign_in') {
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
    }

    // 3. 마지막 폴백으로 네이티브 GoogleSignIn 강제 갱신(또는 대화형 복구) 시도
    try {
      final headers = await GoogleAuthManager().refreshAuthHeaders();
      final auth = headers['Authorization'];
      if (auth != null && auth.startsWith('Bearer ')) {
        account.accessToken = auth.substring(7).trim();
        account.refreshToken = 'google_sign_in';
        account.tokenExpiry = DateTime.now().add(const Duration(minutes: 50));
        await onAccountUpdated?.call(account);
        return true;
      }
    } catch (_) {
      if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
        try {
          final signedIn = await GoogleAuthManager().signIn();
          if (signedIn != null) {
            final token = await GoogleAuthManager().getAccessToken();
            if (token != null && token.isNotEmpty) {
              account.accessToken = token;
              account.refreshToken = 'google_sign_in';
              account.tokenExpiry = DateTime.now().add(const Duration(minutes: 50));
              await onAccountUpdated?.call(account);
              return true;
            }
          }
        } catch (_) {}
      }
    }

    return account.accessToken.isNotEmpty;
  }

  /// 401 발생 시 네이티브 캐시 파기 또는 OAuth 토큰 강제 재발급
  Future<bool> _forceRefreshOn401() async {
    account.tokenExpiry = DateTime.now().subtract(const Duration(minutes: 5));
    if (_preferNativeSignIn) {
      try {
        final headers = await GoogleAuthManager().refreshAuthHeaders();
        final auth = headers['Authorization'];
        if (auth != null && auth.startsWith('Bearer ')) {
          account.accessToken = auth.substring(7).trim();
          account.refreshToken = 'google_sign_in';
          account.tokenExpiry = DateTime.now().add(const Duration(minutes: 50));
          await onAccountUpdated?.call(account);
          return true;
        }
      } catch (_) {
        if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
          try {
            final signedIn = await GoogleAuthManager().signIn();
            if (signedIn != null) {
              final token = await GoogleAuthManager().getAccessToken();
              if (token != null && token.isNotEmpty) {
                account.accessToken = token;
                account.refreshToken = 'google_sign_in';
                account.tokenExpiry = DateTime.now().add(const Duration(minutes: 50));
                await onAccountUpdated?.call(account);
                return true;
              }
            }
          } catch (_) {}
        }
      }
    }
    return await refreshTokensIfNeeded();
  }

  @override
  Future<List<MediaItem>> listItems({String? folderId}) async {
    await refreshTokensIfNeeded();
    final parent = (folderId == null || folderId.isEmpty) ? 'root' : folderId;
    final query = Uri.encodeComponent("'$parent' in parents and trashed = false");
    final url =
        'https://www.googleapis.com/drive/v3/files?q=$query&fields=files(id,name,mimeType,size,thumbnailLink,modifiedTime,videoMediaMetadata)&orderBy=folder,name&pageSize=1000';

    var res = await http.get(
      Uri.parse(url),
      headers: await getStreamHeaders(),
    );

    if (res.statusCode == 401) {
      await _forceRefreshOn401();
      res = await http.get(
        Uri.parse(url),
        headers: await getStreamHeaders(),
      );
    }

    if (res.statusCode != 200) {
      throw Exception('구글 드라이브 파일 목록 조회 실패 (${res.statusCode}): ${res.body}');
    }

    final data = jsonDecode(utf8.decode(res.bodyBytes));
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
    if (account.isTokenExpired || account.accessToken.isEmpty) {
      await refreshTokensIfNeeded();
    }
    return {
      'Authorization': 'Bearer ${account.accessToken}',
    };
  }

  @override
  Future<String?> getThumbnailUrl(MediaItem item) async {
    try {
      await refreshTokensIfNeeded();
      final url = 'https://www.googleapis.com/drive/v3/files/${item.id}?fields=thumbnailLink';
      var res = await http.get(Uri.parse(url), headers: await getStreamHeaders());
      if (res.statusCode == 401) {
        await _forceRefreshOn401();
        res = await http.get(Uri.parse(url), headers: await getStreamHeaders());
      }
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
