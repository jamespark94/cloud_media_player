import 'dart:io';
import 'desktop_ffmpeg_extractor.dart';
import 'mobile_ffmpeg_extractor.dart';

/// 오디오 청크 추출 출력 포맷.
/// - [wav16k]: 16kHz Mono PCM WAV (온디바이스 Whisper 전용)
/// - [mp3LowBitrate]: 16kHz Mono 32kbps MP3 (클라우드 AI 전송 최적화)
/// - [aacLowBitrate]: 16kHz Mono 32kbps AAC ADTS (클라우드 AI 전송 최적화 폴백)
enum AudioChunkFormat {
  wav16k('wav', 'audio/wav'),
  mp3LowBitrate('mp3', 'audio/mp3'),
  aacLowBitrate('aac', 'audio/aac');

  final String fileExtension;
  final String mimeType;

  const AudioChunkFormat(this.fileExtension, this.mimeType);
}

/// 오디오 청크 추출 실패 예외 (호출부에서 조용히 로깅 및 스킵 처리).
class AudioExtractionException implements Exception {
  final String message;
  final int? statusCode;
  final bool isCancelled;

  const AudioExtractionException(
    this.message, {
    this.statusCode,
    this.isCancelled = false,
  });

  @override
  String toString() => 'AudioExtractionException: $message';
}

/// 영상 스트림 또는 로컬 파일에서 특정 구간의 음성(16kHz, Mono)을
/// 가볍게 추출하는 플랫폼 독립 인터페이스.
abstract class AudioChunkExtractor {
  Future<bool> isAvailable();

  /// [streamUrl]의 [start] 시점부터 [duration] 길이만큼 오디오를 추출해 [outputWavPath]에 저장합니다.
  /// [format]을 생략하면 기존 온디바이스 호환을 위해 `AudioChunkFormat.wav16k`로 추출합니다.
  Future<File> extractChunk({
    required String streamUrl,
    required Map<String, String> httpHeaders,
    required Duration start,
    required Duration duration,
    required String outputWavPath,
    AudioChunkFormat format = AudioChunkFormat.wav16k,
  });

  /// 진행 중인 추출 세션을 즉시 중단합니다.
  Future<void> cancel();

  Future<void> dispose();

  factory AudioChunkExtractor.create() {
    if (Platform.isAndroid || Platform.isIOS) {
      return MobileFfmpegExtractor();
    }
    return DesktopFfmpegExtractor();
  }
}
