import 'audio_chunk_extractor.dart';
import 'local_http_audio_relay.dart';

/// 순수 Dart 기반 FFmpeg 추출 인자 및 Loopback HTTP 릴레이 준비 헬퍼.
///
/// Windows 데스크톱(`DesktopFfmpegExtractor`)이 모바일용 `ffmpeg_kit_flutter` 패키지를
/// 임포트하지 않고도 동일한 Seek/HLS 우회/포맷 인자 생성 로직을 공유할 수 있도록 분리되었습니다.
class FfmpegExtractHelpers {
  static final Set<String> _hlsAllowAllStreamUrls = <String>{};

  static bool shouldUseHlsAllowAll(String streamUrl) {
    final lower = streamUrl.toLowerCase();
    return lower.contains('.m3u8') || _hlsAllowAllStreamUrls.contains(streamUrl);
  }

  static void markStreamRequiresHlsAllowAll(String streamUrl) {
    _hlsAllowAllStreamUrls.add(streamUrl);
  }

  static bool isHlsExtensionRestrictionLog(String logs) {
    return logs.contains('allowed_segment_extensions') ||
        logs.contains('extension_picky');
  }

  static List<String> buildExtractArgs({
    required String inputTarget,
    required bool isRemoteHttp,
    required Duration start,
    required Duration duration,
    required String outputWavPath,
    AudioChunkFormat format = AudioChunkFormat.wav16k,
    bool allowAllHlsExtensions = false,
  }) {
    final startSec = (start.inMilliseconds / 1000.0).toStringAsFixed(3);
    final durSec = (duration.inMilliseconds / 1000.0).toStringAsFixed(3);

    final codecArgs = switch (format) {
      AudioChunkFormat.wav16k => <String>[
          '-c:a',
          'pcm_s16le',
          '-f',
          'wav',
        ],
      AudioChunkFormat.mp3LowBitrate => <String>[
          '-c:a',
          'libmp3lame',
          '-b:a',
          '32k',
          '-f',
          'mp3',
        ],
      AudioChunkFormat.aacLowBitrate => <String>[
          '-c:a',
          'aac',
          '-b:a',
          '32k',
          '-f',
          'adts',
        ],
    };

    return <String>[
      '-nostdin',
      '-y',
      '-loglevel',
      'error',
      if (isRemoteHttp) ...['-rw_timeout', '15000000'],
      if (allowAllHlsExtensions) ...[
        '-f',
        'hls',
        '-allowed_segment_extensions',
        'ALL',
      ],
      '-ss',
      startSec,
      '-t',
      durSec,
      '-i',
      inputTarget,
      '-vn',
      '-sn',
      '-dn',
      '-ac',
      '1',
      '-ar',
      '16000',
      ...codecArgs,
      outputWavPath,
    ];
  }

  /// 원격 HTTPS/HTTP 스트림이면 Loopback Relay를 통해 로컬 HTTP 입력 주소를 준비합니다.
  static Future<({String inputTarget, String? relayUrl, bool isRemoteHttp})>
      prepareInputTarget({
    required String streamUrl,
    required Map<String, String> httpHeaders,
  }) async {
    final isLoopback = streamUrl.startsWith('http://127.0.0.1') ||
        streamUrl.startsWith('http://localhost');
    final isRemoteHttp =
        streamUrl.startsWith('https://') || streamUrl.startsWith('http://');

    if (isRemoteHttp && !isLoopback) {
      final relayUrl = await LocalHttpAudioRelay.instance.register(
        url: streamUrl,
        headers: httpHeaders,
      );
      return (inputTarget: relayUrl, relayUrl: relayUrl, isRemoteHttp: true);
    }
    return (
      inputTarget: streamUrl,
      relayUrl: null,
      isRemoteHttp: isRemoteHttp,
    );
  }
}
