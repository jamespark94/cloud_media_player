import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/foundation.dart';
import 'package:whisper_ggml/whisper_ggml.dart';
import '../../../models/ai_subtitle/ai_subtitle_config.dart';
import '../../../models/ai_subtitle/subtitle_segment.dart';

typedef _WReqNative = Pointer<Uint8> Function(Pointer<Uint8> body);
typedef _CrtMallocNative = Pointer<Uint8> Function(Size size);
typedef _CrtMallocDart = Pointer<Uint8> Function(int size);
typedef _CrtFreeNative = Void Function(Pointer<Uint8> ptr);
typedef _CrtFreeDart = void Function(Pointer<Uint8> ptr);
typedef _GetModuleHandleANative = Pointer<Void> Function(Pointer<Uint8> name);
typedef _GetModuleHandleADart = Pointer<Void> Function(Pointer<Uint8> name);

/// 백그라운드 Isolate 기반 Whisper.cpp FFI 워커 래퍼.
///
/// - OS별 표준 하드웨어 가속 자동 최적화:
///   * iPadOS / iOS: Apple Accelerate / Metal
///   * Android: ARM NEON SIMD + 멀티스레드 캡핑 (비디오 디코더 보호)
///   * Windows: x86_64 AVX2 + 멀티스레드 CPU (CRT malloc/free 정합성 보장)
class WhisperIsolateWorker {
  final WhisperController _controller = WhisperController();
  bool _isModelReady = false;
  AiWhisperModelTier _currentTier = AiWhisperModelTier.base;

  /// 현재 OS에서 사용 중인 하드웨어 가속 설명 라벨.
  String get acceleratorLabel {
    if (Platform.isIOS) return 'Apple Accelerate / Metal';
    if (Platform.isAndroid) return 'ARM NEON SIMD (${optimalThreads()}T)';
    if (Platform.isWindows) return 'x64 AVX2 CPU (${optimalThreads()}T)';
    return 'CPU (${optimalThreads()}T)';
  }

  /// 플랫폼별 비디오 디코더 보호 스레드 수 산정.
  static int optimalThreads() {
    final cores = Platform.numberOfProcessors;
    if (Platform.isAndroid) {
      return (cores - 2).clamp(2, 4);
    }
    if (Platform.isIOS) {
      return (cores - 1).clamp(2, 4);
    }
    if (Platform.isWindows) {
      return (cores ~/ 2).clamp(2, 6);
    }
    return (cores ~/ 2).clamp(1, 4);
  }

  /// 네이티브 Whisper FFI 동적 라이브러리 로드 가능 여부를 안전하게 프로빙합니다.
  /// Windows에서 DLL 빌드 누락이나 미지원 환경이어도 크래시 없이 false를 반환합니다.
  Future<bool> isAvailable() async {
    try {
      final DynamicLibrary lib;
      if (Platform.isAndroid) {
        lib = DynamicLibrary.open('libwhisper.so');
      } else if (Platform.isWindows) {
        lib = DynamicLibrary.open('whisper_ggml.dll');
      } else if (Platform.isLinux) {
        lib = DynamicLibrary.open('libwhisper_ggml.so');
      } else if (Platform.isIOS || Platform.isMacOS) {
        lib = DynamicLibrary.process();
      } else {
        return false;
      }
      return lib.providesSymbol('request');
    } catch (e) {
      debugPrint('[WhisperIsolateWorker] 네이티브 라이브러리 로드 불가(Stub 폴백): $e');
      return false;
    }
  }

  WhisperModel _toWrapperWhisperModel(AiWhisperModelTier tier) {
    switch (tier) {
      case AiWhisperModelTier.tiny:
        return WhisperModel.tiny;
      case AiWhisperModelTier.base:
        return WhisperModel.base;
      case AiWhisperModelTier.small:
        return WhisperModel.small;
      case AiWhisperModelTier.largeV3TurboQ5:
        return WhisperModel.large;
    }
  }

  /// 지정된 티어의 GGML 모델 로컬 저장 경로를 반환합니다.
  static Future<String> getModelPath(AiWhisperModelTier tier) async {
    final dir = await WhisperController.getModelDir();
    return '$dir/${tier.modelFileName}';
  }

  /// 지정된 티어의 Whisper 모델이 이미 로컬에 다운로드되었는지 확인합니다.
  static Future<bool> isModelDownloaded(AiWhisperModelTier tier) async {
    try {
      final path = await getModelPath(tier);
      final file = File(path);
      return file.existsSync() && file.lengthSync() > 1024 * 1024;
    } catch (_) {
      return false;
    }
  }

  /// HuggingFace 공식 `ggerganov/whisper.cpp` 모델 다운로드 URL을 반환합니다.
  static Uri getModelDownloadUri(AiWhisperModelTier tier) {
    return Uri.parse(
      'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/${tier.modelFileName}',
    );
  }

  /// 설정 화면 등에서 사용자가 선택한 모델을 사전 다운로드할 수 있는 정적 헬퍼.
  static Future<String> ensureModelDownloaded({
    required AiWhisperModelTier tier,
    void Function(double progress, String status)? onProgress,
  }) async {
    final modelPath = await getModelPath(tier);
    final modelFile = File(modelPath);
    if (modelFile.existsSync() && modelFile.lengthSync() > 1024 * 1024) {
      onProgress?.call(1.0, 'Whisper ${tier.shortName} 모델 준비 완료');
      return modelPath;
    }

    onProgress?.call(0.0, 'Whisper ${tier.shortName} 모델 다운로드 중...');
    await _downloadModelWithProgress(
      uri: getModelDownloadUri(tier),
      destinationPath: modelPath,
      tierLabel: tier.shortName,
      onProgress: onProgress,
    );
    return modelPath;
  }

  /// 토글 ON 시점에만 호출되어 선택된 GGML 모델을 온디맨드 다운로드합니다.
  Future<void> initialize({
    required AiWhisperModelTier tier,
    void Function(double progress, String status)? onProgress,
  }) async {
    if (_isModelReady && _currentTier != tier) {
      await release();
    }
    _currentTier = tier;
    await ensureModelDownloaded(
      tier: tier,
      onProgress: onProgress,
    );
    _isModelReady = true;
  }

  static Future<void> _downloadModelWithProgress({
    required Uri uri,
    required String destinationPath,
    required String tierLabel,
    void Function(double progress, String status)? onProgress,
  }) async {
    final dir = File(destinationPath).parent;
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }

    final tmpFile = File('$destinationPath.tmp');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    IOSink? sink;
    try {
      final request = await client.getUrl(uri);
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          '모델 다운로드 실패 (HTTP ${response.statusCode})',
          uri: uri,
        );
      }

      final totalBytes = response.contentLength;
      var receivedBytes = 0;
      sink = tmpFile.openWrite();

      await for (final chunk in response) {
        sink.add(chunk);
        receivedBytes += chunk.length;
        if (totalBytes > 0) {
          final ratio = (receivedBytes / totalBytes).clamp(0.0, 1.0);
          final pct = (ratio * 100).round();
          onProgress?.call(ratio, 'Whisper $tierLabel 모델 다운로드 중 ($pct%)...');
        }
      }
      await sink.flush();
      await sink.close();
      sink = null;

      if (File(destinationPath).existsSync()) {
        await File(destinationPath).delete();
      }
      await tmpFile.rename(destinationPath);
      onProgress?.call(1.0, 'Whisper $tierLabel 모델 다운로드 완료');
    } catch (e) {
      try {
        await sink?.close();
      } catch (_) {}
      try {
        if (tmpFile.existsSync()) await tmpFile.delete();
      } catch (_) {}
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  /// Windows에서 `whisper_ggml` 패키지의 `malloc.free(res)`가 `CoTaskMemFree`를 호출해
  /// C CRT `malloc()` 포인터와 충돌(`0xc0000374` Heap Corruption)하는 문제를 우회하기 위해,
  /// `whisper_ggml.dll`과 동일한 CRT(`ucrtbased.dll` 또는 `ucrtbase.dll`)의 `free()`를 직접 호출합니다.
  static Future<Map<String, dynamic>> _invokeWhisperRequestOnWindows(
    String requestJson,
  ) {
    return Isolate.run(() {
      final baseCrt = DynamicLibrary.open('ucrtbase.dll');
      final baseMalloc =
          baseCrt.lookupFunction<_CrtMallocNative, _CrtMallocDart>('malloc');
      final baseFree =
          baseCrt.lookupFunction<_CrtFreeNative, _CrtFreeDart>('free');

      // Debug 빌드에서는 whisper_ggml.dll이 ucrtbased.dll 힙을 사용하므로 우선 확인
      DynamicLibrary targetCrt = baseCrt;
      try {
        final k32 = DynamicLibrary.open('kernel32.dll');
        final getModuleHandleA = k32.lookupFunction<_GetModuleHandleANative,
            _GetModuleHandleADart>('GetModuleHandleA');
        final dbgName = utf8.encode('ucrtbased.dll');
        final namePtr = baseMalloc(dbgName.length + 1);
        try {
          namePtr.asTypedList(dbgName.length + 1)
            ..setAll(0, dbgName)
            ..[dbgName.length] = 0;
          final handle = getModuleHandleA(namePtr);
          if (handle.address != 0) {
            targetCrt = DynamicLibrary.open('ucrtbased.dll');
          }
        } finally {
          baseFree(namePtr);
        }
      } catch (_) {}

      final crtMalloc =
          targetCrt.lookupFunction<_CrtMallocNative, _CrtMallocDart>('malloc');
      final crtFree =
          targetCrt.lookupFunction<_CrtFreeNative, _CrtFreeDart>('free');

      final reqBytes = utf8.encode(requestJson);
      final reqPtr = crtMalloc(reqBytes.length + 1);
      if (reqPtr.address == 0) {
        throw StateError('Windows CRT malloc 실패');
      }

      Pointer<Uint8> resPtr = nullptr;
      try {
        reqPtr.asTypedList(reqBytes.length + 1)
          ..setAll(0, reqBytes)
          ..[reqBytes.length] = 0;

        final whisperLib = DynamicLibrary.open('whisper_ggml.dll');
        final requestFn =
            whisperLib.lookupFunction<_WReqNative, _WReqNative>('request');
        resPtr = requestFn(reqPtr);
        if (resPtr.address == 0) {
          throw StateError('whisper_ggml.dll이 null 응답을 반환했습니다.');
        }

        var len = 0;
        while (resPtr[len] != 0) {
          len++;
        }
        final resStr = utf8.decode(resPtr.asTypedList(len), allowMalformed: true);
        return json.decode(resStr) as Map<String, dynamic>;
      } finally {
        crtFree(reqPtr);
        if (resPtr.address != 0) {
          crtFree(resPtr);
        }
      }
    });
  }

  /// 16kHz Mono WAV 청크를 백그라운드 Isolate에서 추론하여 절대 타임스탬프가 반영된 세그먼트를 반환합니다.
  Future<List<SubtitleSegment>> transcribeChunk({
    required String wavPath,
    required Duration chunkOffset,
    required Duration chunkDuration,
    required String sourceLanguage,
  }) async {
    if (!_isModelReady) {
      throw StateError('Whisper 모델이 초기화되지 않았습니다.');
    }

    final model = _toWrapperWhisperModel(_currentTier);
    final modelPath = await getModelPath(_currentTier);

    try {
      final WhisperTranscribeResponse response;
      if (Platform.isWindows) {
        final requestJson = jsonEncode({
          '@type': 'getTextFromWavFile',
          'audio': wavPath,
          'model': modelPath,
          'is_translate': false,
          'threads': optimalThreads(),
          'is_verbose': false,
          'language': sourceLanguage,
          'is_special_tokens': false,
          'is_no_timestamps': false,
          'n_processors': 1,
          'split_on_word': false,
          'no_fallback': false,
          'is_realtime': false,
          'diarize': false,
          'speed_up': false,
          'no_context': true,
          'max_context': 0,
          'suppress_non_speech_tokens': true,
          'keep_model_loaded': true,
        });
        final rawMap = await _invokeWhisperRequestOnWindows(requestJson);
        if (rawMap['text'] == null) {
          throw Exception(rawMap['message'] ?? 'Whisper 추론 오류');
        }
        response = WhisperTranscribeResponse.fromJson(rawMap);
      } else {
        final whisper = Whisper(model: model);
        response = await whisper.transcribe(
          transcribeRequest: TranscribeRequest(
            audio: wavPath,
            language: sourceLanguage,
            threads: optimalThreads(),
            isTranslate: false,
            isNoTimestamps: false,
            isRealtime: false,
            noContext: true,
            maxContext: 0,
            suppressNonSpeechTokens: true,
            keepModelLoaded: true,
          ),
          modelPath: modelPath,
        );
      }

      final rawSegments = response.segments;
      final results = <SubtitleSegment>[];

      if (rawSegments != null && rawSegments.isNotEmpty) {
        for (final seg in rawSegments) {
          final cleaned = _sanitizeTranscript(seg.text);
          if (cleaned.isEmpty) continue;
          final absStart = chunkOffset + seg.fromTs;
          var absEnd = chunkOffset + seg.toTs;
          if (absEnd <= absStart) {
            absEnd = absStart + const Duration(seconds: 2);
          }
          results.add(
            SubtitleSegment(
              startTime: absStart,
              endTime: absEnd,
              originalText: cleaned,
              languageCode: sourceLanguage == 'auto' ? null : sourceLanguage,
            ),
          );
        }
      } else {
        final cleaned = _sanitizeTranscript(response.text);
        if (cleaned.isNotEmpty) {
          results.add(
            SubtitleSegment(
              startTime: chunkOffset,
              endTime: chunkOffset + chunkDuration,
              originalText: cleaned,
              languageCode: sourceLanguage == 'auto' ? null : sourceLanguage,
            ),
          );
        }
      }

      return results;
    } finally {
      // whisper_ggml이 내부적으로 생성할 수 있는 변환 파일($wavPath.wav) 정리
      try {
        final extraWav = File('$wavPath.wav');
        if (extraWav.existsSync()) await extraWav.delete();
      } catch (_) {}
    }
  }

  /// Whisper 비발화/잡음 환각 토큰 제거.
  static String _sanitizeTranscript(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return '';
    // [BLANK_AUDIO], [Music], (applause) 등 괄호형 비음성 주석 필터링
    final stripped = text
        .replaceAll(RegExp(r'\[[^\]]*\]'), '')
        .replaceAll(RegExp(r'\([^\)]*\)'), '')
        .trim();
    if (stripped.isEmpty) return '';
    return text;
  }

  /// 네이티브 메모리에 파킹된 Whisper 컨텍스트를 즉시 해제합니다.
  Future<void> release() async {
    _isModelReady = false;
    try {
      if (Platform.isWindows) {
        await _invokeWhisperRequestOnWindows(
          jsonEncode({'@type': 'releaseModel'}),
        );
      } else {
        await _controller.releaseModel();
      }
    } catch (_) {}
  }
}
