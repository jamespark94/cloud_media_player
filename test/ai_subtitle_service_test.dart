import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cloud_media_player/models/ai_subtitle/ai_subtitle_config.dart';
import 'package:cloud_media_player/models/ai_subtitle/subtitle_segment.dart';
import 'package:cloud_media_player/services/ai_subtitle/ai_subtitle_key_storage.dart';
import 'package:cloud_media_player/services/ai_subtitle/ai_subtitle_service.dart';
import 'package:cloud_media_player/services/ai_subtitle/engines/cloud_ai_subtitle_engine.dart';
import 'package:cloud_media_player/services/ai_subtitle/engines/on_device_subtitle_engine.dart';
import 'package:cloud_media_player/services/ai_subtitle/extractors/audio_chunk_extractor.dart';
import 'package:cloud_media_player/services/ai_subtitle/extractors/ffmpeg_kit_chunk_runner.dart';
import 'package:cloud_media_player/services/ai_subtitle/stt/whisper_isolate_worker.dart';
import 'package:cloud_media_player/services/ai_subtitle/subtitle_generator_engine.dart';
import 'package:cloud_media_player/services/ai_subtitle/subtitle_segment_cache.dart';
import 'package:cloud_media_player/services/ai_subtitle/translators/subtitle_translator.dart';

class _FakeSubtitleEngine implements SubtitleGeneratorEngine {
  bool supported = true;
  bool shouldFail = false;
  int initCount = 0;
  int disposeCount = 0;
  int cancelCount = 0;
  final List<Duration> requestedStarts = [];
  final Map<int, List<SubtitleSegment>> cannedSegments;

  _FakeSubtitleEngine({this.cannedSegments = const {}});

  @override
  String get engineId => 'fake_engine';

  @override
  String get displayName => 'Fake Engine';

  @override
  String get acceleratorLabel => 'Test CPU';

  @override
  Future<bool> isSupported() async => supported;

  @override
  Future<void> initialize({
    void Function(double progress, String status)? onProgress,
  }) async {
    initCount++;
    onProgress?.call(1.0, 'Ready');
  }

  @override
  Stream<SubtitleSegment> generateSubtitlesForChunk(
    AudioChunkRequest request,
  ) async* {
    requestedStarts.add(request.chunkStart);
    if (shouldFail) {
      throw Exception('Simulated STT error');
    }
    final list = cannedSegments[request.chunkStart.inSeconds] ?? const [];
    for (final seg in list) {
      yield seg;
    }
  }

  @override
  Future<void> cancelCurrentJob() async {
    cancelCount++;
  }

  @override
  Future<void> dispose() async {
    disposeCount++;
  }
}

class _FakeOnDeviceEngine extends OnDeviceSubtitleEngine {
  final bool supportedValue;
  _FakeOnDeviceEngine({this.supportedValue = true})
      : super(
          extractor: _FakeAudioExtractor(),
          whisperWorker: WhisperIsolateWorker(),
          translator: SubtitleTranslator.create(),
        );

  @override
  Future<bool> isSupported() async => supportedValue;

  @override
  Future<void> initialize({
    void Function(double progress, String status)? onProgress,
    String sourceLanguage = 'auto',
    String targetLanguage = 'ko',
  }) async {
    onProgress?.call(1.0, 'OnDevice Ready');
  }

  @override
  Stream<SubtitleSegment> generateSubtitlesForChunk(
    AudioChunkRequest request,
  ) async* {}
}

class _FakeAudioExtractor implements AudioChunkExtractor {
  final Set<AudioChunkFormat> failingFormats;
  final List<AudioChunkFormat> attemptedFormats = [];

  _FakeAudioExtractor({this.failingFormats = const {}});

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<File> extractChunk({
    required String streamUrl,
    required Map<String, String> httpHeaders,
    required Duration start,
    required Duration duration,
    required String outputWavPath,
    AudioChunkFormat format = AudioChunkFormat.wav16k,
  }) async {
    attemptedFormats.add(format);
    if (failingFormats.contains(format)) {
      throw AudioExtractionException('Codec ${format.name} unsupported');
    }
    final file = File(outputWavPath);
    await file.writeAsBytes(List<int>.filled(64, 1));
    return file;
  }

  @override
  Future<void> cancel() async {}

  @override
  Future<void> dispose() async {}
}

class _MockHttpAdapter implements HttpClientAdapter {
  final Future<ResponseBody> Function(RequestOptions options) handler;

  _MockHttpAdapter(this.handler);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) =>
      handler(options);

  @override
  void close({bool force = false}) {}
}

void main() {
  group('SubtitleSegment & Format Tests', () {
    test('contains() and formatForDisplay() handle 3 display modes', () {
      const segDual = SubtitleSegment(
        startTime: Duration(seconds: 5),
        endTime: Duration(seconds: 10),
        originalText: 'Hello world',
        translatedText: '안녕하세요',
      );
      expect(segDual.contains(const Duration(seconds: 5)), isTrue);
      expect(segDual.contains(const Duration(seconds: 7)), isTrue);
      expect(segDual.contains(const Duration(seconds: 11)), isFalse);
      expect(segDual.formatForDisplay(showDual: true), 'Hello world\n안녕하세요');
      expect(segDual.formatForDisplay(showDual: false), '안녕하세요');
      expect(
        segDual.formatForDisplay(displayMode: AiSubtitleDisplayMode.dual),
        'Hello world\n안녕하세요',
      );
      expect(
        segDual.formatForDisplay(displayMode: AiSubtitleDisplayMode.koreanOnly),
        '안녕하세요',
      );
      expect(
        segDual.formatForDisplay(displayMode: AiSubtitleDisplayMode.originalOnly),
        'Hello world',
      );

      const segOriginalOnly = SubtitleSegment(
        startTime: Duration(seconds: 12),
        endTime: Duration(seconds: 15),
        originalText: 'Original only',
      );
      expect(segOriginalOnly.formatForDisplay(showDual: true), 'Original only');
      expect(segOriginalOnly.formatForDisplay(showDual: false), 'Original only');
    });

    test('JSON round-trip preserves segment data', () {
      const seg = SubtitleSegment(
        startTime: Duration(milliseconds: 1250),
        endTime: Duration(milliseconds: 3450),
        originalText: 'Test line',
        translatedText: '테스트 줄',
        languageCode: 'en',
      );
      final restored = SubtitleSegment.fromJson(seg.toJson());
      expect(restored, seg);
    });
  });

  group('SubtitleSegmentCache & SRT Export Tests', () {
    test('Bucket indexing, chunk key tracking, and SRT export work properly', () {
      final cache = SubtitleSegmentCache(chunkSeconds: 45);
      expect(cache.bucketIndexFor(const Duration(seconds: 0)), 0);
      expect(cache.bucketIndexFor(const Duration(seconds: 44)), 0);
      expect(cache.bucketIndexFor(const Duration(seconds: 45)), 1);

      const seg0 = SubtitleSegment(
        startTime: Duration(seconds: 3, milliseconds: 250),
        endTime: Duration(seconds: 8, milliseconds: 500),
        originalText: 'First line',
        translatedText: '첫 번째 대사',
      );
      const seg1 = SubtitleSegment(
        startTime: Duration(seconds: 46),
        endTime: Duration(seconds: 50),
        originalText: 'Second line',
        translatedText: '두 번째 대사',
      );

      expect(cache.isChunkProcessedOrActive(0), isFalse);
      cache.insertSegment(0, seg0);
      cache.markCompleted(0);
      expect(cache.isChunkProcessedOrActive(0), isTrue);

      cache.insertSegment(1, seg1);
      cache.markCompleted(1);

      // Seek back to bucket 0 -> instant hit
      expect(cache.findAt(const Duration(seconds: 5)), seg0);
      expect(cache.findAt(const Duration(seconds: 48)), seg1);

      final srtDual = cache.exportAsSrt(displayMode: AiSubtitleDisplayMode.dual);
      expect(srtDual, contains('1\n00:00:03,250 --> 00:00:08,500\nFirst line\n첫 번째 대사'));
      expect(srtDual, contains('2\n00:00:46,000 --> 00:00:50,000\nSecond line\n두 번째 대사'));

      final srtKo = cache.exportAsSrt(displayMode: AiSubtitleDisplayMode.koreanOnly);
      expect(srtKo, isNot(contains('First line')));
      expect(srtKo, contains('첫 번째 대사'));
    });
  });

  group('CloudAiSubtitleEngine Tests', () {
    test('parseGeminiResponse maps relative timestamps to absolute SubtitleSegments', () {
      final responseData = {
        'candidates': [
          {
            'content': {
              'parts': [
                {
                  'text': jsonEncode({
                    'detectedLanguage': 'en',
                    'segments': [
                      {
                        'startSec': 1.5,
                        'endSec': 4.2,
                        'originalText': 'Are you ready?',
                        'koreanTranslation': '준비됐나요?',
                      },
                      {
                        'startSec': 12.0,
                        'endSec': 60.0, // Exceeds 45s chunk -> clamped
                        'originalText': 'Let us go!',
                        'koreanTranslation': '출발합시다!',
                      },
                    ],
                  }),
                }
              ],
            },
          }
        ],
      };

      final segments = CloudAiSubtitleEngine.parseGeminiResponse(
        responseData: responseData,
        chunkStart: const Duration(seconds: 45),
        chunkDuration: const Duration(seconds: 45),
        sourceLanguageHint: 'en',
      );

      expect(segments.length, 2);
      expect(segments[0].startTime, const Duration(seconds: 46, milliseconds: 500));
      expect(segments[0].endTime, const Duration(seconds: 49, milliseconds: 200));
      expect(segments[0].originalText, 'Are you ready?');
      expect(segments[0].translatedText, '준비됐나요?');
      expect(segments[0].languageCode, 'en');

      expect(segments[1].startTime, const Duration(seconds: 57));
      expect(segments[1].endTime, const Duration(seconds: 90));
    });

    test('CloudAiSubtitleEngine falls back MP3 -> AAC and emits segments', () async {
      final extractor = _FakeAudioExtractor(
        failingFormats: {AudioChunkFormat.mp3LowBitrate},
      );
      Map<String, dynamic>? capturedRequest;

      final dio = Dio();
      dio.httpClientAdapter = _MockHttpAdapter((options) async {
        capturedRequest = options.data as Map<String, dynamic>;
        expect(options.headers['x-goog-api-key'], 'test-api-key-1234');
        final body = jsonEncode({
          'candidates': [
            {
              'content': {
                'parts': [
                  {
                    'text': jsonEncode({
                      'detectedLanguage': 'ja',
                      'segments': [
                        {
                          'startSec': 0.5,
                          'endSec': 3.0,
                          'originalText': 'おはようございます',
                          'koreanTranslation': '좋은 아침입니다',
                        }
                      ],
                    }),
                  }
                ],
              },
            }
          ],
        });
        return ResponseBody.fromString(
          body,
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      });

      final engine = CloudAiSubtitleEngine(
        apiKey: 'test-api-key-1234',
        extractor: extractor,
        dio: dio,
      );

      await engine.initialize();
      final segments = await engine
          .generateSubtitlesForChunk(
            const AudioChunkRequest(
              mediaItemId: 'vid_1',
              streamUrl: 'https://example.com/movie.mp4',
              httpHeaders: {},
              chunkStart: Duration.zero,
              chunkDuration: Duration(seconds: 45),
              sourceLanguage: 'ja',
            ),
          )
          .toList();

      expect(extractor.attemptedFormats, [
        AudioChunkFormat.mp3LowBitrate,
        AudioChunkFormat.aacLowBitrate,
      ]);
      expect(capturedRequest, isNotNull);
      final parts =
          ((capturedRequest!['contents'] as List).first as Map)['parts'] as List;
      expect((parts.first as Map)['inlineData']['mimeType'], 'audio/aac');
      expect(segments.length, 1);
      expect(segments.first.translatedText, '좋은 아침입니다');
    });

    test('CloudAiSubtitleEngine falls back automatically on HTTP 404 model error', () async {
      final extractor = _FakeAudioExtractor();
      final requestedPaths = <String>[];
      final dio = Dio();
      dio.httpClientAdapter = _MockHttpAdapter((options) async {
        requestedPaths.add(options.path);
        if (options.path.contains('gemini-deprecated-model')) {
          return ResponseBody.fromString(
            jsonEncode({
              'error': {'message': 'models/gemini-deprecated-model is not found'}
            }),
            404,
            headers: {
              Headers.contentTypeHeader: [Headers.jsonContentType],
            },
          );
        }
        return ResponseBody.fromString(
          jsonEncode({
            'candidates': [
              {
                'content': {
                  'parts': [
                    {
                      'text': jsonEncode({
                        'detectedLanguage': 'en',
                        'segments': [
                          {
                            'startSec': 1.0,
                            'endSec': 3.5,
                            'originalText': 'Hello!',
                            'koreanTranslation': '안녕하세요!',
                          }
                        ],
                      }),
                    }
                  ],
                },
              }
            ],
          }),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      });

      final engine = CloudAiSubtitleEngine(
        apiKey: 'test-key',
        modelName: 'gemini-deprecated-model',
        extractor: extractor,
        dio: dio,
      );

      final segments = await engine
          .generateSubtitlesForChunk(
            const AudioChunkRequest(
              mediaItemId: 'vid_404',
              streamUrl: 'https://example.com/movie.mp4',
              httpHeaders: {},
              chunkStart: Duration.zero,
              chunkDuration: Duration(seconds: 45),
            ),
          )
          .toList();

      expect(requestedPaths.length, 2);
      expect(requestedPaths.first, contains('gemini-deprecated-model'));
      expect(requestedPaths.last, contains('gemini-3.8-flash'));
      expect(segments.single.translatedText, '안녕하세요!');
    });

    test('CloudAiSubtitleEngine classifies 429 QuotaExceeded cleanly', () async {
      final extractor = _FakeAudioExtractor();
      final dio = Dio();
      dio.httpClientAdapter = _MockHttpAdapter((options) async {
        return ResponseBody.fromString(
          jsonEncode({'error': {'status': 'RESOURCE_EXHAUSTED'}}),
          429,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      });

      final engine = CloudAiSubtitleEngine(
        apiKey: 'test-key',
        extractor: extractor,
        dio: dio,
      );

      expect(
        () => engine
            .generateSubtitlesForChunk(
              const AudioChunkRequest(
                mediaItemId: 'vid_1',
                streamUrl: 'https://example.com/movie.mp4',
                httpHeaders: {},
                chunkStart: Duration.zero,
                chunkDuration: Duration(seconds: 45),
              ),
            )
            .toList(),
        throwsA(
          isA<CloudAiException>().having(
            (e) => e.type,
            'type',
            CloudAiErrorType.quotaExceeded,
          ),
        ),
      );
    });
  });

  group('Platform Translator Isolation Tests', () {
    test('Windows platform factory returns non-MLKit original-only fallback', () async {
      final translator = SubtitleTranslator.create();
      expect(translator.isTranslationSupported, isFalse);
      await translator.initialize(sourceLang: 'en');
      expect(await translator.translate('Hello'), isNull);
      await translator.dispose();
    });
  });

  group('AiSubtitleService Fail-Safe & Cost Defense Tests', () {
    test('Default OFF state never initializes engine or loads model', () async {
      final fakeEngine = _FakeSubtitleEngine();
      final service = AiSubtitleService.forTesting(
        engine: fakeEngine,
        translationSupportedOverride: false,
      );

      expect(service.isEnabled, isFalse);
      service.processPositionUpdate(const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(fakeEngine.initCount, 0);
      expect(fakeEngine.requestedStarts, isEmpty);
    });

    test('Pause state blocks scheduling and rapid seeks are debounced', () async {
      final fakeEngine = _FakeSubtitleEngine(
        cannedSegments: {
          0: const [
            SubtitleSegment(
              startTime: Duration(seconds: 1),
              endTime: Duration(seconds: 4),
              originalText: 'Start line',
            ),
          ],
          60: const [
            SubtitleSegment(
              startTime: Duration(seconds: 62),
              endTime: Duration(seconds: 65),
              originalText: 'Seeked line',
            ),
          ],
        },
      );
      final service = AiSubtitleService.forTesting(
        engine: fakeEngine,
        seekDebounceDuration: const Duration(milliseconds: 120),
        translationSupportedOverride: false,
      );
      service.setStreamContextForTesting(
        mediaItemId: 'vid_debounce',
        streamUrl: 'https://example.com/video.mp4',
      );

      await service.setEnabled(true);

      // 1. Pause 상태에서는 세그먼트 요청 미발생
      service.processPositionUpdate(
        const Duration(seconds: 2),
        isPlaying: false,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(fakeEngine.requestedStarts, isEmpty);

      // 2. 재생 시작 -> 버킷 0 (chunkStart=0) 처리
      service.processPositionUpdate(
        const Duration(seconds: 2),
        isPlaying: true,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(fakeEngine.requestedStarts, contains(Duration.zero));
      final countAfterInitial = fakeEngine.requestedStarts.length;

      // 3. 연속 Seek (30s -> 120s -> 60s) -> 디바운싱으로 최종 위치(60s)만 1회 호출
      service.processPositionUpdate(const Duration(seconds: 30), isPlaying: true);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      service.processPositionUpdate(const Duration(seconds: 120), isPlaying: true);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      service.processPositionUpdate(const Duration(seconds: 60), isPlaying: true);

      // 디바운스 완료 전에는 추가 호출 없음
      expect(fakeEngine.requestedStarts.length, countAfterInitial);

      // 디바운스(120ms) 경과 후 최종 위치 버킷만 처리됨
      await Future<void>.delayed(const Duration(milliseconds: 220));
      expect(fakeEngine.requestedStarts, contains(const Duration(seconds: 60)));
      expect(fakeEngine.requestedStarts, isNot(contains(const Duration(seconds: 120))));

      // 4. 이미 처리된 버킷 0으로 다시 Seek -> Chunk Key 중복 체크로 재요청 없음
      final beforeBackSeek = fakeEngine.requestedStarts.length;
      service.processPositionUpdate(const Duration(seconds: 3), isPlaying: true);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(fakeEngine.requestedStarts.length, beforeBackSeek);
      expect(service.currentSegment?.originalText, 'Start line');
    });

    test('Missing API key stops cloud AI safely without interrupting playback', () async {
      final service = AiSubtitleService.forTesting(
        keyStorage: AiSubtitleKeyStorage.inMemory(initialKey: null),
      );
      service.setStreamContextForTesting(
        mediaItemId: 'vid_nokey',
        streamUrl: 'https://example.com/video.mp4',
      );

      String? notice;
      service.onNotification = (msg, {bool isWarning = false}) {
        notice = msg;
      };

      await service.updateConfig(
        const AiSubtitleConfig(engineType: AiSubtitleEngineType.cloudApi),
      );
      await service.setEnabled(true);
      service.processPositionUpdate(const Duration(seconds: 1), isPlaying: true);
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(service.isEnabled, isFalse);
      expect(notice, contains('Gemini API 키'));
    });

    test('QuotaExceeded falls back to OnDeviceSubtitleEngine automatically', () async {
      final keyStorage = AiSubtitleKeyStorage.inMemory(initialKey: 'valid-key');
      final dio = Dio();
      dio.httpClientAdapter = _MockHttpAdapter((options) async {
        return ResponseBody.fromString(
          '{"error":{"status":"RESOURCE_EXHAUSTED"}}',
          429,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      });

      final service = AiSubtitleService.forTesting(
        keyStorage: keyStorage,
        cloudEngineFactory: (key, model) => CloudAiSubtitleEngine(
          apiKey: key,
          modelName: model,
          extractor: _FakeAudioExtractor(),
          dio: dio,
        ),
        onDeviceEngineFactory: (tier) => _FakeOnDeviceEngine(supportedValue: true),
      );
      service.setStreamContextForTesting(
        mediaItemId: 'vid_quota',
        streamUrl: 'https://example.com/video.mp4',
      );

      final notices = <String>[];
      AiSubtitleConfig? fallbackCfg;
      service.onNotification = (msg, {bool isWarning = false}) {
        notices.add(msg);
      };
      service.onConfigFallback = (cfg) {
        fallbackCfg = cfg;
      };

      await service.updateConfig(
        const AiSubtitleConfig(engineType: AiSubtitleEngineType.cloudApi),
      );
      await service.setEnabled(true);
      service.processPositionUpdate(const Duration(seconds: 1), isPlaying: true);
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(service.config.engineType, AiSubtitleEngineType.onDevice);
      expect(fallbackCfg?.engineType, AiSubtitleEngineType.onDevice);
      expect(notices.any((n) => n.contains('할당량')), isTrue);
      expect(service.isEnabled, isTrue);
    });

    test('Enabling and disabling properly disposes engine and clears active segment', () async {
      final fakeEngine = _FakeSubtitleEngine();
      final service = AiSubtitleService.forTesting(
        engine: fakeEngine,
        translationSupportedOverride: false,
      );

      await service.setEnabled(true);
      expect(service.isEnabled, isTrue);

      await service.setEnabled(false);
      expect(service.isEnabled, isFalse);
      expect(service.currentSegment, isNull);
      expect(fakeEngine.disposeCount, 1);
    });

    test('unbindStreamContext resets isEnabled so next video keeps original subtitles', () async {
      final fakeEngine = _FakeSubtitleEngine();
      final service = AiSubtitleService.forTesting(
        engine: fakeEngine,
        translationSupportedOverride: false,
      );

      await service.setEnabled(true);
      expect(service.isEnabled, isTrue);

      await service.unbindStreamContext();
      expect(service.isEnabled, isFalse);
      expect(service.currentSegment, isNull);
    });
  });

  group('FFmpeg HLS Proxy Extraction Args Tests', () {
    test('buildExtractArgs includes HLS extension bypass when requested', () {
      final args = FfmpegKitChunkRunner.buildExtractArgs(
        inputTarget: 'http://127.0.0.1:1218/stream?session=abc',
        isRemoteHttp: false,
        start: const Duration(seconds: 30),
        duration: const Duration(seconds: 45),
        outputWavPath: 'out.aac',
        format: AudioChunkFormat.aacLowBitrate,
        allowAllHlsExtensions: true,
      );

      expect(args, containsAllInOrder(['-f', 'hls', '-allowed_segment_extensions', 'ALL']));
      expect(args, containsAllInOrder(['-c:a', 'aac', '-b:a', '32k', '-f', 'adts']));
      expect(
        FfmpegKitChunkRunner.isHlsExtensionRestrictionLog(
          'URL http://127.0.0.1:1218/hls_segment is not in allowed_segment_extensions',
        ),
        isTrue,
      );
    });
  });
}
