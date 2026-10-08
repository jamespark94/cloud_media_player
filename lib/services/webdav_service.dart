import 'dart:convert';
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
}
