import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'audio_chunk_extractor.dart';
import 'ffmpeg_kit_chunk_runner.dart';
import 'local_http_audio_relay.dart';

/// Windows / Desktop 전용 비동기 FFmpeg 오디오 청크 추출기.
///
/// 1순위: `ffmpeg_kit_flutter_new_min` 네이티브 DLL (`FFmpegKit`)
/// 2순위: 실행 파일 인접 폴더 또는 시스템 PATH의 `ffmpeg.exe` CLI 폴백
class DesktopFfmpegExtractor implements AudioChunkExtractor {
  final FfmpegKitChunkRunner _runner = FfmpegKitChunkRunner();
  Process? _activeProcess;
  String? _resolvedCliPath;
  bool _ffmpegKitMissingPlugin = false;

  @override
  Future<bool> isAvailable() async {
    if (!_ffmpegKitMissingPlugin) return true;
    return (await _findFfmpegExecutable()) != null;
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
    _runner.resetCancel();
    String? relayUrl;

    try {
      final prepared = await FfmpegKitChunkRunner.prepareInputTarget(
        streamUrl: streamUrl,
        httpHeaders: httpHeaders,
      );
      relayUrl = prepared.relayUrl;

      if (_runner.isCancelled) {
        throw const AudioExtractionException(
          '추출 시작 전 취소됨',
          isCancelled: true,
        );
      }

      final allowAllHls = FfmpegKitChunkRunner.shouldUseHlsAllowAll(streamUrl);
      final args = FfmpegKitChunkRunner.buildExtractArgs(
        inputTarget: prepared.inputTarget,
        isRemoteHttp: prepared.isRemoteHttp,
        start: start,
        duration: duration,
        outputWavPath: outputWavPath,
        format: format,
        allowAllHlsExtensions: allowAllHls,
      );

      try {
        return await _runExtractor(args, outputWavPath);
      } on AudioExtractionException catch (e) {
        if (!e.isCancelled &&
            !allowAllHls &&
            FfmpegKitChunkRunner.isHlsExtensionRestrictionLog(e.message)) {
          FfmpegKitChunkRunner.markStreamRequiresHlsAllowAll(streamUrl);
          final retryArgs = FfmpegKitChunkRunner.buildExtractArgs(
            inputTarget: prepared.inputTarget,
            isRemoteHttp: prepared.isRemoteHttp,
            start: start,
            duration: duration,
            outputWavPath: outputWavPath,
            format: format,
            allowAllHlsExtensions: true,
          );
          return await _runExtractor(retryArgs, outputWavPath);
        }
        rethrow;
      }
    } finally {
      _activeProcess = null;
      LocalHttpAudioRelay.instance.unregister(relayUrl);
    }
  }

  Future<File> _runExtractor(List<String> args, String outputWavPath) async {
    // ffmpeg.exe CLI가 있으면 별도 프로세스로 격리 추출(가장 안정적), 없으면 FFmpegKit 사용
    final cliExe = await _findFfmpegExecutable();
    if (cliExe != null) {
      return await _extractViaCli(args, outputWavPath, resolvedExe: cliExe);
    }

    if (!_ffmpegKitMissingPlugin) {
      try {
        return await _runner.runFfmpegKit(
          args: args,
          outputWavPath: outputWavPath,
          logTag: 'DesktopFfmpegExtractor',
        );
      } on MissingPluginException {
        _ffmpegKitMissingPlugin = true;
        debugPrint('[DesktopFfmpegExtractor] FFmpegKit 미등록 -> CLI 폴백 시도');
      } on UnimplementedError {
        _ffmpegKitMissingPlugin = true;
        debugPrint('[DesktopFfmpegExtractor] FFmpegKit 미구현 -> CLI 폴백 시도');
      }
    }

    return await _extractViaCli(args, outputWavPath);
  }

  Future<File> _extractViaCli(
    List<String> args,
    String outputWavPath, {
    String? resolvedExe,
  }) async {
    final exe = resolvedExe ?? await _findFfmpegExecutable();
    if (exe == null) {
      throw const AudioExtractionException(
        'Windows FFmpeg 실행 환경(ffmpeg_kit 또는 ffmpeg.exe)을 찾을 수 없습니다.',
      );
    }

    final process = await Process.start(exe, args);
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

    if (_runner.isCancelled) {
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
    if (_resolvedCliPath != null) return _resolvedCliPath;
    try {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      final bundled = File('$exeDir${Platform.pathSeparator}ffmpeg.exe');
      if (bundled.existsSync()) {
        _resolvedCliPath = bundled.path;
        return _resolvedCliPath;
      }

      final whichCmd = Platform.isWindows ? 'where' : 'which';
      final res = await Process.run(whichCmd, ['ffmpeg']);
      if (res.exitCode == 0) {
        final first =
            res.stdout.toString().trim().split(RegExp(r'[\r\n]+')).firstOrNull;
        if (first != null && first.isNotEmpty) {
          _resolvedCliPath = first;
          return _resolvedCliPath;
        }
      }
    } catch (_) {}
    return null;
  }

  @override
  Future<void> cancel() async {
    await _runner.cancel();
    try {
      _activeProcess?.kill();
    } catch (_) {}
  }

  @override
  Future<void> dispose() => cancel();
}
