import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/cloud_account.dart';
import 'account_manager.dart';
import 'cloud_service_interface.dart';
import 'playback_history_service.dart';

/// 클라우드 기반 디바이스 간 미디어 재생 기록(히스토리) 동기화 서비스
/// 클라우드 스토리지 루트의 `media_play_history.json` 파일을 사용하여
/// PC, 태블릿, 스마트폰 등 다중 기기 간 동영상 이어보기 진도를 자동/수동 동기화합니다.
class CloudPlaybackSyncService extends ChangeNotifier {
  static CloudPlaybackSyncService? _instance;
  static CloudPlaybackSyncService get instance => _instance ??= CloudPlaybackSyncService._();

  CloudPlaybackSyncService._();

  static const String syncFileName = 'media_play_history.json';

  bool _isSyncing = false;
  bool get isSyncing => _isSyncing;

  DateTime? _lastSyncTime;
  DateTime? get lastSyncTime => _lastSyncTime;

  String? _lastSyncMessage;
  String? get lastSyncMessage => _lastSyncMessage;

  Timer? _autoPushDebounceTimer;

  /// 진도 변경 시 3초 후 백그라운드로 자동 클라우드 푸시 예약
  void scheduleAutoPush(AccountManager accountManager) {
    _autoPushDebounceTimer?.cancel();
    _autoPushDebounceTimer = Timer(const Duration(seconds: 3), () {
      syncPlaybackRecords(accountManager, silent: true);
    });
  }

  /// 연결된 클라우드 계정과 동기화 실행 (Pull & Merge -> Push)
  Future<bool> syncPlaybackRecords(AccountManager accountManager, {bool silent = false}) async {
    if (_isSyncing) return false;

    final cloudAccounts = accountManager.accounts.where((a) => a.type != CloudType.local && a.type != CloudType.terabox && a.type != CloudType.baidu).toList();
    if (cloudAccounts.isEmpty) {
      _lastSyncMessage = '동기화할 클라우드 계정이 연결되어 있지 않습니다.';
      notifyListeners();
      return false;
    }

    _isSyncing = true;
    if (!silent) {
      _lastSyncMessage = '미디어 재생 기록 동기화 중...';
      notifyListeners();
    }

    bool anySuccess = false;
    int mergedCount = 0;
    String? permissionWarning;

    for (final account in cloudAccounts) {
      try {
        final service = accountManager.getService(account);
        final tokenOk = await service.refreshTokensIfNeeded();
        if (!tokenOk && account.type != CloudType.webDav) {
          debugPrint('[PlaybackSync] ${account.name} 토큰 갱신 실패');
          continue;
        }

        // 1. 원격 히스토리 파일 가져오기
        final remoteJsonStr = await _fetchRemoteHistoryJson(service, account);
        List<PlaybackRecord> remoteRecords = [];
        Map<String, int> remoteDeleted = {};

        if (remoteJsonStr != null && remoteJsonStr.isNotEmpty) {
          try {
            final data = jsonDecode(remoteJsonStr);
            final List<dynamic> list = data is Map ? (data['histories'] as List<dynamic>? ?? []) : (data as List<dynamic>);
            remoteRecords = list.map((e) => PlaybackRecord.fromJson(e as Map<String, dynamic>)).toList();
            if (data is Map && data['deletedRecords'] is Map) {
              final dMap = data['deletedRecords'] as Map<String, dynamic>;
              remoteDeleted = dMap.map((k, v) => MapEntry(k, (v as num).toInt()));
            }
            debugPrint('[PlaybackSync] 원격 재생기록 ${remoteRecords.length}개, 삭제기록 ${remoteDeleted.length}개 로드 완료 (${account.name})');
          } catch (e) {
            debugPrint('[PlaybackSync] 원격 JSON 파싱 실패: $e');
          }
        }

        // 2. 로컬 히스토리와 스마트 병합 (삭제 툼스톤 양방향 반영)
        final mergedList = await PlaybackHistoryService.instance.mergeWithRemote(
          remoteRecords,
          remoteDeletedRecords: remoteDeleted,
        );
        mergedCount = mergedList.length;

        // 3. 최신 병합본 및 삭제 목록을 원격 클라우드 루트에 업로드
        final allRecords = await PlaybackHistoryService.instance.getAllRecords();
        final localDeleted = await PlaybackHistoryService.instance.getDeletedRecords();
        final syncData = {
          'app': 'cloud_media_player',
          'version': 2,
          'device': defaultTargetPlatform.name,
          'updatedAt': DateTime.now().toUtc().toIso8601String(),
          'count': allRecords.length,
          'histories': allRecords.map((e) => e.toJson()).toList(),
          'deletedRecords': localDeleted,
        };
        final payload = jsonEncode(syncData);
        final uploadResult = await _uploadRemoteHistoryJson(service, account, payload);

        if (uploadResult.success) {
          anySuccess = true;
          debugPrint('[PlaybackSync] 클라우드 동기화 푸시 완료 (${account.name})');
        } else if (uploadResult.isPermissionError) {
          permissionWarning = '${account.name}의 쓰기 권한이 없습니다. 계정을 다시 연결해 주세요.';
        }
      } catch (e, stack) {
        debugPrint('[PlaybackSync] 계정(${account.name}) 동기화 예외: $e\n$stack');
      }
    }

    _isSyncing = false;
    if (anySuccess) {
      _lastSyncTime = DateTime.now();
      _lastSyncMessage = '동기화 완료 ($mergedCount개 영상 기록 동기화됨)';
    } else if (permissionWarning != null) {
      _lastSyncMessage = permissionWarning;
    } else {
      _lastSyncMessage = '동기화 실패: 네트워크 상태 또는 클라우드 연결을 확인해 주세요.';
    }
    notifyListeners();
    return anySuccess;
  }

  // ============================================================
  // 각 클라우드 스토리지별 원격 히스토리 읽기 (Fetch)
  // ============================================================
  Future<String?> _fetchRemoteHistoryJson(CloudService service, CloudAccount account) async {
    switch (account.type) {
      case CloudType.googleDrive:
        return await _fetchGoogleDrive(service, account);
      case CloudType.webDav:
        return await _fetchWebDav(service, account);
      case CloudType.oneDrive:
        return await _fetchOneDrive(service, account);
      case CloudType.dropbox:
        return await _fetchDropbox(service, account);
      default:
        return null;
    }
  }

  // ============================================================
  // 각 클라우드 스토리지별 원격 히스토리 쓰기 (Upload)
  // ============================================================
  Future<({bool success, bool isPermissionError})> _uploadRemoteHistoryJson(
    CloudService service,
    CloudAccount account,
    String jsonPayload,
  ) async {
    switch (account.type) {
      case CloudType.googleDrive:
        return await _uploadGoogleDrive(service, account, jsonPayload);
      case CloudType.webDav:
        return await _uploadWebDav(service, account, jsonPayload);
      case CloudType.oneDrive:
        return await _uploadOneDrive(service, account, jsonPayload);
      case CloudType.dropbox:
        return await _uploadDropbox(service, account, jsonPayload);
      default:
        return (success: false, isPermissionError: false);
    }
  }

  // ------------------------------------------------------------
  // Google Drive 구현 (루트 저장 및 읽기)
  // ------------------------------------------------------------
  Future<String?> _fetchGoogleDrive(CloudService service, CloudAccount account) async {
    final headers = await service.getStreamHeaders();

    final uri = Uri.https('www.googleapis.com', '/drive/v3/files', {
      'q': "name = '$syncFileName' and trashed = false and 'root' in parents",
      'fields': 'files(id, name)',
    });

    final res = await http.get(uri, headers: headers);
    if (res.statusCode == 200) {
      final files = (jsonDecode(res.body)['files'] as List<dynamic>? ?? []);
      if (files.isNotEmpty) {
        final fileId = files.first['id'] as String;
        final downloadRes = await http.get(
          Uri.parse('https://www.googleapis.com/drive/v3/files/$fileId?alt=media'),
          headers: headers,
        );
        if (downloadRes.statusCode == 200) {
          return utf8.decode(downloadRes.bodyBytes);
        }
      }
    }
    return null;
  }

  Future<({bool success, bool isPermissionError})> _uploadGoogleDrive(
    CloudService service,
    CloudAccount account,
    String payload,
  ) async {
    final headers = await service.getStreamHeaders();

    // 1. 기존 파일 검색
    String? fileId;
    final searchUri = Uri.https('www.googleapis.com', '/drive/v3/files', {
      'q': "name = '$syncFileName' and trashed = false",
      'fields': 'files(id, name)',
    });

    final searchRes = await http.get(searchUri, headers: headers);
    if (searchRes.statusCode == 401 || searchRes.statusCode == 403) {
      debugPrint('[PlaybackSync] 구글 드라이브 권한 오류: ${searchRes.statusCode} ${searchRes.body}');
      return (success: false, isPermissionError: true);
    }

    if (searchRes.statusCode == 200) {
      final files = (jsonDecode(searchRes.body)['files'] as List<dynamic>? ?? []);
      if (files.isNotEmpty) {
        fileId = files.first['id'] as String;
      }
    }

    if (fileId != null) {
      // 2. 기존 파일 내용 덮어쓰기 (PATCH)
      final updateRes = await http.patch(
        Uri.parse('https://www.googleapis.com/upload/drive/v3/files/$fileId?uploadType=media'),
        headers: {
          ...headers,
          'Content-Type': 'application/json; charset=utf-8',
        },
        body: utf8.encode(payload),
      );
      if (updateRes.statusCode == 200) {
        return (success: true, isPermissionError: false);
      }
      final isPerm = updateRes.statusCode == 401 || updateRes.statusCode == 403;
      return (success: false, isPermissionError: isPerm);
    } else {
      // 3. 신규 파일 루트에 생성 (Multipart 업로드)
      final boundary = 'boundary_${DateTime.now().millisecondsSinceEpoch}';
      final metadata = jsonEncode({
        'name': syncFileName,
        'parents': ['root'],
        'mimeType': 'application/json',
      });

      final bodyBytes = <int>[
        ...utf8.encode('--$boundary\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n$metadata\r\n'),
        ...utf8.encode('--$boundary\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n$payload\r\n'),
        ...utf8.encode('--$boundary--\r\n'),
      ];

      final createRes = await http.post(
        Uri.parse('https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart'),
        headers: {
          ...headers,
          'Content-Type': 'multipart/related; boundary=$boundary',
        },
        body: bodyBytes,
      );

      if (createRes.statusCode == 200 || createRes.statusCode == 201) {
        debugPrint('[PlaybackSync] 구글 드라이브 루트에 $syncFileName 생성 완료');
        return (success: true, isPermissionError: false);
      }
      final isPerm = createRes.statusCode == 401 || createRes.statusCode == 403;
      return (success: false, isPermissionError: isPerm);
    }
  }

  // ------------------------------------------------------------
  // WebDAV 구현 (루트 저장 및 읽기)
  // ------------------------------------------------------------
  Future<String?> _fetchWebDav(CloudService service, CloudAccount account) async {
    final baseUrl = account.webDavUrl?.replaceAll(RegExp(r'/+$'), '') ?? '';
    if (baseUrl.isEmpty) return null;
    final headers = await service.getStreamHeaders();

    final fileUrl = '$baseUrl/$syncFileName';
    final res = await http.get(Uri.parse(fileUrl), headers: headers);
    if (res.statusCode == 200) {
      return utf8.decode(res.bodyBytes);
    }
    return null;
  }

  Future<({bool success, bool isPermissionError})> _uploadWebDav(
    CloudService service,
    CloudAccount account,
    String payload,
  ) async {
    final baseUrl = account.webDavUrl?.replaceAll(RegExp(r'/+$'), '') ?? '';
    if (baseUrl.isEmpty) return (success: false, isPermissionError: false);
    final headers = await service.getStreamHeaders();

    final fileUrl = '$baseUrl/$syncFileName';
    final putRes = await http.put(
      Uri.parse(fileUrl),
      headers: {
        ...headers,
        'Content-Type': 'application/json; charset=utf-8',
      },
      body: utf8.encode(payload),
    );
    final ok = putRes.statusCode == 200 || putRes.statusCode == 201 || putRes.statusCode == 204;
    return (success: ok, isPermissionError: putRes.statusCode == 401 || putRes.statusCode == 403);
  }

  // ------------------------------------------------------------
  // OneDrive 구현 (루트 저장 및 읽기)
  // ------------------------------------------------------------
  Future<String?> _fetchOneDrive(CloudService service, CloudAccount account) async {
    final headers = await service.getStreamHeaders();
    final url = 'https://graph.microsoft.com/v1.0/me/drive/root:/$syncFileName:/content';
    final res = await http.get(Uri.parse(url), headers: headers);
    if (res.statusCode == 200) {
      return utf8.decode(res.bodyBytes);
    }
    return null;
  }

  Future<({bool success, bool isPermissionError})> _uploadOneDrive(
    CloudService service,
    CloudAccount account,
    String payload,
  ) async {
    final headers = await service.getStreamHeaders();
    final url = 'https://graph.microsoft.com/v1.0/me/drive/root:/$syncFileName:/content';
    final res = await http.put(
      Uri.parse(url),
      headers: {
        ...headers,
        'Content-Type': 'application/json; charset=utf-8',
      },
      body: utf8.encode(payload),
    );
    final ok = res.statusCode == 200 || res.statusCode == 201;
    return (success: ok, isPermissionError: res.statusCode == 401 || res.statusCode == 403);
  }

  // ------------------------------------------------------------
  // Dropbox 구현 (루트 저장 및 읽기)
  // ------------------------------------------------------------
  Future<String?> _fetchDropbox(CloudService service, CloudAccount account) async {
    final headers = await service.getStreamHeaders();
    final url = 'https://content.dropboxapi.com/2/files/download';
    final res = await http.post(
      Uri.parse(url),
      headers: {
        ...headers,
        'Dropbox-API-Arg': jsonEncode({'path': '/$syncFileName'}),
      },
    );
    if (res.statusCode == 200) {
      return utf8.decode(res.bodyBytes);
    }
    return null;
  }

  Future<({bool success, bool isPermissionError})> _uploadDropbox(
    CloudService service,
    CloudAccount account,
    String payload,
  ) async {
    final headers = await service.getStreamHeaders();
    final url = 'https://content.dropboxapi.com/2/files/upload';
    final res = await http.post(
      Uri.parse(url),
      headers: {
        ...headers,
        'Dropbox-API-Arg': jsonEncode({
          'path': '/$syncFileName',
          'mode': 'overwrite',
          'autorename': false,
          'mute': false,
        }),
        'Content-Type': 'application/octet-stream',
      },
      body: utf8.encode(payload),
    );
    return (success: res.statusCode == 200, isPermissionError: res.statusCode == 401 || res.statusCode == 403);
  }
}
