import 'dart:io';
import 'package:flutter/foundation.dart';
import '../../../models/ai_subtitle/subtitle_segment.dart';
import '../extractors/audio_chunk_extractor.dart';
import '../subtitle_generator_engine.dart';
import 'whisper_isolate_worker.dart';

/// 오디오 청크(16kHz Mono PCM WAV)를 추출하고 로컬 `whisper.cpp` 워커로 전사한 뒤
/// 임시 WAV 파일을 정리하는 공통 STT 파이프라인 헬퍼.
///
/// - [AudioChunkRequest.preExtractedWavPath]가 유효하면 오디오 재추출을 건너뜁니다.
/// - Whisper 실행 직전 [AudioChunkRequest.shouldSkipBeforeTranscribe]가 `true`를 반환하면
///   이미 지나간(Stale) 구간이므로 STT 연산 없이 임시 WAV만 즉시 폐기합니다.
Future<List<SubtitleSegment>> extractAndTranscribeChunkWithWhisper({
  required AudioChunkExtractor extractor,
  required WhisperIsolateWorker whisperWorker,
  required AudioChunkRequest request,
  required int chunkSequence,
  required bool Function() isCancelled,
  String tempFolderName = 'ai_sub_chunks',
}) async {
  final prePath = request.preExtractedWavPath;
  final preFile = prePath != null ? File(prePath) : null;
  final hasPreExtracted =
      preFile != null && preFile.existsSync() && preFile.lengthSync() > 44;

  late final String wavPath;
  if (hasPreExtracted) {
    wavPath = prePath!;
  } else {
    final tempDir = Directory('${Directory.systemTemp.path}/$tempFolderName');
    if (!tempDir.existsSync()) {
      tempDir.createSync(recursive: true);
    }
    wavPath =
        '${tempDir.path}/chunk_${request.chunkStart.inMilliseconds}_$chunkSequence.wav';
  }
  final wavFile = File(wavPath);

  try {
    if (!hasPreExtracted) {
      await extractor.extractChunk(
        streamUrl: request.streamUrl,
        httpHeaders: request.httpHeaders,
        start: request.chunkStart,
        duration: request.chunkDuration,
        outputWavPath: wavPath,
      );
    }

    if (isCancelled()) return const [];

    if (request.shouldSkipBeforeTranscribe?.call() == true) {
      debugPrint(
        '[WhisperChunkRunner] Stale 청크 즉시 폐기 '
        '(${request.chunkStart.inSeconds}s~${(request.chunkStart + request.chunkDuration).inSeconds}s)',
      );
      return const [];
    }

    return await whisperWorker.transcribeChunk(
      wavPath: wavPath,
      chunkOffset: request.chunkStart,
      chunkDuration: request.chunkDuration,
      sourceLanguage: request.sourceLanguage,
    );
  } finally {
    try {
      if (wavFile.existsSync()) await wavFile.delete();
    } catch (e) {
      debugPrint('[WhisperChunkRunner] 임시 WAV 삭제 무시: $e');
    }
  }
}
