import '../../models/ai_subtitle/subtitle_segment.dart';

/// 단일 오디오 청크 처리 요청 컨텍스트 (읽기 전용 스냅샷).
class AudioChunkRequest {
  final String mediaItemId;
  final String streamUrl;
  final Map<String, String> httpHeaders;
  final Duration chunkStart;
  final Duration chunkDuration;
  final String sourceLanguage;
  final String targetLanguage;

  /// 백그라운드 선행 추출이 완료된 로컬 WAV 파일 경로(있으면 재추출 생략).
  final String? preExtractedWavPath;

  /// Whisper STT 실행 직전 Stale 여부(현재 재생 시간 >= 청크 종료 시간)를 확인하는 콜백.
  final bool Function()? shouldSkipBeforeTranscribe;

  const AudioChunkRequest({
    required this.mediaItemId,
    required this.streamUrl,
    required this.httpHeaders,
    required this.chunkStart,
    required this.chunkDuration,
    this.sourceLanguage = 'auto',
    this.targetLanguage = 'ko',
    this.preExtractedWavPath,
    this.shouldSkipBeforeTranscribe,
  });
}

/// Phase 1(온디바이스 Whisper + ML Kit) 및 Phase 2(클라우드 AI 멀티모달) 엔진이
/// 구현해야 하는 Strategy Pattern 공통 추상 인터페이스.
abstract class SubtitleGeneratorEngine {
  String get engineId;
  String get displayName;

  /// 현재 OS/하드웨어에서 사용 중인 가속 백엔드 설명 문자열.
  String get acceleratorLabel;

  /// 현재 플랫폼(Android / iPadOS / Windows)에서 이 엔진이 구동 가능한지 검사합니다.
  Future<bool> isSupported();

  /// 모델 다운로드/로딩 등 초기화 (토글 ON 시점에만 지연 호출).
  Future<void> initialize({
    void Function(double progress, String status)? onProgress,
  });

  /// 지정된 구간([AudioChunkRequest])의 오디오를 추출하여 STT/번역된 자막 세그먼트를 생성합니다.
  Stream<SubtitleSegment> generateSubtitlesForChunk(AudioChunkRequest request);

  /// Seek 또는 중지 시 현재 진행 중인 오디오 추출/추론 작업을 취소합니다.
  Future<void> cancelCurrentJob();

  /// 토글 OFF 또는 플레이어 종료 시 모델/워커 리소스를 즉시 해제합니다.
  Future<void> dispose();
}
