import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';
import '../models/media_item.dart';
import 'cloud_service_interface.dart';

class WebDavService extends CloudService {
  WebDavService(super.account, {super.onAccountUpdated});

  String get _authHeader {
    final user = account.webDavUser ?? '';
    final pass = account.webDavPassword ?? '';
    final encoded = base64Encode(utf8.encode('$user:$pass'));
    return 'Basic $encoded';
  }

  @override
  Future<bool> refreshTokensIfNeeded() async {
    return true; // WebDAV uses basic/digest credentials
  }

  @override
  Future<List<MediaItem>> listItems({String? folderId}) async {
    final baseUrl = account.webDavUrl ?? '';
    final targetPath = folderId ?? '';
    final requestUri = Uri.parse('$baseUrl$targetPath');

    final res = http.Request('PROPFIND', requestUri)
      ..headers.addAll({
        'Authorization': _authHeader,
        'Depth': '1',
      });

    final streamedResponse = await res.send();
    final responseBody = await streamedResponse.stream.bytesToString();

    if (streamedResponse.statusCode != 207 && streamedResponse.statusCode != 200) {
      throw Exception('WebDAV 요청 실패: (${streamedResponse.statusCode})');
    }

    final document = XmlDocument.parse(responseBody);
    final responses = document.findAllElements('d:response');
    final items = <MediaItem>[];

    for (var resp in responses) {
      final href = resp.findElements('d:href').firstOrNull?.innerText ?? '';
      if (href.isEmpty || href == targetPath || href == '$targetPath/') continue;

      final propstat = resp.findElements('d:propstat').firstOrNull;
      final prop = propstat?.findElements('d:prop').firstOrNull;
      final resType = prop?.findElements('d:resourcetype').firstOrNull;
      final isFolder = resType?.findElements('d:collection').isNotEmpty == true;
      final contentLength = prop?.findElements('d:getcontentlength').firstOrNull?.innerText;
      final size = contentLength != null ? int.tryParse(contentLength) : null;
      
      final name = Uri.decodeComponent(href.split('/').where((s) => s.isNotEmpty).lastOrNull ?? href);

      items.add(MediaItem(
        id: href,
        name: name,
        parentId: targetPath,
        isFolder: isFolder,
        size: size,
      ));
    }

    return items;
  }

  @override
  Future<String> getStreamUrl(MediaItem item) async {
    final baseUrl = account.webDavUrl ?? '';
    return '$baseUrl${item.id}';
  }

  @override
  Future<Map<String, String>> getStreamHeaders() async {
    return {
      'Authorization': _authHeader,
    };
  }

  @override
  Future<bool> renameItem(MediaItem item, String newName) async {
    try {
      final baseUrl = account.webDavUrl ?? '';
      final parent = item.parentId ?? '';
      final newHref = parent.endsWith('/') ? '$parent$newName' : '$parent/$newName';
      final req = http.Request('MOVE', Uri.parse('$baseUrl${item.id}'))
        ..headers.addAll({
          'Authorization': _authHeader,
          'Destination': '$baseUrl$newHref',
          'Overwrite': 'F',
        });
      final res = await req.send();
      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (e) {
      debugPrint('[WebDavService] 이름 변경 실패: $e');
    }
    return false;
  }

  @override
  Future<bool> deleteItem(MediaItem item) async {
    try {
      final baseUrl = account.webDavUrl ?? '';
      final req = http.Request('DELETE', Uri.parse('$baseUrl${item.id}'))
        ..headers.addAll({
          'Authorization': _authHeader,
        });
      final res = await req.send();
      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (e) {
      debugPrint('[WebDavService] 삭제 실패: $e');
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
      final baseUrl = account.webDavUrl ?? '';
      final nameToUse = newName ?? item.name;
      final newHref = targetFolderId.endsWith('/') ? '$targetFolderId$nameToUse' : '$targetFolderId/$nameToUse';
      final req = http.Request('MOVE', Uri.parse('$baseUrl${item.id}'))
        ..headers.addAll({
          'Authorization': _authHeader,
          'Destination': '$baseUrl$newHref',
          'Overwrite': overwrite ? 'T' : 'F',
        });
      final res = await req.send();
      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (e) {
      debugPrint('[WebDavService] 이동 실패: $e');
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
      final baseUrl = account.webDavUrl ?? '';
      final nameToUse = newName ?? item.name;
      final newHref = targetFolderId.endsWith('/') ? '$targetFolderId$nameToUse' : '$targetFolderId/$nameToUse';
      final req = http.Request('COPY', Uri.parse('$baseUrl${item.id}'))
        ..headers.addAll({
          'Authorization': _authHeader,
          'Destination': '$baseUrl$newHref',
          'Overwrite': overwrite ? 'T' : 'F',
        });
      final res = await req.send();
      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (e) {
      debugPrint('[WebDavService] 복사 실패: $e');
    }
    return false;
  }

  @override
  Future<bool> createFolder(String folderName, {String? parentFolderId}) async {
    try {
      final baseUrl = account.webDavUrl ?? '';
      final parent = parentFolderId ?? '';
      final newHref = parent.endsWith('/') ? '$parent$folderName/' : '$parent/$folderName/';
      final req = http.Request('MKCOL', Uri.parse('$baseUrl$newHref'))
        ..headers.addAll({
          'Authorization': _authHeader,
        });
      final res = await req.send();
      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (e) {
      debugPrint('[WebDavService] 새 폴더 생성 실패: $e');
    }
    return false;
  }
}
