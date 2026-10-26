import 'dart:typed_data';
import 'package:dio/dio.dart';

class SessionExpiredException implements Exception {
  final String message;
  SessionExpiredException([this.message = '네이버 MYBOX 토큰이 만료되었거나 올바르지 않습니다.']);

  @override
  String toString() => 'SessionExpiredException: $message';
}

class NaverBoxFileModel {
  final String resourceId;
  final String name;
  final int size;
  final bool isFolder;
  final String? parentId;
  final DateTime? modifiedTime;
  final String? thumbnail;

  NaverBoxFileModel({
    required this.resourceId,
    required this.name,
    required this.size,
    required this.isFolder,
    this.parentId,
    this.modifiedTime,
    this.thumbnail,
  });

  factory NaverBoxFileModel.fromOpenApi(Map<String, dynamic> json) {
    final typeStr = (json['type'] ?? '').toString().toLowerCase();
    final bool isDir = typeStr == 'folder';
    return NaverBoxFileModel(
      resourceId: (json['resourceId'] ?? json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      size: (json['size'] ?? 0) as int,
      isFolder: isDir,
      parentId: json['parentId']?.toString(),
      modifiedTime: json['modifiedAt'] != null
          ? DateTime.tryParse(json['modifiedAt'].toString())
          : null,
      thumbnail: json['thumbnailUrl']?.toString(),
    );
  }
}

class NaverBoxApiClient {
  final Dio _dio;
  String _token;

  static const String defaultUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36';

  NaverBoxApiClient({
    required String token,
    Dio? customDio,
    // ignore: prefer_initializing_formals
  })  : _token = token,
        _dio = customDio ?? Dio() {
    _dio.options.baseUrl = 'https://open-api.mybox.naver.com';
    _dio.options.connectTimeout = const Duration(seconds: 15);
    _dio.options.receiveTimeout = const Duration(seconds: 30);

    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          options.headers['User-Agent'] = defaultUserAgent;
          options.headers['Authorization'] = 'Bearer $_token';
          options.headers['Accept'] = 'application/json';
          return handler.next(options);
        },
        onError: (DioException error, handler) {
          final statusCode = error.response?.statusCode;
          if (statusCode == 401 || statusCode == 403) {
            return handler.reject(
              DioException(
                requestOptions: error.requestOptions,
                error: SessionExpiredException(),
                type: DioExceptionType.badResponse,
                response: error.response,
              ),
            );
          }
          return handler.next(error);
        },
      ),
    );
  }

  void updateToken(String token) {
    _token = token;
  }

  Map<String, String> get authHeaders => {
        'User-Agent': defaultUserAgent,
        'Authorization': 'Bearer $_token',
      };

  /// 특정 폴더의 파일 및 폴더 목록 조회 (공식 Open API)
  Future<List<NaverBoxFileModel>> listFiles({String? folderId}) async {
    try {
      final isRoot = folderId == null || folderId.isEmpty || folderId == 'root';
      final path = isRoot
          ? '/v1/drive/resources'
          : '/v1/drive/folders/$folderId/resources';

      final response = await _dio.get(
        path,
        queryParameters: {
          'count': 1000,
          'sort': 'name,asc',
        },
      );

      final data = response.data;
      final List<dynamic> rawList = (data is Map && data['resources'] != null)
          ? (data['resources'] as List<dynamic>)
          : [];

      final items = <NaverBoxFileModel>[];
      for (final item in rawList) {
        if (item is Map<String, dynamic>) {
          items.add(NaverBoxFileModel.fromOpenApi(item));
        }
      }
      return items;
    } on DioException catch (e) {
      if (e.error is SessionExpiredException) {
        throw e.error!;
      }
      throw Exception('MYBOX 목록 조회 실패: ${e.response?.statusCode} ${e.message}');
    }
  }

  /// 다운로드용 임시 서명 URL 생성 (/v1/drive/files/{fileId}/download)
  Future<String> getDownloadUrl(String fileId) async {
    try {
      final response = await _dio.get('/v1/drive/files/$fileId/download');
      final data = response.data;
      if (data is Map && data['downloadUrl'] != null) {
        return data['downloadUrl'] as String;
      }
      throw Exception('다운로드 URL 응답 오류');
    } on DioException catch (e) {
      if (e.error is SessionExpiredException) {
        throw e.error!;
      }
      throw Exception('다운로드 URL 발급 실패: ${e.message}');
    }
  }

  /// 파일 썸네일 바이너리 다운로드 (임시 다운로드 링크로 스트리밍)
  Future<Uint8List> getThumbnail(String fileId) async {
    final directUrl = await getDownloadUrl(fileId);
    final response = await Dio().get<List<int>>(
      directUrl,
      options: Options(responseType: ResponseType.bytes),
    );
    return Uint8List.fromList(response.data!);
  }
}
