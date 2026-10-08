import '../models/cloud_account.dart';
import '../models/media_item.dart';

abstract class CloudService {
  final CloudAccount account;
  CloudService(this.account);

  /// 해당 폴더 내의 파일 및 서브 폴더 목록을 조회합니다.
  Future<List<MediaItem>> listItems({String? folderId});

  /// 영상 스트리밍을 위한 직접 접근 URL을 반환합니다.
  Future<String> getStreamUrl(MediaItem item);

  /// 스트리밍 요청 시 필요한 인증 헤더 (예: Authorization Bearer)
  Future<Map<String, String>> getStreamHeaders();

  /// 만료된 액세스 토큰을 자동 갱신합니다.
  Future<bool> refreshTokensIfNeeded();

  /// 썸네일 URL을 조회하거나 갱신합니다 (지원하는 경우).
  Future<String?> getThumbnailUrl(MediaItem item) async => item.thumbnailUrl;
}
