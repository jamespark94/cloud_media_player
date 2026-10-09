import 'dart:typed_data';
import 'package:http/http.dart' as http;
import '../models/cloud_account.dart';
import '../models/media_item.dart';

abstract class CloudService {
  final CloudAccount account;
  final Future<void> Function(CloudAccount)? onAccountUpdated;

  CloudService(this.account, {this.onAccountUpdated});

  /// 해당 폴더 내의 파일 및 서브 폴더 목록을 조회합니다.
  Future<List<MediaItem>> listItems({String? folderId});

  /// 영상/파일 스트리밍 또는 직접 다운로드를 위한 접근 URL을 반환합니다.
  Future<String> getStreamUrl(MediaItem item);

  /// 스트리밍/다운로드 요청 시 필요한 인증 헤더 (예: Authorization Bearer)
  Future<Map<String, String>> getStreamHeaders();

  /// 만료된 액세스 토큰을 자동 갱신합니다.
  Future<bool> refreshTokensIfNeeded();

  /// 썸네일 URL을 조회하거나 갱신합니다 (지원하는 경우).
  Future<String?> getThumbnailUrl(MediaItem item) async => item.thumbnailUrl;

  /// 파일 바이너리 데이터를 다운로드합니다 (만화책/압축파일/이미지 열람용).
  Future<Uint8List> downloadBytes(MediaItem item) async {
    await refreshTokensIfNeeded();
    final url = await getStreamUrl(item);
    final headers = await getStreamHeaders();
    final res = await http.get(Uri.parse(url), headers: headers);
    if (res.statusCode == 200) {
      return res.bodyBytes;
    }
    throw Exception('파일 다운로드 실패 (${res.statusCode}): ${res.body}');
  }
}
