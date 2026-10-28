import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/media_item.dart';
import '../models/video_quality.dart';
import '../services/cloud_service_interface.dart';
import '../services/google_auth_manager.dart';

/// 구글 드라이브 스토리지 프로바이더
/// 공식 google_sign_in 기반 GoogleAuthManager와 연동하여
/// 미디어 파일 목록 조회 및 스트리밍(HTTP Range 지원) 헤더를 주입합니다.
class GoogleDriveStorageProvider extends CloudService {
  final GoogleAuthManager _authManager;

  GoogleDriveStorageProvider(
    super.account, {
    super.onAccountUpdated,
    GoogleAuthManager? authManager,
  }) : _authManager = authManager ?? GoogleAuthManager();

  static const String driveApiBase = 'https://www.googleapis.com/drive/v3';

  /// 토큰 만료 여부 확인 및 무음 갱신
  @override
  Future<bool> refreshTokensIfNeeded() async {
    try {
      final headers = await _authManager.getAuthHeaders();
      return headers.containsKey('Authorization');
    } catch (e) {
      debugPrint('[GoogleDriveStorageProvider] refreshTokensIfNeeded failed: $e');
      return false;
    }
  }

  /// 파일/폴더 목록 조회
  @override
  Future<List<MediaItem>> listItems({String? folderId}) async {
    final parent = (folderId == null || folderId.isEmpty) ? 'root' : folderId;
    final query = Uri.encodeComponent("'$parent' in parents and trashed = false");
    final url =
        '$driveApiBase/files?q=$query&fields=files(id,name,mimeType,size,thumbnailLink,modifiedTime,videoMediaMetadata)&orderBy=folder,name&pageSize=1000';

    var headers = await getStreamHeaders();
    var res = await http.get(Uri.parse(url), headers: headers);

    // 401 Unauthorized 처리 시 강제 토큰 갱신 후 1회 재시도
    if (res.statusCode == 401) {
      debugPrint('[GoogleDriveStorageProvider] 401 encountered, refreshing auth headers...');
      headers = await _authManager.refreshAuthHeaders();
      res = await http.get(Uri.parse(url), headers: headers);
    }

    if (res.statusCode != 200) {
      throw Exception('구글 드라이브 파일 목록 조회 실패 (${res.statusCode}): ${res.body}');
    }

    final data = jsonDecode(utf8.decode(res.bodyBytes));
    final files = (data['files'] as List<dynamic>? ?? []);

    return files.map((f) {
      final isFolder = f['mimeType'] == 'application/vnd.google-apps.folder';
      int? size;
      if (f['size'] != null) {
        size = int.tryParse(f['size'].toString());
      }

      DateTime? modified;
      if (f['modifiedTime'] != null) {
        modified = DateTime.tryParse(f['modifiedTime']);
      }

      Duration? duration;
      if (f['videoMediaMetadata'] != null &&
          f['videoMediaMetadata']['durationMillis'] != null) {
        final ms = int.tryParse(f['videoMediaMetadata']['durationMillis'].toString());
        if (ms != null) {
          duration = Duration(milliseconds: ms);
        }
      }

      return MediaItem(
        id: f['id'],
        name: f['name'] ?? '알 수 없는 파일',
        parentId: parent,
        isFolder: isFolder,
        size: size,
        mimeType: f['mimeType'],
        thumbnailUrl: f['thumbnailLink'],
        modifiedTime: modified,
        duration: duration,
      );
    }).toList();
  }

  /// 미디어 플레이어 및 이미지 뷰어용 스트리밍 직링크 반환
  @override
  Future<String> getStreamUrl(MediaItem item) async {
    // Google Drive v3 alt=media 엔드포인트
    return '$driveApiBase/files/${item.id}?alt=media';
  }

  /// 비디오 플레이어(ExoPlayer / media_kit) 및 HTTP 통신용 인증 + Range 헤더 주입
  @override
  Future<Map<String, String>> getStreamHeaders() async {
    final authHeaders = await _authManager.getAuthHeaders();
    return {
      ...authHeaders,
      'Accept': '*/*',
    };
  }

  /// 특정 범위(Range)를 요구하는 스트리밍 헤더 생성 (비디오 시크 및 청크 다운로드용)
  Future<Map<String, String>> getStreamHeadersWithRange(int startByte, [int? endByte]) async {
    final headers = await getStreamHeaders();
    final rangeValue = endByte != null
        ? 'bytes=$startByte-$endByte'
        : 'bytes=$startByte-';
    headers['Range'] = rangeValue;
    return headers;
  }

  /// 만화/이미지/압축파일 다운로드 (401 자동 복구 지원)
  @override
  Future<Uint8List> downloadBytes(MediaItem item) async {
    final url = await getStreamUrl(item);
    var headers = await getStreamHeaders();
    var res = await http.get(Uri.parse(url), headers: headers);

    if (res.statusCode == 401) {
      headers = await _authManager.refreshAuthHeaders();
      res = await http.get(Uri.parse(url), headers: headers);
    }

    if (res.statusCode == 200 || res.statusCode == 206) {
      return res.bodyBytes;
    }
    throw Exception('파일 다운로드 실패 (${res.statusCode}): ${res.body}');
  }

  @override
  Future<List<VideoQuality>> getAvailableQualities(MediaItem item) async => const [
        VideoQuality.original,
      ];

  @override
  VideoQuality getDefaultPlaybackQuality() => VideoQuality.original;

  @override
  Future<bool> deleteItem(MediaItem item) async {
    final url = '$driveApiBase/files/${item.id}';
    final headers = await getStreamHeaders();
    final res = await http.delete(Uri.parse(url), headers: headers);
    return res.statusCode == 204 || res.statusCode == 200;
  }

  @override
  Future<bool> renameItem(MediaItem item, String newName) async {
    final url = '$driveApiBase/files/${item.id}';
    final headers = await getStreamHeaders();
    headers['Content-Type'] = 'application/json';
    final res = await http.patch(
      Uri.parse(url),
      headers: headers,
      body: jsonEncode({'name': newName}),
    );
    return res.statusCode == 200;
  }
}
