import 'package:flutter/foundation.dart';
import 'dart:math';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../utils/mega_crypto_utils.dart';

/// MEGA 세션 및 마스터 키 보안 저장 데이터 모델
class MegaSessionCredentials {
  final String email;
  final String sid;
  final Uint8List masterKey; // 16 bytes
  final String? userHandle;

  const MegaSessionCredentials({
    required this.email,
    required this.sid,
    required this.masterKey,
    this.userHandle,
  });
}

/// 복호화된 MEGA 노드(파일/폴더) 모델
class MegaNodeModel {
  final String handle; // 'h' (노드 고유 ID)
  final String parentId; // 'p' (부모 노드 ID)
  final String name; // 복호화된 'a' -> 'n'
  final int size; // 's'
  final bool isFolder; // 't' == 1 (폴더) or 't' >= 2 (루트/휴지통 등), 't' == 0 (파일)
  final int nodeType; // 0: File, 1: Folder, 2: Cloud Drive Root, 3: Inbox, 4: Rubbish Bin
  final DateTime? modifiedTime; // 'ts' (Unix timestamp)
  final MegaFileKey? decryptedKey; // 파일 바이트 복호화에 사용할 16B AES Key + 8B IV

  const MegaNodeModel({
    required this.handle,
    required this.parentId,
    required this.name,
    required this.size,
    required this.isFolder,
    required this.nodeType,
    this.modifiedTime,
    this.decryptedKey,
  });
}

/// 1. 인증 및 마스터 키 유도/보관 매니저 (`flutter_secure_storage` 연동)
class MegaAuthManager {
  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage();
  static const String _keyPrefix = 'mega_cred_';

  /// 이메일/비밀번호로 MEGA 로그인 수행 후 세션(`sid`) 및 마스터 키를 유도하고 SecureStorage에 저장
  static Future<MegaSessionCredentials> loginWithEmailAndPassword({
    required String email,
    required String password,
    required String accountId,
    Dio? dio,
  }) async {
    final client = dio ??
        Dio(BaseOptions(
          baseUrl: 'https://g.api.mega.co.nz',
          connectTimeout: const Duration(seconds: 20),
          receiveTimeout: const Duration(seconds: 30),
          headers: {'Content-Type': 'application/json'},
        ));

    int seq = Random().nextInt(0x10000000);
    final cleanEmail = email.trim().toLowerCase();

    // 1. Pre-login 요청 (us0)
    final us0Res = await client.post(
      '/cs',
      queryParameters: {'id': (seq++).toString()},
      data: [
        {'a': 'us0', 'user': cleanEmail}
      ],
    );

    if (us0Res.data is! List || (us0Res.data as List).isEmpty) {
      throw Exception('MEGA 로그인 응답 오류 (us0)');
    }

    final first = (us0Res.data as List).first;
    if (first is int && first < 0) {
      if (first == -9) throw Exception('존재하지 않는 MEGA 계정이거나 이메일이 잘못되었습니다.');
      throw Exception('MEGA pre-login 실패 (코드: $first)');
    }

    final us0Data = first as Map<String, dynamic>;
    final version = us0Data['v'] ?? 1;

    Uint8List derivedKey;
    String userHash;

    if (version == 2) {
      final salt = us0Data['s'] as String?;
      if (salt == null || salt.isEmpty) {
        throw Exception('MEGA v2 Salt 정보를 수신하지 못했습니다.');
      }
      final v2Res = MegaCryptoUtils.derivePasswordKeyV2(password, salt);
      derivedKey = v2Res.derivedKey;
      userHash = v2Res.userHash;
    } else {
      derivedKey = MegaCryptoUtils.derivePasswordKeyV1(password);
      userHash = MegaCryptoUtils.calculateUserHashV1(cleanEmail, derivedKey);
    }

    // 2. Login 요청 (us)
    final usRes = await client.post(
      '/cs',
      queryParameters: {'id': (seq++).toString()},
      data: [
        {'a': 'us', 'user': cleanEmail, 'uh': userHash}
      ],
    );

    if (usRes.data is! List || (usRes.data as List).isEmpty) {
      throw Exception('MEGA 로그인 응답 오류 (us)');
    }

    final usFirst = (usRes.data as List).first;
    if (usFirst is int && usFirst < 0) {
      if (usFirst == -9) throw Exception('이메일 또는 비밀번호가 올바르지 않습니다.');
      if (usFirst == -26) throw Exception('2단계 인증(2FA)이 설정된 계정입니다. (현재 미지원)');
      throw Exception('MEGA 로그인 실패 (코드: $usFirst)');
    }

    final usData = usFirst as Map<String, dynamic>;
    final encK = usData['k'] as String?;
    final encPrivK = usData['privk'] as String?;
    final encCsid = usData['csid'] as String?;
    final uHandle = usData['u'] as String?;

    if (encK == null || encPrivK == null || encCsid == null) {
      throw Exception('로그인 응답에 필요한 암호화 키 정보가 누락되었습니다.');
    }

    // 3. 마스터 키 복호화
    final masterKey = MegaCryptoUtils.decryptMasterKey(encK, derivedKey);

    // 4. 세션 ID(sid) 복호화
    final sid = MegaCryptoUtils.decryptSessionId(
      encryptedPrivKeyBase64: encPrivK,
      encryptedCsidBase64: encCsid,
      masterKey: masterKey,
    );

    final creds = MegaSessionCredentials(
      email: cleanEmail,
      sid: sid,
      masterKey: masterKey,
      userHandle: uHandle,
    );

    await saveCredentials(accountId, creds);
    return creds;
  }

  /// `flutter_secure_storage`에 `sid`와 `masterKey`(Base64URL) 저장
  static Future<void> saveCredentials(
    String accountId,
    MegaSessionCredentials credentials,
  ) async {
    try {
      await _secureStorage.write(
        key: '$_keyPrefix${accountId}_sid',
        value: credentials.sid,
      );
      await _secureStorage.write(
        key: '$_keyPrefix${accountId}_mk',
        value: MegaCryptoUtils.base64UrlEncode(credentials.masterKey),
      );
      if (credentials.userHandle != null) {
        await _secureStorage.write(
          key: '$_keyPrefix${accountId}_uh',
          value: credentials.userHandle!,
        );
      }
    } catch (_) {}
  }

  /// `flutter_secure_storage`에서 저장된 세션 및 마스터 키 복원
  static Future<MegaSessionCredentials?> loadCredentials(
    String accountId, {
    String email = '',
  }) async {
    try {
      final sid = await _secureStorage.read(key: '$_keyPrefix${accountId}_sid');
      final mkB64 = await _secureStorage.read(key: '$_keyPrefix${accountId}_mk');
      final uh = await _secureStorage.read(key: '$_keyPrefix${accountId}_uh');

      if (sid != null && sid.isNotEmpty && mkB64 != null && mkB64.isNotEmpty) {
        final masterKey = MegaCryptoUtils.base64UrlDecode(mkB64);
        return MegaSessionCredentials(
          email: email,
          sid: sid,
          masterKey: masterKey,
          userHandle: uh,
        );
      }
    } catch (_) {}
    return null;
  }

  /// 계정 연결 해제 시 보안 저장소에서 키 삭제
  static Future<void> deleteCredentials(String accountId) async {
    try {
      await _secureStorage.delete(key: '$_keyPrefix${accountId}_sid');
      await _secureStorage.delete(key: '$_keyPrefix${accountId}_mk');
      await _secureStorage.delete(key: '$_keyPrefix${accountId}_uh');
    } catch (_) {}
  }
}

/// 2. MEGA API 클라이언트 (`https://g.api.mega.co.nz/cs`)
class MegaApiClient {
  final Dio _dio;
  String _sid;
  Uint8List _masterKey;
  int _sequenceId = Random().nextInt(0x10000000);

  /// 전체 노드 트리 인메모리 캐시
  List<MegaNodeModel>? _cachedAllNodes;
  String? _cloudDriveRootHandle; // nodeType == 2 인 루트 폴더 핸들

  static const Set<String> comicExtensions = {
    'zip', 'cbz', 'rar', 'cbr', '7z', 'pdf',
    'jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp', 'avif'
  };

  MegaApiClient({
    required this._sid,
    required this._masterKey,
    Dio? customDio,
  })  :
        _dio = customDio ??
            Dio(BaseOptions(
              baseUrl: 'https://g.api.mega.co.nz',
              connectTimeout: const Duration(seconds: 20),
              receiveTimeout: const Duration(seconds: 60),
              headers: {'Content-Type': 'application/json'},
            ));

  void updateCredentials({required String sid, required Uint8List masterKey}) {
    _sid = sid;
    _masterKey = masterKey;
  }

  void invalidateNodeCache() {
    _cachedAllNodes = null;
  }

  /// MEGA JSON-RPC 배열 명령 전송 헬퍼 (`POST /cs?id={seq}&sid={sid}`)
  Future<dynamic> _postCommand(Map<String, dynamic> command, {bool includeSid = true}) async {
    final query = <String, String>{
      'id': (_sequenceId++).toString(),
    };
    if (includeSid && _sid.isNotEmpty) {
      query['sid'] = _sid;
    }

    final response = await _dio.post(
      '/cs',
      queryParameters: query,
      data: [command],
    );

    if (response.data is List && (response.data as List).isNotEmpty) {
      final res = (response.data as List).first;
      if (res is int && res < 0) {
        if (res == -15) {
          throw Exception('MEGA 세션이 만료되었습니다. 다시 로그인해주세요.');
        }
        if (res == -3) {
          // EAGAIN -> 1초 후 1회 재시도
          await Future.delayed(const Duration(seconds: 1));
          return _postCommand(command, includeSid: includeSid);
        }
        throw Exception('MEGA API 요청 에러 (코드: $res)');
      }
      return res;
    }
    return response.data;
  }

  /// 전체 파일/폴더 트리 요청 (`action: 'f'`) 및 각 노드 키/메타데이터 복호화
  Future<List<MegaNodeModel>> fetchAllNodes({bool forceRefresh = false}) async {
    if (_cachedAllNodes != null && !forceRefresh) {
      return _cachedAllNodes!;
    }

    final res = await _postCommand({'a': 'f', 'c': 1, 'r': 1});
    if (res is! Map<String, dynamic> || res['f'] == null) {
      _cachedAllNodes = [];
      return [];
    }

    final rawList = res['f'] as List<dynamic>;
    debugPrint('[MEGA] fetchAllNodes rawList length: ' + rawList.length.toString());
    final List<MegaNodeModel> parsedNodes = [];

    // Extra / Shared keys from 'ok' parameter if present
    final Map<String, String> okKeys = {};
    if (res['ok'] is List) {
      for (final item in (res['ok'] as List)) {
        if (item is Map<String, dynamic> && item['h'] != null && item['k'] != null) {
          okKeys[item['h'].toString()] = item['k'].toString();
        }
      }
    }

    // 1st pass: root node (t == 2) search
    for (final item in rawList) {
      if (item is Map<String, dynamic>) {
        final t = (item['t'] ?? 0) as int;
        if (t == 2) {
          _cloudDriveRootHandle = item['h']?.toString();
          debugPrint('[MEGA] Detected Cloud Drive Root handle: ' + (_cloudDriveRootHandle ?? ''));
          break;
        }
      }
    }

    // 2nd pass: parse all nodes
    for (final item in rawList) {
      if (item is! Map<String, dynamic>) continue;

      final handle = (item['h'] ?? '').toString();
      final parentId = (item['p'] ?? '').toString();
      final t = (item['t'] ?? 0) as int;
      final size = (item['s'] ?? 0) as int;
      final ts = (item['ts'] ?? 0) as int;
      final modTime = ts > 0 ? DateTime.fromMillisecondsSinceEpoch(ts * 1000) : null;
      final kStr = (item['k'] ?? '').toString();
      final aStr = (item['a'] ?? '').toString();

      final bool isFolder = t == 1 || t >= 2;

      // Extract candidate encrypted keys from node 'k' or 'ok'
      final List<String> candidateEncryptedKeys = [];
      if (kStr.isNotEmpty) {
        final parts = kStr.split('/');
        for (final part in parts) {
          final colonIdx = part.indexOf(':');
          if (colonIdx >= 0 && colonIdx < part.length - 1) {
            candidateEncryptedKeys.add(part.substring(colonIdx + 1));
          } else if (colonIdx == -1 && part.isNotEmpty) {
            candidateEncryptedKeys.add(part);
          }
        }
      }

      if (okKeys.containsKey(handle)) {
        final okVal = okKeys[handle]!;
        final colonIdx = okVal.indexOf(':');
        if (colonIdx >= 0 && colonIdx < okVal.length - 1) {
          candidateEncryptedKeys.add(okVal.substring(colonIdx + 1));
        } else if (colonIdx == -1 && okVal.isNotEmpty) {
          candidateEncryptedKeys.add(okVal);
        }
      }

      MegaFileKey? fileKey;
      String name = '';

      for (final encKey in candidateEncryptedKeys) {
        try {
          final candidateKey = MegaCryptoUtils.decryptAndUnpackNodeKey(
            encKey,
            _masterKey,
            isFolder: isFolder,
          );

          if (aStr.isNotEmpty) {
            final attrs = MegaCryptoUtils.decryptNodeAttributes(aStr, candidateKey.aesKey);
            if (attrs != null && attrs['n'] != null) {
              fileKey = candidateKey;
              name = attrs['n'].toString();
              break;
            }
          } else {
            fileKey = candidateKey;
            break;
          }
        } catch (_) {}
      }

      if (name.isEmpty) {
        if (t == 2) {
          name = '클라우드 드라이브';
        } else if (t == 3) {
          name = '수신함';
        } else if (t == 4) {
          name = '휴지통';
        } else {
          name = isFolder ? '폴더' : '파일';
        }
      }

      debugPrint('[MEGA] Node parsed: name=' + name + ', handle=' + handle + ', p=' + parentId + ', t=' + t.toString() + ', isFolder=' + isFolder.toString() + ', hasKey=' + (fileKey != null).toString());
      parsedNodes.add(
        MegaNodeModel(
          handle: handle,
          parentId: parentId,
          name: name,
          size: size,
          isFolder: isFolder,
          nodeType: t,
          modifiedTime: modTime,
          decryptedKey: fileKey,
        ),
      );
    }

    _cachedAllNodes = parsedNodes;
    return parsedNodes;
  }

  /// 특정 폴더(olderId) 하위의 자식 폴더/파일 목록 반환
  Future<List<MegaNodeModel>> listFiles({String? folderId, bool forceRefresh = false}) async {
    final all = await fetchAllNodes(forceRefresh: forceRefresh);
    String targetParent = folderId ?? '';
    debugPrint('[MEGA] listFiles called for folderId: ' + (folderId ?? 'null') + ', rootHandle: ' + (_cloudDriveRootHandle ?? 'null') + ', allNodesCount: ' + all.length.toString());

    if (targetParent.isEmpty || targetParent == 'root') {
      targetParent = _cloudDriveRootHandle ?? '';
      if (targetParent.isEmpty) {
        final rootNode = all.cast<MegaNodeModel?>().firstWhere(
              (n) => n?.nodeType == 2,
              orElse: () => null,
            );
        if (rootNode != null) {
          targetParent = rootNode.handle;
        }
      }
    }

    List<MegaNodeModel> result = [];
    if (targetParent.isNotEmpty) {
      result = all.where((n) => n.parentId == targetParent && n.handle != targetParent).toList();
    }

    // Fallback: If no nodes match targetParent, include all user nodes except special root buckets
    if (result.isEmpty && (folderId == null || folderId.isEmpty || folderId == 'root')) {
      final rootHandles = all.where((n) => n.nodeType >= 2).map((n) => n.handle).toSet();
      result = all.where((n) {
        if (rootHandles.contains(n.handle)) return false;
        return n.parentId == _cloudDriveRootHandle ||
               n.parentId.isEmpty ||
               !all.any((parent) => parent.handle == n.parentId && parent.nodeType < 2);
      }).toList();
    }

    debugPrint('[MEGA] listFiles returning ' + result.length.toString() + ' items for targetParent=' + targetParent);
    return result;
  }

  Future<MegaNodeModel?> getNodeById(String fileId) async {
    if (_cachedAllNodes == null) {
      await fetchAllNodes();
    }
    return _cachedAllNodes?.cast<MegaNodeModel?>().firstWhere(
          (n) => n?.handle == fileId,
          orElse: () => null,
        );
  }

  /// 암호화된 파일 다운로드 임시 URL 발급 (`action: 'g'`)
  Future<({String downloadUrl, int size})> getEncryptedDownloadUrl(String fileId) async {
    final res = await _postCommand({'a': 'g', 'g': 1, 'n': fileId});
    if (res is! Map<String, dynamic> || res['g'] == null) {
      throw Exception('MEGA 다운로드 URL 발급 실패');
    }
    return (
      downloadUrl: res['g'] as String,
      size: (res['s'] ?? 0) as int,
    );
  }

  /// 암호화된 바이너리 다운로드 (Dio 바이트 수신)
  Future<Uint8List> downloadEncryptedBytes(
    String downloadUrl, {
    void Function(int received, int total)? onProgress,
  }) async {
    final response = await _dio.get<List<int>>(
      downloadUrl,
      options: Options(responseType: ResponseType.bytes),
      onReceiveProgress: onProgress,
    );
    return Uint8List.fromList(response.data!);
  }

}
