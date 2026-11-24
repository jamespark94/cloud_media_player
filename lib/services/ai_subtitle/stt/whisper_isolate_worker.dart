import 'dart:async';
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
typedef _GetShortPathNameWNative = Uint32 Function(
  Pointer<Uint16> longPath,
  Pointer<Uint16> shortPath,
  Uint32 bufferLen,
);
typedef _GetShortPathNameWDart = int Function(
  Pointer<Uint16> longPath,
  Pointer<Uint16> shortPath,
  int bufferLen,
);

/// 백그라운드 Isolate / CLI 기반 Whisper.cpp 워커 래퍼.
///
/// - OS별 표준 하드웨어 가속 자동 최적화:
///   * iPadOS / iOS: Apple Accelerate / Metal
///   * Android: ARM NEON SIMD + 멀티스레드 CPU 캡핑 (비디오 디코더 보호)
///   * Windows:
///     1순위: `whisper_ggml.dll` / `whisper.dll` (`request` FFI + CRT 힙 정합성 + 비ASCII 8.3 경로 보정)
///     2순위: `whisper-cli.exe` / `whisper.exe` / `main.exe` 프로세스 호출 및 JSON/타임스탬프 파싱
class WhisperIsolateWorker {
  static final RegExp _cliTimestampLinePattern = RegExp(
    r'^\[(\d{2}:\d{2}:\d{2}[.,]\d{3})\s*-->\s*(\d{2}:\d{2}:\d{2}[.,]\d{3})\]\s*(.*)$',
  );

  final WhisperController _controller = WhisperController();
  @visibleForTesting
  final String? Function()? windowsFfiPathFinderOverride;
  @visibleForTesting
  final Future<String?> Function()? windowsCliPathFinderOverride;
  @visibleForTesting
  final bool? vulkanAvailableOverride;
  @visibleForTesting
  final Future<({int exitCode, String stdout, String stderr})> Function(
    String cliPath,
    List<String> args,
  )? windowsCliRunnerOverride;
  @visibleForTesting
  final Future<String> Function(AiWhisperModelTier tier)? modelPathOverride;

  bool _isModelReady = false;
  bool _isCancelled = false;
  AiWhisperModelTier _currentTier = AiWhisperModelTier.small;
  String? _resolvedWindowsFfiPath;
  bool _hasCheckedWindowsFfi = false;
  String? _resolvedWindowsCliPath;
  bool _hasCheckedWindowsCli = false;
  bool _gpuFallbackTriggered = false;
  bool _activeUsingVulkanGpu = false;
  Process? _activeCliProcess;
  Future<void> _serialTranscribeChain = Future<void>.value();

  WhisperIsolateWorker({
    this.windowsFfiPathFinderOverride,
    this.windowsCliPathFinderOverride,
    this.vulkanAvailableOverride,
    this.windowsCliRunnerOverride,
    this.modelPathOverride,
  });

  /// 현재 OS에서 사용 중인 하드웨어 가속 설명 라벨.
  String get acceleratorLabel {
    if (Platform.isIOS) return 'Apple Accelerate / Metal';
    if (Platform.isAndroid) return 'ARM NEON SIMD (${optimalThreads()}T)';
    if (Platform.isWindows) {
      if (_activeUsingVulkanGpu) {
        return 'Windows Vulkan GPU (whisper-cli -ngl 99)';
      }
      if (_resolvedWindowsFfiPath == null && _resolvedWindowsCliPath != null) {
        return _gpuFallbackTriggered
            ? 'x64 whisper-cli CPU 폴백 (-ngl 0 -t 4)'
            : 'x64 whisper-cli (${optimalThreads()}T)';
      }
      return 'x64 AVX2 CPU (${optimalThreads()}T)';
    }
    return 'CPU (${optimalThreads()}T)';
  }

  /// GPU 초기화 실패로 CPU 폴백이 발생했는지 여부.
  bool get hasFallenBackToCpu => _gpuFallbackTriggered;

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

  String? _findWindowsFfiLibraryPath() {
    if (windowsFfiPathFinderOverride != null) {
      return windowsFfiPathFinderOverride!();
    }
    if (_hasCheckedWindowsFfi) return _resolvedWindowsFfiPath;
    _hasCheckedWindowsFfi = true;

    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final sep = Platform.pathSeparator;
    final candidates = <String>[
      '$exeDir${sep}whisper_ggml.dll',
      '$exeDir${sep}whisper.dll',
      'whisper_ggml.dll',
      'whisper.dll',
    ];

    for (final candidate in candidates) {
      try {
        if (candidate.contains(sep) && !File(candidate).existsSync()) {
          continue;
        }
        final lib = DynamicLibrary.open(candidate);
        if (lib.providesSymbol('request')) {
          _resolvedWindowsFfiPath = candidate;
          return candidate;
        }
      } catch (e) {
        debugPrint('[WhisperIsolateWorker] Windows FFI 프로브 실패($candidate): $e');
      }
    }
    return null;
  }

  Future<String?> _findWindowsCliExecutable() async {
    if (windowsCliPathFinderOverride != null) {
      return windowsCliPathFinderOverride!();
    }
    if (_hasCheckedWindowsCli) return _resolvedWindowsCliPath;
    _hasCheckedWindowsCli = true;

    try {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      final sep = Platform.pathSeparator;
      final bundledCandidates = <String>[
        '$exeDir${sep}whisper-cli.exe',
        '$exeDir${sep}bin${sep}whisper-cli.exe',
        '$exeDir${sep}tools${sep}whisper-cli.exe',
        '$exeDir${sep}whisper${sep}whisper-cli.exe',
        '$exeDir${sep}vulkan${sep}whisper-cli.exe',
        '$exeDir${sep}whisper.exe',
        '$exeDir${sep}main.exe',
      ];
      for (final path in bundledCandidates) {
        if (File(path).existsSync()) {
          _resolvedWindowsCliPath = path;
          return _resolvedWindowsCliPath;
        }
      }

      for (final cmd in const ['whisper-cli', 'whisper']) {
        final res = await Process.run('where', [cmd]);
        if (res.exitCode == 0) {
          final first = res.stdout
              .toString()
              .trim()
              .split(RegExp(r'[\r\n]+'))
              .firstOrNull;
          if (first != null && first.isNotEmpty && File(first).existsSync()) {
            _resolvedWindowsCliPath = first;
            return _resolvedWindowsCliPath;
          }
        }
      }
    } catch (_) {}
    return null;
  }

  /// 네이티브 Whisper FFI 동적 라이브러리 또는 Windows CLI 실행 가능 여부를 안전하게 프로빙합니다.
  /// Windows에서 DLL/CLI 누락이나 미지원 환경이어도 크래시 없이 false를 반환합니다.
  Future<bool> isAvailable() async {
    try {
      if (Platform.isWindows) {
        if (_findWindowsFfiLibraryPath() != null) return true;
        return (await _findWindowsCliExecutable()) != null;
      }

      final DynamicLibrary lib;
      if (Platform.isAndroid) {
        lib = DynamicLibrary.open('libwhisper.so');
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

  Future<String?> getUnavailableReason() async {
    if (await isAvailable()) return null;
    if (Platform.isWindows) {
      return 'Windows 로컬 Whisper 실행 파일(whisper_ggml.dll, whisper.dll 또는 whisper-cli.exe)을 '
          '찾을 수 없습니다.';
    }
    return '현재 기기에서 로컬 Whisper 음성 인식 라이브러리를 사용할 수 없습니다.';
  }

  WhisperModel _toWrapperWhisperModel(AiWhisperModelTier tier) {
    switch (tier) {
      case AiWhisperModelTier.tiny:
        return WhisperModel.tiny;
      case AiWhisperModelTier.base:
        return WhisperModel.base;
      case AiWhisperModelTier.smallQ5_1:
      case AiWhisperModelTier.small:
        return WhisperModel.small;
      case AiWhisperModelTier.largeV3TurboQ5:
        return WhisperModel.large;
    }
  }

  /// `whisper-cli.exe` 인접 폴더 또는 앱 실행 폴더에 `ggml-vulkan.dll`이 존재하는지 확인합니다.
  bool _hasWindowsVulkanRuntime(String cliPath) {
    if (vulkanAvailableOverride != null) {
      return vulkanAvailableOverride!;
    }
    try {
      final sep = Platform.pathSeparator;
      final cliDir = File(cliPath).parent.path;
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      final candidates = <String>[
        '$cliDir${sep}ggml-vulkan.dll',
        '$exeDir${sep}ggml-vulkan.dll',
        '$exeDir${sep}bin${sep}ggml-vulkan.dll',
        '$exeDir${sep}vulkan${sep}ggml-vulkan.dll',
      ];
      return candidates.any((path) => File(path).existsSync());
    } catch (_) {
      return false;
    }
  }

  /// Windows `whisper-cli.exe` 실행 인자를 생성합니다.
  /// - [useGpu]가 `true`이면 Vulkan GPU 레이어 오프로드(`-ngl 99`)를 우선 사용합니다.
  /// - [useGpu]가 `false`이면 CPU 폴백 모드(`-ngl 0 -t 4`) 인자를 구성합니다.
  @visibleForTesting
  static List<String> buildWindowsCliArgs({
    required String modelPath,
    required String wavPath,
    required String sourceLanguage,
    required String outPrefix,
    required bool useGpu,
    int? cpuThreads,
    bool includeNglFlag = true,
  }) {
    final threads = cpuThreads ?? (useGpu ? optimalThreads() : 4);
    return <String>[
      '-m',
      modelPath,
      '-f',
      wavPath,
      '-l',
      sourceLanguage,
      if (includeNglFlag) ...['-ngl', useGpu ? '99' : '0'],
      '-t',
      '$threads',
      '-mc',
      '0',
      '-oj',
      '-of',
      outPrefix,
      '-np',
    ];
  }

  /// 지정된 티어의 GGML 모델 로컬 저장 경로를 반환합니다.
  static Future<String> getModelPath(AiWhisperModelTier tier) async {
    final dir = await WhisperController.getModelDir();
    return '$dir${Platform.pathSeparator}${tier.modelFileName}';
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
    if (modelPathOverride != null) {
      await modelPathOverride!(tier);
      onProgress?.call(1.0, 'Whisper ${tier.shortName} 모델 준비 완료');
    } else {
      await ensureModelDownloaded(
        tier: tier,
        onProgress: onProgress,
      );
    }
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

  /// Windows C `fopen`이 비ASCII 경로(한글 사용자명 등)를 열지 못하는 문제를 방지하기 위해
  /// 가능한 경우 Win32 `GetShortPathNameW` 8.3 경로로 변환합니다.
  static String _toWindowsAsciiSafePath(String path) {
    if (!Platform.isWindows) return path;
    if (path.codeUnits.every((c) => c <= 127)) return path;

    try {
      final crt = DynamicLibrary.open('ucrtbase.dll');
      final mallocFn =
          crt.lookupFunction<_CrtMallocNative, _CrtMallocDart>('malloc');
      final freeFn = crt.lookupFunction<_CrtFreeNative, _CrtFreeDart>('free');
      final k32 = DynamicLibrary.open('kernel32.dll');
      final getShortPathNameW = k32.lookupFunction<_GetShortPathNameWNative,
          _GetShortPathNameWDart>('GetShortPathNameW');

      final units = path.codeUnits;
      final inPtr = mallocFn((units.length + 1) * 2).cast<Uint16>();
      const outBufLen = 1024;
      final outPtr = mallocFn(outBufLen * 2).cast<Uint16>();
      try {
        inPtr.asTypedList(units.length + 1)
          ..setAll(0, units)
          ..[units.length] = 0;

        final written = getShortPathNameW(inPtr, outPtr, outBufLen);
        if (written > 0 && written < outBufLen) {
          return String.fromCharCodes(outPtr.asTypedList(written));
        }
      } finally {
        freeFn(inPtr.cast());
        freeFn(outPtr.cast());
      }
    } catch (_) {}
    return path;
  }

  /// Windows에서 `whisper_ggml` 패키지의 `malloc.free(res)`가 `CoTaskMemFree`를 호출해
  /// C CRT `malloc()` 포인터와 충돌(`0xc0000374` Heap Corruption)하는 문제를 우회하기 위해,
  /// `whisper_ggml.dll`과 동일한 CRT(`ucrtbased.dll` 또는 `ucrtbase.dll`)의 `free()`를 직접 호출합니다.
  static Future<Map<String, dynamic>> _invokeWhisperRequestOnWindows({
    required String dllPath,
    required String requestJson,
  }) {
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

        final whisperLib = DynamicLibrary.open(dllPath);
        final requestFn =
            whisperLib.lookupFunction<_WReqNative, _WReqNative>('request');
        resPtr = requestFn(reqPtr);
        if (resPtr.address == 0) {
          throw StateError('$dllPath이 null 응답을 반환했습니다.');
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

  /// 16kHz Mono WAV 청크를 백그라운드 Isolate(또는 Windows `whisper-cli.exe`)에서 추론하여
  /// 절대 타임스탬프가 반영된 세그먼트를 반환합니다.
  ///
  /// 동시 실행 제한(Single Worker Serial Queue)으로 이전 추론이 끝나기 전에
  /// 중복 Whisper 프로세스가 병렬 실행되지 않도록 직렬화합니다.
  Future<List<SubtitleSegment>> transcribeChunk({
    required String wavPath,
    required Duration chunkOffset,
    required Duration chunkDuration,
    required String sourceLanguage,
  }) {
    final completer = Completer<List<SubtitleSegment>>();
    _serialTranscribeChain = _serialTranscribeChain.then((_) async {
      try {
        final res = await _transcribeChunkSerial(
          wavPath: wavPath,
          chunkOffset: chunkOffset,
          chunkDuration: chunkDuration,
          sourceLanguage: sourceLanguage,
        );
        if (!completer.isCompleted) completer.complete(res);
      } catch (e, st) {
        if (!completer.isCompleted) completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  Future<List<SubtitleSegment>> _transcribeChunkSerial({
    required String wavPath,
    required Duration chunkOffset,
    required Duration chunkDuration,
    required String sourceLanguage,
  }) async {
    if (!_isModelReady) {
      throw StateError('Whisper 모델이 초기화되지 않았습니다.');
    }
    _isCancelled = false;

    final model = _toWrapperWhisperModel(_currentTier);
    final modelPath = modelPathOverride != null
        ? await modelPathOverride!(_currentTier)
        : await getModelPath(_currentTier);

    try {
      if (Platform.isWindows) {
        return await _transcribeOnWindows(
          wavPath: wavPath,
          modelPath: modelPath,
          chunkOffset: chunkOffset,
          chunkDuration: chunkDuration,
          sourceLanguage: sourceLanguage,
        );
      }

      final whisper = Whisper(model: model);
      final response = await whisper.transcribe(
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

      return _mapWrapperResponseToSegments(
        response: response,
        chunkOffset: chunkOffset,
        chunkDuration: chunkDuration,
        sourceLanguage: sourceLanguage,
      );
    } finally {
      // whisper_ggml이 내부적으로 생성할 수 있는 변환 파일($wavPath.wav) 정리
      try {
        final extraWav = File('$wavPath.wav');
        if (extraWav.existsSync()) await extraWav.delete();
      } catch (_) {}
    }
  }

  Future<List<SubtitleSegment>> _transcribeOnWindows({
    required String wavPath,
    required String modelPath,
    required Duration chunkOffset,
    required Duration chunkDuration,
    required String sourceLanguage,
  }) async {
    final cliPath = await _findWindowsCliExecutable();
    final dllPath = _findWindowsFfiLibraryPath();
    final preferVulkanCli =
        cliPath != null && _hasWindowsVulkanRuntime(cliPath) && !_gpuFallbackTriggered;

    // 1순위: Vulkan GPU 가속을 지원하는 whisper-cli.exe (ggml-vulkan.dll + -ngl 99)
    if (preferVulkanCli || (dllPath == null && cliPath != null)) {
      try {
        return await _transcribeViaWindowsCli(
          cliPath: cliPath,
          wavPath: wavPath,
          modelPath: modelPath,
          chunkOffset: chunkOffset,
          chunkDuration: chunkDuration,
          sourceLanguage: sourceLanguage,
        );
      } catch (e) {
        if (dllPath == null || _isCancelled) rethrow;
        debugPrint(
          '[WhisperIsolateWorker] whisper-cli.exe 실패 -> FFI 폴백 시도: $e',
        );
      }
    }

    if (dllPath != null) {
      try {
        final safeWav = _toWindowsAsciiSafePath(wavPath);
        final safeModel = _toWindowsAsciiSafePath(modelPath);
        final requestJson = jsonEncode({
          '@type': 'getTextFromWavFile',
          'audio': safeWav,
          'model': safeModel,
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
        final rawMap = await _invokeWhisperRequestOnWindows(
          dllPath: dllPath,
          requestJson: requestJson,
        );
        if (rawMap['text'] == null) {
          throw Exception(rawMap['message'] ?? 'Whisper FFI 추론 오류');
        }
        _activeUsingVulkanGpu = false;
        final response = WhisperTranscribeResponse.fromJson(rawMap);
        return _mapWrapperResponseToSegments(
          response: response,
          chunkOffset: chunkOffset,
          chunkDuration: chunkDuration,
          sourceLanguage: sourceLanguage,
        );
      } catch (e) {
        if (cliPath == null || _isCancelled) rethrow;
        debugPrint(
          '[WhisperIsolateWorker] Windows FFI 실패 -> whisper-cli.exe 폴백 시도: $e',
        );
      }
    }

    if (cliPath != null) {
      return await _transcribeViaWindowsCli(
        cliPath: cliPath,
        wavPath: wavPath,
        modelPath: modelPath,
        chunkOffset: chunkOffset,
        chunkDuration: chunkDuration,
        sourceLanguage: sourceLanguage,
      );
    }

    throw StateError(
      (await getUnavailableReason()) ??
          'Windows 로컬 Whisper 실행 파일(whisper_ggml.dll / whisper-cli.exe)을 찾을 수 없습니다.',
    );
  }

  Future<({int exitCode, String stdout, String stderr})> _runWindowsCliProcess(
    String cliPath,
    List<String> args,
  ) async {
    if (windowsCliRunnerOverride != null) {
      return windowsCliRunnerOverride!(cliPath, args);
    }

    final process = await Process.start(cliPath, args);
    _activeCliProcess = process;

    final stdoutBuf = StringBuffer();
    final stderrBuf = StringBuffer();
    final stdoutSub = process.stdout
        .transform(utf8.decoder)
        .listen(stdoutBuf.write, onError: (_) {});
    final stderrSub = process.stderr
        .transform(SystemEncoding().decoder)
        .listen(stderrBuf.write, onError: (_) {});

    try {
      final exitCode = await process.exitCode.timeout(
        const Duration(seconds: 90),
        onTimeout: () {
          process.kill();
          return -1;
        },
      );
      await stdoutSub.cancel();
      await stderrSub.cancel();
      return (
        exitCode: exitCode,
        stdout: stdoutBuf.toString(),
        stderr: stderrBuf.toString(),
      );
    } finally {
      _activeCliProcess = null;
    }
  }

  static bool _isUnsupportedNglArgumentError(String stderrText) {
    final lower = stderrText.toLowerCase();
    return lower.contains('-ngl') &&
        (lower.contains('unknown') ||
            lower.contains('invalid') ||
            lower.contains('unrecognized'));
  }

  Future<List<SubtitleSegment>> _transcribeViaWindowsCli({
    required String cliPath,
    required String wavPath,
    required String modelPath,
    required Duration chunkOffset,
    required Duration chunkDuration,
    required String sourceLanguage,
  }) async {
    final outPrefix = '$wavPath.out';
    final outJsonFile = File('$outPrefix.json');
    final hasVulkan = _hasWindowsVulkanRuntime(cliPath);
    final tryGpuFirst = hasVulkan && !_gpuFallbackTriggered;

    Future<List<SubtitleSegment>> parseCliOutput(
      ({int exitCode, String stdout, String stderr}) res,
    ) async {
      if (outJsonFile.existsSync()) {
        final rawJson = await outJsonFile.readAsString();
        final parsed = parseWhisperCliJson(
          jsonString: rawJson,
          chunkOffset: chunkOffset,
          chunkDuration: chunkDuration,
          sourceLanguage: sourceLanguage,
        );
        if (parsed.isNotEmpty) return parsed;
      }
      return parseWhisperCliStdout(
        stdoutText: res.stdout,
        chunkOffset: chunkOffset,
        chunkDuration: chunkDuration,
        sourceLanguage: sourceLanguage,
      );
    }

    try {
      var usedGpu = tryGpuFirst;
      var args = buildWindowsCliArgs(
        modelPath: modelPath,
        wavPath: wavPath,
        sourceLanguage: sourceLanguage,
        outPrefix: outPrefix,
        useGpu: usedGpu,
        cpuThreads: usedGpu ? optimalThreads() : 4,
      );

      var res = await _runWindowsCliProcess(cliPath, args);
      if (_isCancelled) return const [];

      // GPU(-ngl 99) 초기화 또는 실행 실패 시 자동으로 CPU 모드(-ngl 0 -t 4) 폴백 재시도
      if (usedGpu && res.exitCode != 0) {
        debugPrint(
          '[WhisperIsolateWorker] Vulkan GPU(-ngl 99) 초기화/실행 실패 -> CPU 폴백(-ngl 0 -t 4) 전환: ${res.stderr}',
        );
        _gpuFallbackTriggered = true;
        _activeUsingVulkanGpu = false;
        usedGpu = false;
        if (outJsonFile.existsSync()) {
          await outJsonFile.delete().catchError((_) => outJsonFile);
        }
        args = buildWindowsCliArgs(
          modelPath: modelPath,
          wavPath: wavPath,
          sourceLanguage: sourceLanguage,
          outPrefix: outPrefix,
          useGpu: false,
          cpuThreads: 4,
        );
        res = await _runWindowsCliProcess(cliPath, args);
        if (_isCancelled) return const [];
      }

      // 구형 CPU-only whisper-cli 바이너리가 -ngl 인자를 미지원할 경우 제거 후 재시도
      if (res.exitCode != 0 && _isUnsupportedNglArgumentError(res.stderr)) {
        _gpuFallbackTriggered = true;
        _activeUsingVulkanGpu = false;
        usedGpu = false;
        args = buildWindowsCliArgs(
          modelPath: modelPath,
          wavPath: wavPath,
          sourceLanguage: sourceLanguage,
          outPrefix: outPrefix,
          useGpu: false,
          cpuThreads: 4,
          includeNglFlag: false,
        );
        res = await _runWindowsCliProcess(cliPath, args);
        if (_isCancelled) return const [];
      }

      if (res.exitCode != 0) {
        throw Exception(
          'whisper-cli 실행 실패 (exit=${res.exitCode}): ${res.stderr}',
        );
      }

      _activeUsingVulkanGpu = usedGpu;
      return await parseCliOutput(res);
    } finally {
      _activeCliProcess = null;
      try {
        if (outJsonFile.existsSync()) await outJsonFile.delete();
      } catch (_) {}
    }
  }

  static List<SubtitleSegment> _mapWrapperResponseToSegments({
    required WhisperTranscribeResponse response,
    required Duration chunkOffset,
    required Duration chunkDuration,
    required String sourceLanguage,
  }) {
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
  }

  /// `whisper-cli.exe -oj` JSON 출력(`transcription` 배열)을 [SubtitleSegment] 목록으로 변환합니다.
  @visibleForTesting
  static List<SubtitleSegment> parseWhisperCliJson({
    required String jsonString,
    required Duration chunkOffset,
    required Duration chunkDuration,
    String sourceLanguage = 'auto',
  }) {
    if (jsonString.trim().isEmpty) return const [];
    final dynamic decoded = jsonDecode(jsonString);
    if (decoded is! Map<String, dynamic>) return const [];

    String? detectedLang;
    final resultMeta = decoded['result'];
    if (resultMeta is Map<String, dynamic> && resultMeta['language'] is String) {
      final lang = (resultMeta['language'] as String).trim();
      if (lang.isNotEmpty && lang != 'auto') {
        detectedLang = lang;
      }
    }
    final effectiveLang =
        sourceLanguage != 'auto' ? sourceLanguage : detectedLang;

    final list = decoded['transcription'];
    if (list is! List) return const [];

    final results = <SubtitleSegment>[];
    for (final item in list) {
      if (item is! Map<String, dynamic>) continue;
      final cleaned = _sanitizeTranscript((item['text'] as String?) ?? '');
      if (cleaned.isEmpty) continue;

      Duration? relStart;
      Duration? relEnd;
      final offsets = item['offsets'];
      if (offsets is Map<String, dynamic>) {
        final fromMs = offsets['from'];
        final toMs = offsets['to'];
        if (fromMs is num) relStart = Duration(milliseconds: fromMs.round());
        if (toMs is num) relEnd = Duration(milliseconds: toMs.round());
      }

      if (relStart == null || relEnd == null) {
        final ts = item['timestamps'];
        if (ts is Map<String, dynamic>) {
          relStart ??= _parseCliTimestamp(ts['from'] as String?);
          relEnd ??= _parseCliTimestamp(ts['to'] as String?);
        }
      }

      final start = chunkOffset + (relStart ?? Duration.zero);
      var end = chunkOffset +
          (relEnd ?? ((relStart ?? Duration.zero) + const Duration(seconds: 2)));
      if (end <= start) {
        end = start + const Duration(seconds: 2);
      }

      results.add(
        SubtitleSegment(
          startTime: start,
          endTime: end,
          originalText: cleaned,
          languageCode: effectiveLang,
        ),
      );
    }
    return results;
  }

  /// `whisper-cli.exe` / `main.exe` 표준 출력(`[00:00:00.000 --> 00:00:03.200] text`) 파싱.
  @visibleForTesting
  static List<SubtitleSegment> parseWhisperCliStdout({
    required String stdoutText,
    required Duration chunkOffset,
    required Duration chunkDuration,
    String sourceLanguage = 'auto',
  }) {
    if (stdoutText.trim().isEmpty) return const [];
    final effectiveLang = sourceLanguage == 'auto' ? null : sourceLanguage;
    final results = <SubtitleSegment>[];

    for (final rawLine in stdoutText.split(RegExp(r'\r?\n'))) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      final match = _cliTimestampLinePattern.firstMatch(line);
      if (match == null) continue;

      final relStart = _parseCliTimestamp(match.group(1));
      final relEnd = _parseCliTimestamp(match.group(2));
      final cleaned = _sanitizeTranscript(match.group(3) ?? '');
      if (relStart == null || cleaned.isEmpty) continue;

      final start = chunkOffset + relStart;
      var end = chunkOffset +
          (relEnd ?? (relStart + const Duration(seconds: 2)));
      if (end <= start) {
        end = start + const Duration(seconds: 2);
      }

      results.add(
        SubtitleSegment(
          startTime: start,
          endTime: end,
          originalText: cleaned,
          languageCode: effectiveLang,
        ),
      );
    }

    return results;
  }

  static Duration? _parseCliTimestamp(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final match = RegExp(r'(\d{2}):(\d{2}):(\d{2})[.,](\d{3})').firstMatch(raw);
    if (match == null) return null;
    final h = int.parse(match.group(1)!);
    final m = int.parse(match.group(2)!);
    final s = int.parse(match.group(3)!);
    final ms = int.parse(match.group(4)!);
    return Duration(hours: h, minutes: m, seconds: s, milliseconds: ms);
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

  Future<void> cancel() async {
    _isCancelled = true;
    try {
      _activeCliProcess?.kill();
    } catch (_) {}
  }

  /// 네이티브 메모리에 파킹된 Whisper 컨텍스트를 즉시 해제합니다.
  Future<void> release() async {
    _isModelReady = false;
    await cancel();
    try {
      if (Platform.isWindows) {
        final dllPath = _findWindowsFfiLibraryPath();
        if (dllPath != null) {
          await _invokeWhisperRequestOnWindows(
            dllPath: dllPath,
            requestJson: jsonEncode({'@type': 'releaseModel'}),
          );
        }
      } else {
        await _controller.releaseModel();
      }
    } catch (_) {}
  }
}
