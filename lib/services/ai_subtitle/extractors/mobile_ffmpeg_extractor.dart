import 'dart:io';
import 'audio_chunk_extractor.dart';
import 'ffmpeg_kit_chunk_runner.dart';
import 'local_http_audio_relay.dart';

/// Android / iPadOS 전용 FFmpegKit 비동기 오디오 청크 추출기.
class MobileFfmpegExtractor implements AudioChunkExtractor {
  final FfmpegKitChunkRunner _runner = FfmpegKitChunkRunner();

  @override
  Future<bool> isAvailable() async => Platform.isAndroid || Platform.isIOS;

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
        return await _runner.runFfmpegKit(
          args: args,
          outputWavPath: outputWavPath,
          logTag: 'MobileFfmpegExtractor',
        );
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
          return await _runner.runFfmpegKit(
            args: retryArgs,
            outputWavPath: outputWavPath,
            logTag: 'MobileFfmpegExtractor',
          );
        }
        rethrow;
      }
    } finally {
      LocalHttpAudioRelay.instance.unregister(relayUrl);
    }
  }

  @override
  Future<void> cancel() => _runner.cancel();

  @override
  Future<void> dispose() => cancel();
}
