import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../../../models/ai_subtitle/ai_subtitle_config.dart';
import '../../../models/ai_subtitle/subtitle_segment.dart';
import '../ai_subtitle_key_storage.dart';
import '../extractors/audio_chunk_extractor.dart';
import '../extractors/desktop_ffmpeg_extractor.dart';
import '../subtitle_generator_engine.dart';

/// 클라우드 AI 자막 엔진 오류 분류.
enum CloudAiErrorType {
  missingApiKey,
  invalidApiKey,
  quotaExceeded,
  networkError,
  audioExtractionFailed,
  invalidResponse,
  cancelled,
}

class CloudAiException implements Exception {
  final CloudAiErrorType type;
  final String message;
  final int? statusCode;

  const CloudAiException(
    this.type,
    this.message, {
    this.statusCode,
  });

  @override
  String toString() => 'CloudAiException($type): $message';
}

/// Phase 2 클라우드 멀티모달 AI(Gemini API) 기반 고품질 자막 생성 & 문맥 의역 엔진.
///
/// 1. FFmpeg로 30~60초 단위 오디오 청크를 경량 포맷(모노 16kHz MP3/AAC, 미지원 시 WAV)으로 추출
/// 2. Gemini Multimodal API(`generateContent`)에 오디오 + Structured Output JSON 스키마를 단일 요청으로 전송
/// 3. 한 번의 호출로 `[상대 시작/종료 타임스탬프 + 원어 전사 + 문맥 한국어 의역]`을 받아 `SubtitleSegment`로 매핑
class CloudAiSubtitleEngine implements SubtitleGeneratorEngine {
  static const List<String> _fallbackModels = <String>[
    'gemini-3.8-flash',
    'gemini-3.1-flash-lite',
    'gemini-3-flash-preview',
    'gemini-2.5-flash',
  ];

  static final Set<AudioChunkFormat> _globalUnsupportedFormats = {};
  static String? _globalWorkingModel;

  final String? apiKey;
  final Future<String?> Function()? apiKeyProvider;
  final String modelName;
  final AudioChunkExtractor _extractor;
  final Dio _dio;
  final bool enableModelFallback;

  int _chunkSeq = 0;
  bool _isCancelled = false;
  CancelToken? _activeCancelToken;
  AudioChunkFormat? _preferredAudioFormat;
  String? _resolvedApiKey;
  String? _resolvedModelName;

  CloudAiSubtitleEngine({
    this.apiKey,
    this.apiKeyProvider,
    this.modelName = 'gemini-3.8-flash',
    AudioChunkExtractor? extractor,
    Dio? dio,
    this.enableModelFallback = true,
  })  : _extractor = extractor ?? AudioChunkExtractor.create(),
        _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 20),
                sendTimeout: const Duration(seconds: 40),
                receiveTimeout: const Duration(seconds: 75),
              ),
            );

  String get _activeModelName {
    if (_resolvedModelName != null) return _resolvedModelName!;
    if (modelName == 'gemini-3.8-flash' && _globalWorkingModel != null) {
      return _globalWorkingModel!;
    }
    return modelName;
  }

  @override
  String get engineId => 'cloud_ai_$_activeModelName';

  @override
  String get displayName => '클라우드 AI ($_activeModelName)';

  @override
  String get acceleratorLabel => 'Gemini Multimodal API';

  Future<String?> _getApiKey() async {
    final direct = apiKey?.trim();
    if (direct != null && direct.isNotEmpty) return direct;
    if (apiKeyProvider != null) {
      final provided = (await apiKeyProvider!())?.trim();
      if (provided != null && provided.isNotEmpty) return provided;
    }
    final stored = (await AiSubtitleKeyStorage.instance.loadApiKey())?.trim();
    if (stored != null && stored.isNotEmpty) return stored;
    return null;
  }

  @override
  Future<bool> isSupported() async {
    final extractorOk = await _extractor.isAvailable();
    if (!extractorOk) return false;
    final key = await _getApiKey();
    return key != null && key.isNotEmpty;
  }

  /// 현재 환경에서 클라우드 AI 엔진을 사용할 수 없는 사유를 반환합니다.
  Future<String?> getUnsupportedReason() async {
    final extractor = _extractor;
    if (!await extractor.isAvailable()) {
      if (extractor is DesktopFfmpegExtractor) {
        return await extractor.getUnavailableReason();
      }
      return '오디오 청크 추출 모듈을 사용할 수 없습니다.';
    }
    final key = await _getApiKey();
    if (key == null || key.isEmpty) {
      return 'Gemini API 키가 입력되지 않았습니다.';
    }
    return null;
  }

  @override
  Future<void> initialize({
    void Function(double progress, String status)? onProgress,
  }) async {
    onProgress?.call(0.3, 'Gemini API 키 확인 중...');
    final key = await _getApiKey();
    if (key == null || key.isEmpty) {
      throw const CloudAiException(
        CloudAiErrorType.missingApiKey,
        'Gemini API 키가 설정되지 않았습니다. 설정에서 API 키를 입력해 주세요.',
      );
    }
    _resolvedApiKey = key;
    onProgress?.call(1.0, '클라우드 AI ($_activeModelName) 준비 완료');
  }

  @override
  Stream<SubtitleSegment> generateSubtitlesForChunk(
    AudioChunkRequest request,
  ) async* {
    _isCancelled = false;
    final key = _resolvedApiKey ?? await _getApiKey();
    if (key == null || key.isEmpty) {
      throw const CloudAiException(
        CloudAiErrorType.missingApiKey,
        'Gemini API 키가 설정되지 않았습니다.',
      );
    }

    final tempDir = Directory('${Directory.systemTemp.path}/ai_sub_cloud_chunks');
    if (!tempDir.existsSync()) {
      tempDir.createSync(recursive: true);
    }

    final seq = ++_chunkSeq;
    File? audioFile;

    try {
      // 1. 경량 오디오 청크 추출 (MP3 -> AAC -> WAV 폴백)
      final extracted = await _extractWithOptimalCodec(
        request: request,
        tempDirPath: tempDir.path,
        seq: seq,
      );
      audioFile = extracted.file;

      if (_isCancelled) {
        throw const CloudAiException(
          CloudAiErrorType.cancelled,
          '작업이 취소되었습니다.',
        );
      }

      final audioBytes = await audioFile.readAsBytes();
      if (audioBytes.isEmpty) {
        throw const CloudAiException(
          CloudAiErrorType.audioExtractionFailed,
          '추출된 오디오 데이터가 비어 있습니다.',
        );
      }

      final base64Audio = base64Encode(audioBytes);
      final cancelToken = CancelToken();
      _activeCancelToken = cancelToken;

      final responseJson = await _requestGeminiWithModelFallback(
        apiKey: key,
        base64Audio: base64Audio,
        mimeType: extracted.format.mimeType,
        request: request,
        cancelToken: cancelToken,
      );

      if (_isCancelled) {
        throw const CloudAiException(
          CloudAiErrorType.cancelled,
          '작업이 취소되었습니다.',
        );
      }

      final segments = parseGeminiResponse(
        responseData: responseJson,
        chunkStart: request.chunkStart,
        chunkDuration: request.chunkDuration,
        sourceLanguageHint: request.sourceLanguage,
      );
      debugPrint(
        '[CloudAiSubtitleEngine] 청크(${request.chunkStart.inSeconds}s, $_activeModelName) 자막 ${segments.length}개 수신',
      );

      for (final seg in segments) {
        if (_isCancelled) return;
        yield seg;
      }
    } finally {
      _activeCancelToken = null;
      if (audioFile != null) {
        try {
          if (audioFile.existsSync()) await audioFile.delete();
        } catch (e) {
          debugPrint('[CloudAiSubtitleEngine] 임시 오디오 삭제 무시: $e');
        }
      }
    }
  }

  Future<({File file, AudioChunkFormat format})> _extractWithOptimalCodec({
    required AudioChunkRequest request,
    required String tempDirPath,
    required int seq,
  }) async {
    final baseOrder = _preferredAudioFormat != null
        ? <AudioChunkFormat>[
            _preferredAudioFormat!,
            if (_preferredAudioFormat != AudioChunkFormat.wav16k)
              AudioChunkFormat.wav16k,
          ]
        : const <AudioChunkFormat>[
            AudioChunkFormat.mp3LowBitrate,
            AudioChunkFormat.aacLowBitrate,
            AudioChunkFormat.wav16k,
          ];

    final candidates = baseOrder
        .where((f) => !_globalUnsupportedFormats.contains(f))
        .toList();
    if (candidates.isEmpty) {
      candidates.add(AudioChunkFormat.wav16k);
    }

    AudioExtractionException? lastErr;
    for (final format in candidates) {
      if (_isCancelled) {
        throw const CloudAiException(
          CloudAiErrorType.cancelled,
          '오디오 추출이 취소되었습니다.',
        );
      }
      final outPath =
          '$tempDirPath/cloud_${request.chunkStart.inMilliseconds}_$seq.${format.fileExtension}';
      try {
        final file = await _extractor.extractChunk(
          streamUrl: request.streamUrl,
          httpHeaders: request.httpHeaders,
          start: request.chunkStart,
          duration: request.chunkDuration,
          outputWavPath: outPath,
          format: format,
        );
        _preferredAudioFormat ??= format;
        return (file: file, format: format);
      } on AudioExtractionException catch (e) {
        if (e.isCancelled || _isCancelled) {
          throw const CloudAiException(
            CloudAiErrorType.cancelled,
            '오디오 추출이 취소되었습니다.',
          );
        }
        lastErr = e;
        if (format != AudioChunkFormat.wav16k) {
          _globalUnsupportedFormats.add(format);
        }
        try {
          final f = File(outPath);
          if (f.existsSync()) await f.delete();
        } catch (_) {}
        debugPrint(
          '[CloudAiSubtitleEngine] ${format.name} 추출 실패, 다음 포맷 폴백 시도: ${e.message}',
        );
      }
    }

    throw CloudAiException(
      CloudAiErrorType.audioExtractionFailed,
      lastErr?.message ?? '오디오 청크 추출에 실패했습니다.',
    );
  }

  Future<Map<String, dynamic>> _requestGeminiWithModelFallback({
    required String apiKey,
    required String base64Audio,
    required String mimeType,
    required AudioChunkRequest request,
    required CancelToken cancelToken,
  }) async {
    final payload = buildGeminiRequestBody(
      base64Audio: base64Audio,
      mimeType: mimeType,
      chunkDuration: request.chunkDuration,
      sourceLanguage: request.sourceLanguage,
      targetLanguage: request.targetLanguage,
    );

    final candidates = <String>[
      _activeModelName,
      if (enableModelFallback) ..._fallbackModels,
    ];
    final tried = <String>{};
    CloudAiException? lastNotFoundError;

    for (final candidate in candidates) {
      if (!tried.add(candidate)) continue;
      try {
        final res = await _postGenerateContent(
          model: candidate,
          apiKey: apiKey,
          payload: payload,
          cancelToken: cancelToken,
        );
        _resolvedModelName = candidate;
        _globalWorkingModel = candidate;
        return res;
      } on CloudAiException catch (e) {
        if (e.statusCode == 404 && enableModelFallback) {
          lastNotFoundError = e;
          debugPrint('[CloudAiSubtitleEngine] 모델 $candidate HTTP 404 -> 대체 모델 시도');
          continue;
        }
        rethrow;
      }
    }

    // 모든 기본 후보가 404일 경우 ListModels API에서 사용 가능한 Flash 모델 자동 탐색
    if (enableModelFallback) {
      final discovered = await _discoverAvailableFlashModel(
        apiKey: apiKey,
        cancelToken: cancelToken,
      );
      if (discovered != null && !tried.contains(discovered)) {
        final res = await _postGenerateContent(
          model: discovered,
          apiKey: apiKey,
          payload: payload,
          cancelToken: cancelToken,
        );
        _resolvedModelName = discovered;
        _globalWorkingModel = discovered;
        return res;
      }
    }

    throw lastNotFoundError ??
        const CloudAiException(
          CloudAiErrorType.invalidResponse,
          '사용 가능한 Gemini 모델을 찾을 수 없습니다 (HTTP 404).',
          statusCode: 404,
        );
  }

  Future<String?> _discoverAvailableFlashModel({
    required String apiKey,
    required CancelToken cancelToken,
  }) async {
    try {
      final res = await _dio.get<dynamic>(
        'https://generativelanguage.googleapis.com/v1beta/models',
        cancelToken: cancelToken,
        options: Options(
          headers: <String, dynamic>{'x-goog-api-key': apiKey},
          responseType: ResponseType.json,
        ),
      );
      final data = res.data;
      if (data is! Map<String, dynamic>) return null;
      final models = data['models'];
      if (models is! List) return null;

      final validFlashNames = <String>[];
      for (final m in models) {
        if (m is! Map<String, dynamic>) continue;
        final name = (m['name'] as String?) ?? '';
        final methods = m['supportedGenerationMethods'];
        final supportsGenerate =
            methods is List && methods.contains('generateContent');
        if (!supportsGenerate) continue;
        final shortName =
            name.startsWith('models/') ? name.substring('models/'.length) : name;
        if (shortName.contains('flash') &&
            !shortName.contains('tts') &&
            !shortName.contains('image')) {
          validFlashNames.add(shortName);
        }
      }
      if (validFlashNames.isEmpty) return null;
      validFlashNames.sort((a, b) => b.compareTo(a));
      debugPrint(
        '[CloudAiSubtitleEngine] 자동 탐색된 Gemini Flash 모델: ${validFlashNames.first}',
      );
      return validFlashNames.first;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>> _postGenerateContent({
    required String model,
    required String apiKey,
    required Map<String, dynamic> payload,
    required CancelToken cancelToken,
  }) async {
    final url =
        'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent';

    try {
      final response = await _dio.post<dynamic>(
        url,
        data: payload,
        cancelToken: cancelToken,
        options: Options(
          headers: <String, dynamic>{
            'Content-Type': 'application/json',
            'x-goog-api-key': apiKey,
          },
          responseType: ResponseType.json,
        ),
      );

      final data = response.data;
      if (data is Map<String, dynamic>) {
        return data;
      }
      if (data is String && data.isNotEmpty) {
        final decoded = jsonDecode(data);
        if (decoded is Map<String, dynamic>) return decoded;
      }
      throw const CloudAiException(
        CloudAiErrorType.invalidResponse,
        'Gemini 응답 형식이 올바르지 않습니다.',
      );
    } on DioException catch (e) {
      if (CancelToken.isCancel(e) || e.type == DioExceptionType.cancel) {
        throw const CloudAiException(
          CloudAiErrorType.cancelled,
          'Gemini API 요청이 취소되었습니다.',
        );
      }
      throw _classifyDioException(e);
    }
  }

  @visibleForTesting
  static Map<String, dynamic> buildGeminiRequestBody({
    required String base64Audio,
    required String mimeType,
    required Duration chunkDuration,
    required String sourceLanguage,
    required String targetLanguage,
  }) {
    final chunkSec = (chunkDuration.inMilliseconds / 1000.0).toStringAsFixed(1);
    final langHint = sourceLanguage == 'auto'
        ? '자동 감지 (음성에서 언어를 스스로 판별하세요)'
        : '${AiSourceLanguageOption.labelOf(sourceLanguage)} ($sourceLanguage)';

    final prompt = '''
당신은 영상 자막 전문 전사 및 의역가입니다.
첨부된 오디오 클립(총 길이 $chunkSec초)의 대사를 듣고, 아래 JSON 스키마에 맞춰 자막 세그먼트 목록을 생성하세요.

[규칙]
1. 원본 음성 언어 힌트: $langHint
2. startSec과 endSec은 이 오디오 클립의 시작(0.0초)을 기준으로 한 상대 시간(초, 소수점 허용)이며, 0.0 <= startSec < endSec <= $chunkSec 범위여야 합니다.
3. 자막 1개는 화면에서 읽기 좋게 자연스러운 호흡/문장 단위(보통 1~5초 내외)로 분할하세요.
4. originalText에는 들리는 원어 대사를 정확히 전사하세요.
5. koreanTranslation에는 앞뒤 문맥과 어조를 살린 자연스러운 한국어 의역을 작성하세요. (이미 한국어 음성인 경우 자연스러운 한국어 문장으로 정리하세요.)
6. 대사가 없는 무음/배경음악/효과음 구간은 생략하고, 클립 전체에 대사가 없으면 segments를 빈 배열 []로 반환하세요.
''';

    return <String, dynamic>{
      'contents': [
        {
          'parts': [
            {
              'inlineData': {
                'mimeType': mimeType,
                'data': base64Audio,
              },
            },
            {
              'text': prompt,
            },
          ],
        },
      ],
      'generationConfig': {
        'temperature': 0.2,
        'responseMimeType': 'application/json',
        'responseSchema': {
          'type': 'OBJECT',
          'properties': {
            'detectedLanguage': {'type': 'STRING'},
            'segments': {
              'type': 'ARRAY',
              'items': {
                'type': 'OBJECT',
                'properties': {
                  'startSec': {'type': 'NUMBER'},
                  'endSec': {'type': 'NUMBER'},
                  'originalText': {'type': 'STRING'},
                  'koreanTranslation': {'type': 'STRING'},
                },
                'required': [
                  'startSec',
                  'endSec',
                  'originalText',
                  'koreanTranslation',
                ],
              },
            },
          },
          'required': ['segments'],
        },
      },
    };
  }

  @visibleForTesting
  static List<SubtitleSegment> parseGeminiResponse({
    required Map<String, dynamic> responseData,
    required Duration chunkStart,
    required Duration chunkDuration,
    String sourceLanguageHint = 'auto',
  }) {
    final candidates = responseData['candidates'];
    if (candidates is! List || candidates.isEmpty) {
      return const [];
    }

    final firstCandidate = candidates.first;
    if (firstCandidate is! Map<String, dynamic>) return const [];
    final content = firstCandidate['content'];
    if (content is! Map<String, dynamic>) return const [];
    final parts = content['parts'];
    if (parts is! List || parts.isEmpty) return const [];

    String? rawText;
    for (final part in parts) {
      if (part is Map<String, dynamic> && part['text'] is String) {
        rawText = part['text'] as String;
        break;
      }
    }
    if (rawText == null || rawText.trim().isEmpty) {
      return const [];
    }

    final cleaned = _stripMarkdownJsonFence(rawText.trim());
    final dynamic decoded;
    try {
      decoded = jsonDecode(cleaned);
    } catch (e) {
      throw CloudAiException(
        CloudAiErrorType.invalidResponse,
        'Gemini JSON 파싱 실패: $e',
      );
    }

    if (decoded is! Map<String, dynamic>) {
      return const [];
    }

    final detectedLang = (decoded['detectedLanguage'] as String?)?.trim();
    final langCode = (detectedLang != null && detectedLang.isNotEmpty)
        ? detectedLang
        : (sourceLanguageHint != 'auto' ? sourceLanguageHint : null);

    final rawSegments = decoded['segments'];
    if (rawSegments is! List) return const [];

    final maxChunkMs = chunkDuration.inMilliseconds;
    final results = <SubtitleSegment>[];

    for (final item in rawSegments) {
      if (item is! Map<String, dynamic>) continue;
      final startSec = (item['startSec'] as num?)?.toDouble();
      final endSec = (item['endSec'] as num?)?.toDouble();
      final orig = ((item['originalText'] as String?) ?? '').trim();
      final trans = ((item['koreanTranslation'] as String?) ?? '').trim();

      if (orig.isEmpty && trans.isEmpty) continue;
      if (startSec == null) continue;

      final relStartMs = (startSec * 1000).round().clamp(0, maxChunkMs);
      var relEndMs = endSec != null
          ? (endSec * 1000).round().clamp(0, maxChunkMs)
          : (relStartMs + 2500).clamp(0, maxChunkMs);

      if (relEndMs <= relStartMs) {
        relEndMs = (relStartMs + 1500).clamp(0, maxChunkMs);
        if (relEndMs <= relStartMs) continue;
      }

      results.add(
        SubtitleSegment(
          startTime: chunkStart + Duration(milliseconds: relStartMs),
          endTime: chunkStart + Duration(milliseconds: relEndMs),
          originalText: orig.isNotEmpty ? orig : trans,
          translatedText: trans.isNotEmpty ? trans : null,
          languageCode: langCode,
        ),
      );
    }

    results.sort((a, b) => a.startTime.compareTo(b.startTime));
    return results;
  }

  static String _stripMarkdownJsonFence(String text) {
    if (!text.startsWith('```')) return text;
    final lines = text.split('\n');
    if (lines.length >= 2 && lines.first.startsWith('```')) {
      lines.removeAt(0);
    }
    if (lines.isNotEmpty && lines.last.trim() == '```') {
      lines.removeLast();
    }
    return lines.join('\n').trim();
  }

  CloudAiException _classifyDioException(DioException e) {
    final statusCode = e.response?.statusCode;
    final rawData = e.response?.data;
    String? apiErrorMsg;
    if (rawData is Map<String, dynamic>) {
      final err = rawData['error'];
      if (err is Map<String, dynamic>) {
        apiErrorMsg = err['message'] as String?;
      }
    }
    final bodyStr = rawData?.toString() ?? '';
    final upperBody = bodyStr.toUpperCase();

    if (statusCode == 429 ||
        upperBody.contains('RESOURCE_EXHAUSTED') ||
        upperBody.contains('QUOTA')) {
      return CloudAiException(
        CloudAiErrorType.quotaExceeded,
        'Gemini API 할당량(Quota)을 초과했습니다.',
        statusCode: statusCode,
      );
    }

    if (statusCode == 401 ||
        statusCode == 403 ||
        upperBody.contains('API_KEY_INVALID') ||
        upperBody.contains('PERMISSION_DENIED')) {
      return CloudAiException(
        CloudAiErrorType.invalidApiKey,
        'Gemini API 키가 유효하지 않거나 권한이 없습니다.',
        statusCode: statusCode,
      );
    }

    if (statusCode != null && statusCode >= 400 && statusCode < 500) {
      final detail = apiErrorMsg != null && apiErrorMsg.isNotEmpty
          ? ' ($apiErrorMsg)'
          : '';
      return CloudAiException(
        CloudAiErrorType.invalidResponse,
        'Gemini API 요청 오류 (HTTP $statusCode)$detail',
        statusCode: statusCode,
      );
    }

    return CloudAiException(
      CloudAiErrorType.networkError,
      '네트워크 연결 또는 Gemini 서버 응답 오류가 발생했습니다.',
      statusCode: statusCode,
    );
  }

  @override
  Future<void> cancelCurrentJob() async {
    _isCancelled = true;
    try {
      _activeCancelToken?.cancel('Cancelled by user/seek');
    } catch (_) {}
    await _extractor.cancel();
  }

  @override
  Future<void> dispose() async {
    _isCancelled = true;
    try {
      _activeCancelToken?.cancel('Engine disposed');
    } catch (_) {}
    await _extractor.dispose();
  }
}
