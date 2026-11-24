import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/foundation.dart';
import 'audio_chunk_extractor.dart';

typedef _MpvCreateNative = Pointer<Void> Function();
typedef _MpvCreateDart = Pointer<Void> Function();
typedef _MpvInitNative = Int32 Function(Pointer<Void> ctx);
typedef _MpvInitDart = int Function(Pointer<Void> ctx);
typedef _MpvDestroyNative = Void Function(Pointer<Void> ctx);
typedef _MpvDestroyDart = void Function(Pointer<Void> ctx);
typedef _MpvSetOptStrNative = Int32 Function(
  Pointer<Void> ctx,
  Pointer<Uint8> name,
  Pointer<Uint8> data,
);
typedef _MpvSetOptStrDart = int Function(
  Pointer<Void> ctx,
  Pointer<Uint8> name,
  Pointer<Uint8> data,
);
typedef _MpvCommandNative = Int32 Function(
  Pointer<Void> ctx,
  Pointer<Pointer<Uint8>> args,
);
typedef _MpvCommandDart = int Function(
  Pointer<Void> ctx,
  Pointer<Pointer<Uint8>> args,
);
typedef _MpvWaitEventNative = Pointer<_MpvEvent> Function(
  Pointer<Void> ctx,
  Double timeout,
);
typedef _MpvWaitEventDart = Pointer<_MpvEvent> Function(
  Pointer<Void> ctx,
  double timeout,
);

final class _MpvEvent extends Struct {
  @Int32()
  external int eventId;
  @Int32()
  external int error;
  @Uint64()
  external int replyUserdata;
  external Pointer<Void> data;
}

typedef _CrtMallocNative = Pointer<Uint8> Function(Size size);
typedef _CrtMallocDart = Pointer<Uint8> Function(int size);
typedef _CrtFreeNative = Void Function(Pointer<Uint8> ptr);
typedef _CrtFreeDart = void Function(Pointer<Uint8> ptr);

/// Windows에서 기존 `media_kit` 플레이어가 번들하는 `libmpv-2.dll`을 FFI로 직접 호출해
/// `ffmpeg.exe`가 없는 환경에서도 16kHz Mono 16-bit PCM WAV 청크를 추출하는 폴백 추출기.
class MpvWindowsAudioExtractor {
  static const int _mpvEventShutdown = 1;
  static const int _mpvEventEndFile = 7;

  String? _resolvedLibPath;
  SendPort? _activeCancelPort;
  bool _isCancelled = false;

  /// 실행 파일 인접 폴더 또는 DLL 검색 경로에서 `libmpv-2.dll`을 탐색합니다.
  String? findLibraryPath() {
    if (!Platform.isWindows) return null;
    if (_resolvedLibPath != null) return _resolvedLibPath;

    final candidates = <String>[
      '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}libmpv-2.dll',
      'libmpv-2.dll',
    ];

    for (final candidate in candidates) {
      try {
        if (candidate.contains(Platform.pathSeparator) &&
            !File(candidate).existsSync()) {
          continue;
        }
        final lib = DynamicLibrary.open(candidate);
        if (lib.providesSymbol('mpv_create') &&
            lib.providesSymbol('mpv_initialize') &&
            lib.providesSymbol('mpv_command') &&
            lib.providesSymbol('mpv_wait_event') &&
            lib.providesSymbol('mpv_terminate_destroy')) {
          _resolvedLibPath = candidate;
          return candidate;
        }
      } catch (_) {}
    }
    return null;
  }

  bool isAvailable() => findLibraryPath() != null;

  void resetCancel() {
    _isCancelled = false;
  }

  Future<File> extractWavChunk({
    required String inputTarget,
    required Duration start,
    required Duration duration,
    required String outputWavPath,
    Duration timeout = const Duration(seconds: 40),
  }) async {
    final libPath = findLibraryPath();
    if (libPath == null) {
      throw const AudioExtractionException(
        'Windows 오디오 추출기(libmpv-2.dll)를 찾을 수 없습니다.',
      );
    }
    if (_isCancelled) {
      throw const AudioExtractionException(
        '오디오 청크 추출 취소됨',
        isCancelled: true,
      );
    }

    final resultPort = ReceivePort();
    final controlReadyPort = ReceivePort();
    Isolate? workerIsolate;

    try {
      workerIsolate = await Isolate.spawn(
        _extractInIsolate,
        <_StringOrDynamic>[
          resultPort.sendPort,
          controlReadyPort.sendPort,
          libPath,
          inputTarget,
          (start.inMilliseconds / 1000.0).toStringAsFixed(3),
          (duration.inMilliseconds / 1000.0).toStringAsFixed(3),
          outputWavPath,
          timeout.inMilliseconds,
        ].cast<dynamic>(),
      );

      final controlPortCompleter = Completer<SendPort>();
      final resultCompleter = Completer<Map<String, dynamic>>();

      controlReadyPort.listen((msg) {
        if (msg is SendPort && !controlPortCompleter.isCompleted) {
          controlPortCompleter.complete(msg);
        }
      });

      resultPort.listen((msg) {
        if (msg is Map<String, dynamic> && !resultCompleter.isCompleted) {
          resultCompleter.complete(msg);
        }
      });

      final cancelPort = await controlPortCompleter.future.timeout(
        const Duration(seconds: 5),
      );
      _activeCancelPort = cancelPort;

      if (_isCancelled) {
        cancelPort.send('cancel');
      }

      final res = await resultCompleter.future.timeout(
        timeout + const Duration(seconds: 3),
        onTimeout: () {
          cancelPort.send('cancel');
          return <String, dynamic>{
            'ok': false,
            'error': 'libmpv 오디오 추출 시간 초과',
          };
        },
      );

      if (_isCancelled || res['cancelled'] == true) {
        throw const AudioExtractionException(
          '오디오 청크 추출 취소됨',
          isCancelled: true,
        );
      }

      if (res['ok'] != true) {
        throw AudioExtractionException(
          (res['error'] as String?) ?? 'libmpv 오디오 추출에 실패했습니다.',
        );
      }

      final outFile = File(outputWavPath);
      if (!outFile.existsSync() || outFile.lengthSync() <= 128) {
        throw const AudioExtractionException('추출된 오디오 파일이 비어 있습니다.');
      }
      return outFile;
    } on AudioExtractionException {
      rethrow;
    } catch (e) {
      throw AudioExtractionException('libmpv 오디오 추출 오류: $e');
    } finally {
      _activeCancelPort = null;
      resultPort.close();
      controlReadyPort.close();
      workerIsolate?.kill(priority: Isolate.immediate);
    }
  }

  Future<void> cancel() async {
    _isCancelled = true;
    try {
      _activeCancelPort?.send('cancel');
    } catch (_) {}
  }

  static Future<void> _extractInIsolate(List<dynamic> args) async {
    final resultPort = args[0] as SendPort;
    final controlReadyPort = args[1] as SendPort;
    final libPath = args[2] as String;
    final inputTarget = args[3] as String;
    final startSec = args[4] as String;
    final durSec = args[5] as String;
    final outputWavPath = args[6] as String;
    final timeoutMs = args[7] as int;

    final controlPort = ReceivePort();
    var cancelRequested = false;
    controlPort.listen((msg) {
      if (msg == 'cancel') {
        cancelRequested = true;
      }
    });
    controlReadyPort.send(controlPort.sendPort);

    Pointer<Void> ctx = nullptr;
    _MpvDestroyDart? mpvDestroy;

    try {
      final crt = DynamicLibrary.open('ucrtbase.dll');
      final mallocFn =
          crt.lookupFunction<_CrtMallocNative, _CrtMallocDart>('malloc');
      final freeFn = crt.lookupFunction<_CrtFreeNative, _CrtFreeDart>('free');

      Pointer<Uint8> toCStr(String s) {
        final bytes = utf8.encode(s);
        final ptr = mallocFn(bytes.length + 1);
        ptr.asTypedList(bytes.length + 1)
          ..setAll(0, bytes)
          ..[bytes.length] = 0;
        return ptr;
      }

      final mpv = DynamicLibrary.open(libPath);
      final mpvCreate =
          mpv.lookupFunction<_MpvCreateNative, _MpvCreateDart>('mpv_create');
      final mpvInit =
          mpv.lookupFunction<_MpvInitNative, _MpvInitDart>('mpv_initialize');
      mpvDestroy = mpv.lookupFunction<_MpvDestroyNative, _MpvDestroyDart>(
        'mpv_terminate_destroy',
      );
      final mpvSetOpt =
          mpv.lookupFunction<_MpvSetOptStrNative, _MpvSetOptStrDart>(
        'mpv_set_option_string',
      );
      final mpvCmd =
          mpv.lookupFunction<_MpvCommandNative, _MpvCommandDart>('mpv_command');
      final mpvWait = mpv.lookupFunction<_MpvWaitEventNative, _MpvWaitEventDart>(
        'mpv_wait_event',
      );

      ctx = mpvCreate();
      if (ctx.address == 0) {
        resultPort.send(<String, dynamic>{
          'ok': false,
          'error': 'mpv_create() 실패',
        });
        return;
      }

      void setOpt(String k, String v) {
        final kp = toCStr(k);
        final vp = toCStr(v);
        try {
          mpvSetOpt(ctx, kp, vp);
        } finally {
          freeFn(kp);
          freeFn(vp);
        }
      }

      setOpt('vo', 'null');
      setOpt('vid', 'no');
      setOpt('sid', 'no');
      setOpt('ao', 'pcm');
      setOpt('ao-pcm-file', outputWavPath);
      setOpt('ao-pcm-waveheader', 'yes');
      setOpt('audio-channels', 'mono');
      setOpt('audio-format', 's16');
      setOpt('audio-samplerate', '16000');
      setOpt('untimed', 'yes');
      setOpt('audio-display', 'no');
      setOpt('quiet', 'yes');
      setOpt('network-timeout', '15');
      setOpt('start', startSec);
      setOpt('length', durSec);

      final initRc = mpvInit(ctx);
      if (initRc < 0) {
        resultPort.send(<String, dynamic>{
          'ok': false,
          'error': 'mpv_initialize 실패 (code=$initRc)',
        });
        return;
      }

      final cmdLoad = toCStr('loadfile');
      final cmdTarget = toCStr(inputTarget);
      final cmdArgs =
          mallocFn(sizeOf<Pointer<Uint8>>() * 3).cast<Pointer<Uint8>>();
      int loadRc;
      try {
        cmdArgs[0] = cmdLoad;
        cmdArgs[1] = cmdTarget;
        cmdArgs[2] = nullptr;
        loadRc = mpvCmd(ctx, cmdArgs);
      } finally {
        freeFn(cmdLoad);
        freeFn(cmdTarget);
        freeFn(cmdArgs.cast());
      }

      if (loadRc < 0) {
        resultPort.send(<String, dynamic>{
          'ok': false,
          'error': 'mpv loadfile 실패 (code=$loadRc)',
        });
        return;
      }

      final sw = Stopwatch()..start();
      var endError = 0;
      var finished = false;
      while (!cancelRequested && sw.elapsedMilliseconds < timeoutMs) {
        final ev = mpvWait(ctx, 0.08);
        final eid = ev.ref.eventId;
        if (eid == _mpvEventEndFile) {
          endError = ev.ref.error;
          finished = true;
          break;
        }
        if (eid == _mpvEventShutdown) {
          finished = true;
          break;
        }
        // ReceivePort 취소 메시지 처리를 위해 이벤트 루프 양보
        await Future<void>.delayed(Duration.zero);
      }

      if (cancelRequested) {
        resultPort.send(<String, dynamic>{'ok': false, 'cancelled': true});
        return;
      }
      if (!finished) {
        resultPort.send(<String, dynamic>{
          'ok': false,
          'error': 'libmpv 오디오 추출 시간 초과',
        });
        return;
      }
      if (endError < 0) {
        resultPort.send(<String, dynamic>{
          'ok': false,
          'error': 'libmpv 오디오 디코딩 오류 (code=$endError)',
        });
        return;
      }

      resultPort.send(<String, dynamic>{'ok': true});
    } catch (e) {
      debugPrint('[MpvWindowsAudioExtractor] 추출 예외: $e');
      resultPort.send(<String, dynamic>{
        'ok': false,
        'error': e.toString(),
      });
    } finally {
      if (ctx.address != 0 && mpvDestroy != null) {
        try {
          mpvDestroy(ctx);
        } catch (_) {}
      }
      controlPort.close();
    }
  }
}

typedef _StringOrDynamic = dynamic;
