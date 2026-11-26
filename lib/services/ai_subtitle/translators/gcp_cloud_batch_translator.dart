import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'google_web_batch_translator.dart';

/// GCP Cloud Translation API v2 요청 오류.
class GcpTranslationException implements Exception {
  final int? statusCode;
  final String message;

  const GcpTranslationException({
    required this.message,
    this.statusCode,
  });

  /// API 키 권한 오류(403) 또는 할당량 초과(429) 등 온디바이스/기본 폴백 전환 대상 여부.
  bool get isFallbackStatus => statusCode == 403 || statusCode == 429;

  @override
  String toString() =>
      'GcpTranslationException(status=$statusCode, message=$message)';
}

/// GCP Cloud Translation API v2(`http` 패키지 직접 POST) 배치 번역기.
///
/// - 공식 `googleapis` 패키지 없이 `package:http`로
///   `https://translation.googleapis.com/language/translate/v2?key={apiKey}`에 직접 POST 요청합니다.
/// - 요청 바디는 `{"q": text, "target": "ko", "format": "html"}` 형식을 사용하며
///   `source`를 생략하여 자동 감지를 활용합니다.
/// - 여러 문장은 `<span translate="no">|||</span>` 구분자로 이어 붙여 최대 3,500자 단위로 묶어 요청합니다.
class GcpCloudBatchTranslator {
  static const String baseUrl =
      'https://translation.googleapis.com/language/translate/v2';
  static const String batchDelimiter = '<span translate="no">|||</span>';
  static const int maxBatchChars = 3500;

  static final RegExp _splitDelimiterPattern = RegExp(
    r'\s*(?:<span\b[^>]*>\s*)?\|\|\|(?:\s*</span>)?\s*',
    caseSensitive: false,
  );
  static final RegExp _strayNoTranslateSpanPattern = RegExp(
    r'</?span\b[^>]*>',
    caseSensitive: false,
  );
  static final RegExp _htmlEntityPattern = RegExp(
    r'&(?:#(\d+)|#x([0-9a-fA-F]+)|([a-zA-Z]+));',
  );

  static const Map<String, String> _namedHtmlEntities = <String, String>{
    'amp': '&',
    'lt': '<',
    'gt': '>',
    'quot': '"',
    'apos': "'",
    'nbsp': ' ',
    'hellip': '…',
    'lsquo': '‘',
    'rsquo': '’',
    'ldquo': '“',
    'rdquo': '”',
    'ndash': '–',
    'mdash': '—',
  };

  final http.Client _httpClient;
  final bool _ownsClient;
  final Duration requestTimeout;
  String? _lastErrorMessage;

  GcpCloudBatchTranslator({
    http.Client? httpClient,
    this.requestTimeout = const Duration(seconds: 15),
  })  : _httpClient = httpClient ?? http.Client(),
        _ownsClient = httpClient == null;

  String? get lastErrorMessage => _lastErrorMessage;

  /// [texts]를 `<span translate="no">|||</span>`로 연결해 최대 3,500자 단위 POST 배치로 번역합니다.
  Future<BatchTranslationResult> translateBatch(
    List<String> texts, {
    required String apiKey,
    String targetLang = 'ko',
  }) async {
    final cleanedKey = apiKey.trim();
    if (cleanedKey.isEmpty) {
      throw const GcpTranslationException(
        message: 'GCP Cloud Translation API 키가 입력되지 않았습니다.',
      );
    }
    if (texts.isEmpty) {
      _lastErrorMessage = null;
      return const BatchTranslationResult(translations: []);
    }

    final normalizedTarget = _normalizeTargetLang(targetLang);
    final sanitized = texts
        .map((t) => t.replaceAll('|||', ' ').trim())
        .toList(growable: false);

    final indexedNonEmpty = <({int index, String text})>[];
    for (var i = 0; i < sanitized.length; i++) {
      if (sanitized[i].isNotEmpty) {
        indexedNonEmpty.add((index: i, text: sanitized[i]));
      }
    }

    if (indexedNonEmpty.isEmpty) {
      _lastErrorMessage = null;
      return BatchTranslationResult(
        translations: List<String?>.filled(texts.length, null),
      );
    }

    final batches = splitIntoBatches(
      indexedNonEmpty.map((e) => e.text).toList(growable: false),
    );

    final results = List<String?>.filled(texts.length, null);
    String? detectedLang;
    var cursor = 0;

    for (final batch in batches) {
      final batchResult = await _translateSingleBatch(
        batch,
        apiKey: cleanedKey,
        targetLang: normalizedTarget,
      );
      detectedLang ??= batchResult.detectedSourceLanguage;

      for (var j = 0; j < batch.length; j++) {
        final origIdx = indexedNonEmpty[cursor + j].index;
        results[origIdx] = batchResult.translations[j];
      }
      cursor += batch.length;
    }

    _lastErrorMessage = null;
    return BatchTranslationResult(
      translations: results,
      detectedSourceLanguage: detectedLang,
    );
  }

  Future<BatchTranslationResult> _translateSingleBatch(
    List<String> batchTexts, {
    required String apiKey,
    required String targetLang,
  }) async {
    final combinedQuery = batchTexts.join(batchDelimiter);
    final uri = Uri.parse(
      '$baseUrl?key=${Uri.encodeQueryComponent(apiKey)}',
    );
    final requestBody = jsonEncode(<String, dynamic>{
      'q': combinedQuery,
      'target': targetLang,
      'format': 'html',
    });

    final http.Response response;
    try {
      response = await _httpClient
          .post(
            uri,
            headers: const <String, String>{
              'Content-Type': 'application/json; charset=utf-8',
            },
            body: requestBody,
          )
          .timeout(requestTimeout);
    } catch (e) {
      _lastErrorMessage = 'GCP Cloud Translation 네트워크 오류: $e';
      throw GcpTranslationException(message: _lastErrorMessage!);
    }

    if (response.statusCode != 200) {
      final detail = _extractApiErrorMessage(response);
      _lastErrorMessage = detail != null
          ? 'GCP Cloud Translation API 오류 (HTTP ${response.statusCode}): $detail'
          : 'GCP Cloud Translation API 오류 (HTTP ${response.statusCode})';
      throw GcpTranslationException(
        statusCode: response.statusCode,
        message: _lastErrorMessage!,
      );
    }

    final parsed = parseResponseJson(_decodeResponseBody(response));
    if (parsed == null) {
      _lastErrorMessage = 'GCP Cloud Translation 응답 파싱에 실패했습니다.';
      throw GcpTranslationException(message: _lastErrorMessage!);
    }

    final mapped = splitAndDecodeTranslations(
      translatedCombined: parsed.translatedText,
      originalTexts: batchTexts,
    );
    if (mapped == null) {
      _lastErrorMessage = 'GCP Cloud Translation 구분자 분리 매핑에 실패했습니다.';
      throw GcpTranslationException(message: _lastErrorMessage!);
    }

    return BatchTranslationResult(
      translations: mapped,
      detectedSourceLanguage: parsed.detectedLanguage,
    );
  }

  /// 문장 목록을 `<span translate="no">|||</span>` 구분자 포함 최대 [maxChars](3,500자) 청크로 묶습니다.
  @visibleForTesting
  static List<List<String>> splitIntoBatches(
    List<String> texts, {
    int maxChars = maxBatchChars,
  }) {
    if (texts.isEmpty) return const [];
    final batches = <List<String>>[];
    var current = <String>[];
    var currentLen = 0;

    for (final text in texts) {
      if (current.isEmpty) {
        current.add(text);
        currentLen = text.length;
        continue;
      }

      final projectedLen = currentLen + batchDelimiter.length + text.length;
      if (projectedLen <= maxChars) {
        current.add(text);
        currentLen = projectedLen;
      } else {
        batches.add(current);
        current = <String>[text];
        currentLen = text.length;
      }
    }

    if (current.isNotEmpty) {
      batches.add(current);
    }
    return batches;
  }

  /// GCP Translation v2 JSON 응답에서 `translatedText`와 `detectedSourceLanguage`를 추출합니다.
  @visibleForTesting
  static ({String translatedText, String? detectedLanguage})? parseResponseJson(
    String rawBody,
  ) {
    if (rawBody.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(rawBody);
      if (decoded is! Map<String, dynamic>) return null;
      final root = decoded['data'] is Map<String, dynamic>
          ? decoded['data'] as Map<String, dynamic>
          : decoded;
      final translations = root['translations'];
      if (translations is! List || translations.isEmpty) return null;

      final first = translations.first;
      if (first is! Map<String, dynamic>) return null;
      final translatedText = first['translatedText'];
      if (translatedText is! String || translatedText.trim().isEmpty) {
        return null;
      }
      final detected = (first['detectedSourceLanguage'] as String?)?.trim();
      return (
        translatedText: translatedText,
        detectedLanguage:
            (detected != null && detected.isNotEmpty) ? detected : null,
      );
    } catch (_) {
      return null;
    }
  }

  /// 응답 문자열을 `|||` 기준으로 분리한 뒤 HTML 엔티티를 디코딩해 원문과 1:1 매핑합니다.
  @visibleForTesting
  static List<String?>? splitAndDecodeTranslations({
    required String translatedCombined,
    required List<String> originalTexts,
  }) {
    if (originalTexts.isEmpty) return const [];
    if (originalTexts.length == 1) {
      final cleaned = decodeHtmlEntities(
        translatedCombined.replaceAll(_strayNoTranslateSpanPattern, ''),
      ).trim();
      return [
        cleaned.isEmpty || cleaned == originalTexts.first ? null : cleaned,
      ];
    }

    var parts = translatedCombined
        .split(_splitDelimiterPattern)
        .map(
          (part) => decodeHtmlEntities(
            part.replaceAll(_strayNoTranslateSpanPattern, ''),
          ).trim(),
        )
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

  /// `&#39;`, `&quot;`, `&amp;` 등 HTML 엔티티를 단일 패스 정규식으로 디코딩합니다.
  @visibleForTesting
  static String decodeHtmlEntities(String input) {
    if (!input.contains('&')) return input;
    return input.replaceAllMapped(_htmlEntityPattern, (match) {
      final dec = match.group(1);
      if (dec != null) {
        final code = int.tryParse(dec);
        if (code != null && code >= 0 && code <= 0x10FFFF) {
          return String.fromCharCode(code);
        }
        return match.group(0)!;
      }

      final hex = match.group(2);
      if (hex != null) {
        final code = int.tryParse(hex, radix: 16);
        if (code != null && code >= 0 && code <= 0x10FFFF) {
          return String.fromCharCode(code);
        }
        return match.group(0)!;
      }

      final named = match.group(3)?.toLowerCase();
      if (named != null) {
        final mapped = _namedHtmlEntities[named];
        if (mapped != null) return mapped;
      }
      return match.group(0)!;
    });
  }

  static String _decodeResponseBody(http.Response response) {
    if (response.bodyBytes.isNotEmpty) {
      return utf8.decode(response.bodyBytes, allowMalformed: true);
    }
    return response.body;
  }

  static String? _extractApiErrorMessage(http.Response response) {
    try {
      final decoded = jsonDecode(_decodeResponseBody(response));
      if (decoded is Map<String, dynamic>) {
        final err = decoded['error'];
        if (err is Map<String, dynamic>) {
          final msg = err['message'];
          if (msg is String && msg.trim().isNotEmpty) {
            return msg.trim();
          }
        }
      }
    } catch (_) {}
    return null;
  }

  static String _normalizeTargetLang(String code) {
    final trimmed = code.trim();
    if (trimmed.isEmpty || trimmed.toLowerCase() == 'auto') return 'ko';
    if (trimmed.toLowerCase() == 'zh') return 'zh-CN';
    return trimmed;
  }

  void dispose() {
    _lastErrorMessage = null;
    if (_ownsClient) {
      _httpClient.close();
    }
  }
}
