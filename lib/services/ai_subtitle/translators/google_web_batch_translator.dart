import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

/// 배치 번역 결과.
class BatchTranslationResult {
  final List<String?> translations;
  final String? detectedSourceLanguage;

  const BatchTranslationResult({
    required this.translations,
    this.detectedSourceLanguage,
  });
}

/// Google Translate 무료 웹 엔드포인트(`client=gtx`) 기반 청크 일괄 번역기.
///
/// - API Key나 유료 토큰 소모 없이 Android, iPadOS, Windows 모두에서 동작합니다.
/// - 단일 청크 내 여러 자막 세그먼트를 고유 구분자(`\n|||\n`)로 묶어
///   **청크당 1회 HTTP GET** 요청으로 일괄 번역한 뒤 각 세그먼트에 다시 매핑합니다.
/// - 오프라인 또는 네트워크/파싱 오류 시 예외를 던지지 않고 `null`을 반환해
///   원어 자막 단독 폴백을 보장합니다.
class GoogleWebBatchTranslator {
  static const String endpointUrl =
      'https://translate.googleapis.com/translate_a/single';
  static const String batchDelimiter = '\n|||\n';
  static final RegExp _splitDelimiterPattern =
      RegExp(r'\r?\n?\s*\|\|\|\s*\r?\n?');

  final Dio _dio;
  String? _lastErrorMessage;

  GoogleWebBatchTranslator({Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 10),
                sendTimeout: const Duration(seconds: 10),
                receiveTimeout: const Duration(seconds: 15),
              ),
            );

  String? get lastErrorMessage => _lastErrorMessage;

  /// [texts] 목록을 고유 구분자(`\n|||\n`)로 결합하여 청크당 1회 HTTP GET으로 번역합니다.
  ///
  /// 요청 취소([CancelToken])는 상위로 전파하지 않고 `null`을 반환하거나
  /// 호출자가 취소 플래그를 검사할 수 있게 합니다.
  /// 네트워크/서버 오류 시 [lastErrorMessage]를 기록하고 `null`을 반환합니다.
  Future<BatchTranslationResult?> translateBatch(
    List<String> texts, {
    String sourceLang = 'auto',
    String targetLang = 'ko',
    CancelToken? cancelToken,
  }) async {
    if (texts.isEmpty) {
      _lastErrorMessage = null;
      return const BatchTranslationResult(translations: []);
    }

    final sl = _normalizeForGoogle(sourceLang);
    final tl = _normalizeForGoogle(targetLang, fallback: 'ko');
    if (sl != 'auto' && sl == tl) {
      _lastErrorMessage = null;
      return BatchTranslationResult(
        translations: List<String?>.filled(texts.length, null),
        detectedSourceLanguage: sl,
      );
    }

    // 원문에 구분자 문자열이 우연히 포함된 경우 공백으로 치환해 분리 정합성 보장
    final sanitized = texts
        .map((t) => t.replaceAll('|||', ' ').trim())
        .toList(growable: false);
    if (sanitized.every((t) => t.isEmpty)) {
      return BatchTranslationResult(
        translations: List<String?>.filled(texts.length, null),
      );
    }

    final combined = sanitized.join(batchDelimiter);

    try {
      final response = await _dio.get<dynamic>(
        endpointUrl,
        queryParameters: <String, dynamic>{
          'client': 'gtx',
          'sl': sl,
          'tl': tl,
          'dt': 't',
          'q': combined,
        },
        cancelToken: cancelToken,
        options: Options(responseType: ResponseType.json),
      );

      final parsed = parseResponseData(response.data);
      if (parsed == null) {
        _lastErrorMessage = '구글 무료 번역 응답 형식이 올바르지 않습니다.';
        return null;
      }

      final mapped = splitAndMapTranslations(
        translatedCombined: parsed.translatedText,
        originalTexts: sanitized,
      );
      if (mapped == null) {
        _lastErrorMessage = '구글 무료 번역 배치 분리 매핑에 실패했습니다.';
        return null;
      }

      _lastErrorMessage = null;
      return BatchTranslationResult(
        translations: mapped,
        detectedSourceLanguage: parsed.detectedLanguage,
      );
    } on DioException catch (e) {
      if (CancelToken.isCancel(e) || e.type == DioExceptionType.cancel) {
        return null;
      }
      final status = e.response?.statusCode;
      _lastErrorMessage = status != null
          ? '구글 무료 번역 요청 실패 (HTTP $status)'
          : '네트워크 오프라인 또는 번역 서버 연결 실패';
      debugPrint('[GoogleWebBatchTranslator] $_lastErrorMessage: ${e.message}');
      return null;
    } catch (e) {
      _lastErrorMessage = '구글 무료 번역 오류: $e';
      debugPrint('[GoogleWebBatchTranslator] $_lastErrorMessage');
      return null;
    }
  }

  /// `translate.googleapis.com/translate_a/single` JSON 배열 응답을 파싱합니다.
  @visibleForTesting
  static ({String translatedText, String? detectedLanguage})? parseResponseData(
    dynamic rawData,
  ) {
    dynamic data = rawData;
    if (data is String && data.isNotEmpty) {
      try {
        data = jsonDecode(data);
      } catch (_) {
        return null;
      }
    }
    if (data is! List || data.isEmpty) return null;

    final sentenceList = data[0];
    if (sentenceList is! List) return null;

    final buffer = StringBuffer();
    for (final item in sentenceList) {
      if (item is List && item.isNotEmpty && item[0] is String) {
        buffer.write(item[0] as String);
      }
    }

    final translated = buffer.toString();
    if (translated.trim().isEmpty) return null;

    String? detectedLang;
    if (data.length > 2 && data[2] is String) {
      final lang = (data[2] as String).trim();
      if (lang.isNotEmpty) {
        detectedLang = lang;
      }
    }

    return (
      translatedText: translated,
      detectedLanguage: detectedLang,
    );
  }

  /// 일괄 번역된 문자열을 고유 구분자(`|||`) 기준으로 분리해 원문 인덱스에 1:1 매핑합니다.
  @visibleForTesting
  static List<String?>? splitAndMapTranslations({
    required String translatedCombined,
    required List<String> originalTexts,
  }) {
    if (originalTexts.isEmpty) return const [];
    if (originalTexts.length == 1) {
      final single = translatedCombined.trim();
      return [single.isEmpty || single == originalTexts.first ? null : single];
    }

    var parts = translatedCombined
        .split(_splitDelimiterPattern)
        .map((e) => e.trim())
        .toList();

    if (parts.length != originalTexts.length) {
      final nonEmpty = parts.where((e) => e.isNotEmpty).toList();
      if (nonEmpty.length == originalTexts.length) {
        parts = nonEmpty;
      }
    }

    if (parts.length != originalTexts.length) {
      return null;
    }

    return List<String?>.generate(originalTexts.length, (i) {
      final trans = parts[i];
      final orig = originalTexts[i];
      if (trans.isEmpty || trans == orig) return null;
      return trans;
    });
  }

  static String _normalizeForGoogle(
    String code, {
    String fallback = 'auto',
  }) {
    final trimmed = code.trim().toLowerCase();
    if (trimmed.isEmpty || trimmed == 'auto') return fallback;
    if (trimmed == 'zh') return 'zh-CN';
    return trimmed;
  }

  void dispose() {
    _lastErrorMessage = null;
  }
}
