import 'dart:async';
import 'dart:io';
import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_session.dart';
import 'package:ffmpeg_kit_flutter_new_min/return_code.dart';
import 'package:flutter/foundation.dart';
import 'audio_chunk_extractor.dart';
import 'local_http_audio_relay.dart';

/// FFmpegKit 기반 공통 오디오 청크 추출 헬퍼.
/// MobileFfmpegExtractor와 DesktopFfmpegExtractor가 공통으로 사용합니다.
class FfmpegKitChunkRunner {
  static Future<void> _serialLock = Future<void>.value();
  static final Set<String> _hlsAllowAllStreamUrls = <String>{};

  int? _activeSessionId;
  Completer<ReturnCode?>? _activeCompleter;
  bool _isCancelled = false;

  bool get isCancelled => _isCancelled;

  void resetCancel() {
    _isCancelled = false;
  }

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

  /// 원격 HTTPS/HTTP 스트림이면 Loopback Relay를 통해 FFmpeg 입력 주소를 준비합니다.
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

  Future<File> runFfmpegKit({
    required List<String> args,
    required String outputWavPath,
    required String logTag,
  }) async {
    // libffmpegkit 동시 실행/취소 경합으로 인한 네이티브 크래시 방지를 위해 전역 직렬화
    final prev = _serialLock;
    final gate = Completer<void>();
    _serialLock = gate.future;
    try {
      await prev.catchError((_) {});
    } catch (_) {}

    try {
      if (_isCancelled) {
        throw const AudioExtractionException(
          '오디오 청크 추출 취소됨',
          isCancelled: true,
        );
      }

      final completer = Completer<ReturnCode?>();
      _activeCompleter = completer;

      final FFmpegSession session = await FFmpegKit.executeWithArgumentsAsync(
        args,
        (completedSession) async {
          final rc = await completedSession.getReturnCode();
          if (!completer.isCompleted) {
            completer.complete(rc);
          }
        },
      );
      _activeSessionId = session.getSessionId();

      final rc = await completer.future.timeout(
        const Duration(seconds: 40),
        onTimeout: () {
          final sid = _activeSessionId;
          if (sid != null) FFmpegKit.cancel(sid);
          return null;
        },
      );

      if (ReturnCode.isCancel(rc) || _isCancelled) {
        throw const AudioExtractionException(
          '오디오 청크 추출 취소됨',
          isCancelled: true,
        );
      }
      if (!ReturnCode.isSuccess(rc)) {
        final logs = (await session.getAllLogsAsString(500)) ?? '';
        debugPrint('[$logTag] FFmpegKit 실패 rc=${rc?.getValue()}: $logs');
        throw AudioExtractionException(
          'FFmpegKit 추출 실패 (code=${rc?.getValue()}): $logs',
        );
      }

      final outFile = File(outputWavPath);
      if (!outFile.existsSync() || outFile.lengthSync() <= 44) {
        throw const AudioExtractionException('추출된 오디오 파일이 비어 있습니다.');
      }
      return outFile;
    } finally {
      _activeSessionId = null;
      _activeCompleter = null;
      if (!gate.isCompleted) gate.complete();
    }
  }

  Future<void> cancel() async {
    _isCancelled = true;
    final sid = _activeSessionId;
    final comp = _activeCompleter;
    if (sid != null) {
      try {
        await FFmpegKit.cancel(sid);
      } catch (_) {}
    }
    if (comp != null && !comp.isCompleted) {
      try {
        await comp.future.timeout(const Duration(milliseconds: 1500));
      } catch (_) {}
    }
  }
}
