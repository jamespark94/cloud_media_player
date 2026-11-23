import 'dart:io';
import 'package:flutter/foundation.dart';
import '../../../models/ai_subtitle/subtitle_segment.dart';
import '../extractors/audio_chunk_extractor.dart';
import '../subtitle_generator_engine.dart';
import 'whisper_isolate_worker.dart';

/// 오디오 청크(16kHz Mono PCM WAV)를 추출하고 로컬 `whisper.cpp` 워커로 전사한 뒤
/// 임시 WAV 파일을 정리하는 공통 STT 파이프라인 헬퍼.
Future<List<SubtitleSegment>> extractAndTranscribeChunkWithWhisper({
  required AudioChunkExtractor extractor,
  required WhisperIsolateWorker whisperWorker,
  required AudioChunkRequest request,
  required int chunkSequence,
  required bool Function() isCancelled,
  String tempFolderName = 'ai_sub_chunks',
}) async {
  final tempDir = Directory('${Directory.systemTemp.path}/$tempFolderName');
  if (!tempDir.existsSync()) {
    tempDir.createSync(recursive: true);
  }

  final wavPath =
      '${tempDir.path}/chunk_${request.chunkStart.inMilliseconds}_$chunkSequence.wav';
  final wavFile = File(wavPath);

  try {
    await extractor.extractChunk(
      streamUrl: request.streamUrl,
      httpHeaders: request.httpHeaders,
      start: request.chunkStart,
      duration: request.chunkDuration,
      outputWavPath: wavPath,
    );

    if (isCancelled()) return const [];

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
