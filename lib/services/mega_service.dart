import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../models/media_item.dart';
import '../models/video_quality.dart';
import '../utils/mega_crypto_utils.dart';
import 'cloud_service_interface.dart';
import 'mega_api_client.dart';

class MegaService extends CloudService {
  MegaApiClient? _apiClient;

  /// 다운로드 URL 임시 캐시
  final Map<String, ({String url, DateTime expiry})> _downloadUrlCache = {};

  MegaService(
    super.account, {
    super.onAccountUpdated,
  });

  /// `flutter_secure_storage` 또는 `account` 필드에서 `sid`와 `masterKey`를 로드하여 `MegaApiClient` 초기화
  Future<MegaApiClient> ensureClient() async {
    if (_apiClient != null) {
      return _apiClient!;
    }

    String? sid;
    Uint8List? masterKey;

    // 1. FlutterSecureStorage에서 조회
    final creds = await MegaAuthManager.loadCredentials(
      account.id,
      email: account.email,
    );

    if (creds != null) {
      sid = creds.sid;
      masterKey = creds.masterKey;
    } else {
      // 2. 폴백: account.accessToken 및 refreshToken 확인
      if (account.accessToken.isNotEmpty) {
        sid = account.accessToken;
      }
      if (account.refreshToken != null && account.refreshToken!.isNotEmpty) {
        try {
          masterKey = MegaCryptoUtils.base64UrlDecode(account.refreshToken!);
        } catch (_) {}
      }
    }

    if (sid == null || sid.isEmpty || masterKey == null || masterKey.isEmpty) {
      throw Exception('MEGA 인증 자격증명(세션 토큰 또는 마스터 키)을 찾을 수 없습니다.');
    }

    _apiClient = MegaApiClient(sid: sid, masterKey: masterKey);
    return _apiClient!;
  }

  @override
  Future<bool> refreshTokensIfNeeded() async {
    try {
      await ensureClient();
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<Map<String, String>> getStreamHeaders() async {
    return const {};
  }

  @override
  Future<List<MediaItem>> listItems({String? folderId}) async {
    final client = await ensureClient();
    final nodes = await client.listFiles(folderId: folderId);

    return nodes.map((node) {
      return MediaItem(
        id: node.handle,
        name: node.name,
        isFolder: node.isFolder,
        parentId: node.parentId,
        size: node.size,
        modifiedTime: node.modifiedTime,
      );
    }).toList();
  }

  @override
  Future<String> getStreamUrl(MediaItem item) async {
    final cached = _downloadUrlCache[item.id];
    if (cached != null && DateTime.now().isBefore(cached.expiry)) {
      return cached.url;
    }

    final client = await ensureClient();
    final res = await client.getEncryptedDownloadUrl(item.id);

    // MEGA 다운로드 URL은 임시 URL이므로 15분 캐싱
    _downloadUrlCache[item.id] = (
      url: res.downloadUrl,
      expiry: DateTime.now().add(const Duration(minutes: 15)),
    );

    return res.downloadUrl;
  }

  @override
  Future<String> getStreamUrlWithQuality(MediaItem item, VideoQuality quality) async {
    return getStreamUrl(item);
  }

  /// 노드의 복호화 키 반환
  Future<MegaFileKey?> getFileKey(String fileId) async {
    final client = await ensureClient();
    final node = await client.getNodeById(fileId);
    return node?.decryptedKey;
  }

  /// 미디어 플레이어의 Range 요청에 맞추어 MEGA 암호화 스트림을 바이트 단위로 복호화 파이프라인 제공
  Future<Stream<List<int>>> openDecryptedRangeStream({
    required MediaItem item,
    int? start,
    int? end,
  }) async {
    final client = await ensureClient();
    final node = await client.getNodeById(item.id);
    if (node == null || node.decryptedKey == null) {
      throw Exception('MEGA 파일 정보를 찾을 수 없거나 복호화 키가 없습니다. (${item.id})');
    }

    final key = node.decryptedKey!;
    final downloadUrl = await getStreamUrl(item);

    // 16바이트 AES 블록 경계로 정렬
    final actualStart = start ?? 0;
    final blockIndex = actualStart ~/ 16;
    final alignedStart = blockIndex * 16;
    final prefixSkip = actualStart - alignedStart;

    final dio = Dio();
    final options = Options(
      responseType: ResponseType.stream,
      headers: {
        'Range': end != null ? 'bytes=$alignedStart-$end' : 'bytes=$alignedStart-',
      },
    );

    final response = await dio.get<ResponseBody>(downloadUrl, options: options);
    final rawStream = response.data!.stream;

    return _decryptStream(rawStream, key.aesKey, key.iv, blockIndex, prefixSkip);
  }

  static Stream<List<int>> _decryptStream(
    Stream<Uint8List> rawStream,
    Uint8List aesKey,
    Uint8List iv,
    int startBlockIndex,
    int prefixSkip,
  ) async* {
    int currentBlockIndex = startBlockIndex;
    int remainingSkip = prefixSkip;
    Uint8List remainder = Uint8List(0);

    await for (final chunk in rawStream) {
      Uint8List combined;
      if (remainder.isNotEmpty) {
        final b = BytesBuilder(copy: false);
        b.add(remainder);
        b.add(chunk);
        combined = b.toBytes();
      } else {
        combined = chunk;
      }

      final fullBlocksLength = (combined.length ~/ 16) * 16;
      if (fullBlocksLength == 0) {
        remainder = combined;
        continue;
      }

      final blocksToDecrypt = combined.sublist(0, fullBlocksLength);
      remainder = combined.sublist(fullBlocksLength);

      final decrypted = MegaCryptoUtils.decryptFileBytesCtr(
        encryptedBytes: blocksToDecrypt,
        fileAesKey16: aesKey,
        fileIv8: iv,
        initialBlockOffset: currentBlockIndex,
      );

      currentBlockIndex += fullBlocksLength ~/ 16;

      if (remainingSkip > 0) {
        if (remainingSkip >= decrypted.length) {
          remainingSkip -= decrypted.length;
          continue;
        } else {
          final out = decrypted.sublist(remainingSkip);
          remainingSkip = 0;
          yield out;
        }
      } else {
        yield decrypted;
      }
    }

    // 스트림 종료 시 남은 16바이트 미만의 마지막 블록 복호화
    if (remainder.isNotEmpty) {
      final decrypted = MegaCryptoUtils.decryptFileBytesCtr(
        encryptedBytes: remainder,
        fileAesKey16: aesKey,
        fileIv8: iv,
        initialBlockOffset: currentBlockIndex,
      );

      if (remainingSkip > 0) {
        if (remainingSkip < decrypted.length) {
          yield decrypted.sublist(remainingSkip);
        }
      } else {
        yield decrypted;
      }
    }
  }

  @override
  Future<Uint8List> downloadBytes(MediaItem item) async {
    final client = await ensureClient();
    final node = await client.getNodeById(item.id);
    if (node == null || node.decryptedKey == null) {
      throw Exception('MEGA 파일 정보를 찾을 수 없거나 복호화 키가 없습니다. (${item.id})');
    }

    final downloadUrl = await getStreamUrl(item);
    final encryptedBytes = await client.downloadEncryptedBytes(downloadUrl);

    return MegaCryptoUtils.decryptFileBytesCtr(
      encryptedBytes: encryptedBytes,
      fileAesKey16: node.decryptedKey!.aesKey,
      fileIv8: node.decryptedKey!.iv,
    );
  }
}
