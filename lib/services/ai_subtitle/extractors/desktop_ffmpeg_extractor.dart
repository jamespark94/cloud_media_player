import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'audio_chunk_extractor.dart';
import 'ffmpeg_extract_helpers.dart';
import 'local_http_audio_relay.dart';
import 'mpv_windows_audio_extractor.dart';

/// Windows / Desktop 전용 비동기 오디오 청크 추출기.
///
/// 모바일용 `ffmpeg_kit_flutter`에 의존하지 않고 아래 우선순위로 추출합니다:
/// 1순위: 실행 파일 인접 폴더 또는 시스템 PATH의 `ffmpeg.exe` (`ffmpeg`) CLI 프로세스
/// 2순위: (Windows) 기존 플레이어 엔진(`media_kit`)의 번들 `libmpv-2.dll` FFI 추출
///        (`ffmpeg.exe`가 없는 기본 Windows 배포 환경에서도 16kHz Mono PCM WAV 즉시 추출)
class DesktopFfmpegExtractor implements AudioChunkExtractor {
  final MpvWindowsAudioExtractor _mpvExtractor;
  @visibleForTesting
  final Future<String?> Function()? ffmpegPathFinderOverride;
  @visibleForTesting
  final bool Function()? mpvAvailableOverride;

  Process? _activeProcess;
  String? _resolvedCliPath;
  bool _hasCheckedCliPath = false;
  bool _isCancelled = false;

  DesktopFfmpegExtractor({
    MpvWindowsAudioExtractor? mpvExtractor,
    this.ffmpegPathFinderOverride,
    this.mpvAvailableOverride,
  }) : _mpvExtractor = mpvExtractor ?? MpvWindowsAudioExtractor();

  @override
  Future<bool> isAvailable() async {
    final cli = await _findFfmpegExecutable();
    if (cli != null) return true;
    if (Platform.isWindows) {
      return _isMpvAvailable();
    }
    return false;
  }

  Future<String?> getUnavailableReason() async {
    if (await isAvailable()) return null;
    if (Platform.isWindows) {
      return 'Windows 오디오 추출 모듈(ffmpeg.exe 또는 libmpv-2.dll)을 찾을 수 없습니다. '
          '앱 실행 폴더 또는 PATH에 ffmpeg.exe를 배치해 주세요.';
    }
    return '데스크톱 오디오 추출 바이너리(ffmpeg)를 찾을 수 없습니다.';
  }

  bool _isMpvAvailable() {
    if (mpvAvailableOverride != null) {
      return mpvAvailableOverride!();
    }
    return _mpvExtractor.isAvailable();
  }

  @override
  Future<File> extractChunk({
    required String streamUrl,
    required Map<String, String> httpHeaders,
    required Duration start,
    required Duration duration,
    required String outputWavPath,
    AudioChunkFormat format = AudioChunkFormat.wav16k,
  }) async {
    _isCancelled = false;
    _mpvExtractor.resetCancel();
    String? relayUrl;

    try {
      final prepared = await FfmpegExtractHelpers.prepareInputTarget(
        streamUrl: streamUrl,
        httpHeaders: httpHeaders,
      );
      relayUrl = prepared.relayUrl;

      if (_isCancelled) {
        throw const AudioExtractionException(
          '추출 시작 전 취소됨',
          isCancelled: true,
        );
      }

      // 1순위: Windows / Desktop ffmpeg 바이너리 CLI 호출
      final cliExe = await _findFfmpegExecutable();
      if (cliExe != null) {
        final allowAllHls =
            FfmpegExtractHelpers.shouldUseHlsAllowAll(streamUrl);
        final args = FfmpegExtractHelpers.buildExtractArgs(
          inputTarget: prepared.inputTarget,
          isRemoteHttp: prepared.isRemoteHttp,
          start: start,
          duration: duration,
          outputWavPath: outputWavPath,
          format: format,
          allowAllHlsExtensions: allowAllHls,
        );

        try {
          return await _extractViaCli(
            args,
            outputWavPath,
            resolvedExe: cliExe,
          );
        } on AudioExtractionException catch (e) {
          if (!e.isCancelled &&
              !allowAllHls &&
              FfmpegExtractHelpers.isHlsExtensionRestrictionLog(e.message)) {
            FfmpegExtractHelpers.markStreamRequiresHlsAllowAll(streamUrl);
            final retryArgs = FfmpegExtractHelpers.buildExtractArgs(
              inputTarget: prepared.inputTarget,
              isRemoteHttp: prepared.isRemoteHttp,
              start: start,
              duration: duration,
              outputWavPath: outputWavPath,
              format: format,
              allowAllHlsExtensions: true,
            );
            return await _extractViaCli(
              retryArgs,
              outputWavPath,
              resolvedExe: cliExe,
            );
          }
          rethrow;
        }
      }

      // 2순위: Windows 번들 libmpv-2.dll (기존 플레이어의 Windows 미디어 엔진)으로 WAV 추출
      if (Platform.isWindows && _isMpvAvailable()) {
        if (format != AudioChunkFormat.wav16k) {
          throw AudioExtractionException(
            'ffmpeg.exe 미설치 환경에서 libmpv 폴백은 ${format.name} 포맷을 지원하지 않습니다.',
          );
        }
        return await _mpvExtractor.extractWavChunk(
          inputTarget: prepared.inputTarget,
          start: start,
          duration: duration,
          outputWavPath: outputWavPath,
        );
      }

      throw AudioExtractionException(
        (await getUnavailableReason()) ??
            'Windows 오디오 추출 실행 파일(ffmpeg.exe 또는 libmpv-2.dll)을 찾을 수 없습니다.',
      );
    } finally {
      _activeProcess = null;
      LocalHttpAudioRelay.instance.unregister(relayUrl);
    }
  }

  Future<File> _extractViaCli(
    List<String> args,
    String outputWavPath, {
    required String resolvedExe,
  }) async {
    final process = await Process.start(resolvedExe, args);
    _activeProcess = process;

    final stderrBuf = StringBuffer();
    process.stderr.transform(SystemEncoding().decoder).listen(stderrBuf.write);

    final exitCode = await process.exitCode.timeout(
      const Duration(seconds: 40),
      onTimeout: () {
        process.kill();
        return -1;
      },
    );

    if (_isCancelled) {
      throw const AudioExtractionException(
        '오디오 청크 추출 취소됨',
        isCancelled: true,
      );
    }
    if (exitCode != 0) {
      throw AudioExtractionException(
        'FFmpeg CLI 추출 실패 (exit=$exitCode): $stderrBuf',
      );
    }

    final outFile = File(outputWavPath);
    if (!outFile.existsSync() || outFile.lengthSync() <= 44) {
      throw const AudioExtractionException('추출된 오디오 파일이 비어 있습니다.');
    }
    return outFile;
  }

  Future<String?> _findFfmpegExecutable() async {
    if (ffmpegPathFinderOverride != null) {
      return ffmpegPathFinderOverride!();
    }
    if (_hasCheckedCliPath) return _resolvedCliPath;
    _hasCheckedCliPath = true;

    try {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      final sep = Platform.pathSeparator;
      final binName = Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg';
      final bundledCandidates = <String>[
        '$exeDir$sep$binName',
        '$exeDir${sep}bin$sep$binName',
        '$exeDir${sep}tools$sep$binName',
      ];
      for (final path in bundledCandidates) {
        if (File(path).existsSync()) {
          _resolvedCliPath = path;
          return _resolvedCliPath;
        }
      }

      final whichCmd = Platform.isWindows ? 'where' : 'which';
      final res = await Process.run(whichCmd, ['ffmpeg']);
      if (res.exitCode == 0) {
        final first =
            res.stdout.toString().trim().split(RegExp(r'[\r\n]+')).firstOrNull;
        if (first != null && first.isNotEmpty && File(first).existsSync()) {
          _resolvedCliPath = first;
          return _resolvedCliPath;
        }
      }
    } catch (_) {}
    return null;
  }

  @override
  Future<void> cancel() async {
    _isCancelled = true;
    await _mpvExtractor.cancel();
    try {
      _activeProcess?.kill();
    } catch (_) {}
  }

  @override
  Future<void> dispose() => cancel();
}
