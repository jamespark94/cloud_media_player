import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import '../models/media_item.dart';
import 'cloud_service_interface.dart';
import 'naver_box_api_client.dart';

class NaverBoxService extends CloudService {
  late final NaverBoxApiClient _apiClient;

  NaverBoxService(
    super.account, {
    super.onAccountUpdated,
  }) {
    _initClient();
  }

  void _initClient() {
    _apiClient = NaverBoxApiClient(
      token: account.accessToken.trim(),
    );
  }

  @override
  Future<bool> refreshTokensIfNeeded() async {
    return account.accessToken.isNotEmpty;
  }

  @override
  Future<Map<String, String>> getStreamHeaders() async {
    return _apiClient.authHeaders;
  }

  @override
  Future<List<MediaItem>> listItems({String? folderId}) async {
    final list = await _apiClient.listFiles(folderId: folderId);
    return list.map((item) {
      return MediaItem(
        id: item.resourceId,
        name: item.name,
        size: item.size,
        isFolder: item.isFolder,
        mimeType: item.isFolder ? 'folder' : null,
        parentId: item.parentId ?? folderId,
        modifiedTime: item.modifiedTime,
        thumbnailUrl: item.thumbnail,
      );
    }).toList();
  }

  @override
  Future<String> getStreamUrl(MediaItem item) async {
    if (item.directStreamUrl != null && item.directStreamUrl!.isNotEmpty) {
      return item.directStreamUrl!;
    }
    return _apiClient.getDownloadUrl(item.id);
  }

  @override
  Future<Uint8List> downloadBytes(MediaItem item) async {
    return _apiClient.getThumbnail(item.id);
  }
}
