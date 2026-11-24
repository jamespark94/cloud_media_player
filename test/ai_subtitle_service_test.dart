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
import 'package:cloud_media_player/services/ai_subtitle/engines/free_hybrid_subtitle_engine.dart';
import 'package:cloud_media_player/services/ai_subtitle/engines/on_device_subtitle_engine.dart';
import 'package:cloud_media_player/services/ai_subtitle/extractors/audio_chunk_extractor.dart';
import 'package:cloud_media_player/services/ai_subtitle/extractors/desktop_ffmpeg_extractor.dart';
import 'package:cloud_media_player/services/ai_subtitle/extractors/ffmpeg_kit_chunk_runner.dart';
import 'package:cloud_media_player/services/ai_subtitle/stt/whisper_chunk_runner.dart';
import 'package:cloud_media_player/services/ai_subtitle/stt/whisper_isolate_worker.dart';
import 'package:cloud_media_player/services/ai_subtitle/subtitle_generator_engine.dart';
import 'package:cloud_media_player/services/ai_subtitle/subtitle_segment_cache.dart';
import 'package:cloud_media_player/services/ai_subtitle/translators/google_web_batch_translator.dart';
import 'package:cloud_media_player/services/ai_subtitle/translators/mlkit_subtitle_translator.dart';
import 'package:cloud_media_player/services/ai_subtitle/translators/subtitle_translator.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';

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

class _FakeModelManager extends OnDeviceTranslatorModelManager {
  final Set<String> downloadedModels;
  final Set<String> failingDownloads;
  final List<String> downloadAttempts = [];

  _FakeModelManager({
    Set<String>? downloadedModels,
    Set<String>? failingDownloads,
  })  : downloadedModels = downloadedModels ?? <String>{},
        failingDownloads = failingDownloads ?? <String>{};

  @override
  Future<bool> isModelDownloaded(String model) async {
    return downloadedModels.contains(model);
  }

  @override
  Future<bool> downloadModel(String model, {bool isWifiRequired = true}) async {
    downloadAttempts.add(model);
    if (failingDownloads.contains(model)) {
      return false;
    }
    downloadedModels.add(model);
    return true;
  }
}

class _FakeOnDeviceTranslator extends OnDeviceTranslator {
  final List<(TranslateLanguage, TranslateLanguage, String)> calls;
  final String Function(
    TranslateLanguage source,
    TranslateLanguage target,
    String text,
  ) onTranslate;

  _FakeOnDeviceTranslator({
    required super.sourceLanguage,
    required super.targetLanguage,
    required this.calls,
    required this.onTranslate,
  });

  @override
  Future<String> translateText(String text) async {
    calls.add((sourceLanguage, targetLanguage, text));
    return onTranslate(sourceLanguage, targetLanguage, text);
  }

  @override
  Future<void> close() async {}
}

class _FakeWhisperWorker extends WhisperIsolateWorker {
  final List<SubtitleSegment> cannedSegments;
  _FakeWhisperWorker(this.cannedSegments);

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<void> initialize({
    required AiWhisperModelTier tier,
    void Function(double progress, String status)? onProgress,
  }) async {}

  @override
  Future<List<SubtitleSegment>> transcribeChunk({
    required String wavPath,
    required Duration chunkOffset,
    required Duration chunkDuration,
    required String sourceLanguage,
  }) async {
    return cannedSegments;
  }

  @override
  Future<void> release() async {}
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

    test('MlKitSubtitleTranslator auto mode translates Japanese to Korean instead of forcing en->ko', () async {
      final modelManager = _FakeModelManager(downloadedModels: {'ko'});
      final calls = <(TranslateLanguage, TranslateLanguage, String)>[];

      final translator = MlKitSubtitleTranslator(
        modelManager: modelManager,
        translatorFactory: (src, tgt) => _FakeOnDeviceTranslator(
          sourceLanguage: src,
          targetLanguage: tgt,
          calls: calls,
          onTranslate: (s, t, text) {
            if (s == TranslateLanguage.japanese && t == TranslateLanguage.korean) {
              return '좋은 아침입니다';
            }
            return text;
          },
        ),
      );

      await translator.initialize(sourceLang: 'auto', targetLang: 'ko');
      final result = await translator.translate(
        'おはようございます',
        detectedSourceLang: 'auto',
      );

      expect(result, '좋은 아침입니다');
      expect(calls, [(TranslateLanguage.japanese, TranslateLanguage.korean, 'おはようございます')]);
      expect(modelManager.downloadedModels, contains('ja'));
      expect(modelManager.downloadedModels, isNot(contains('en')));
      await translator.dispose();
    });

    test('MlKitSubtitleTranslator retries model download after failure instead of caching broken state', () async {
      final modelManager = _FakeModelManager(
        downloadedModels: {'ko'},
        failingDownloads: {'ja'},
      );
      final calls = <(TranslateLanguage, TranslateLanguage, String)>[];

      final translator = MlKitSubtitleTranslator(
        modelManager: modelManager,
        translatorFactory: (src, tgt) => _FakeOnDeviceTranslator(
          sourceLanguage: src,
          targetLanguage: tgt,
          calls: calls,
          onTranslate: (s, t, text) => '안녕하세요',
        ),
      );

      await translator.initialize(sourceLang: 'ja', targetLang: 'ko');
      expect(await translator.translate('こんにちは', detectedSourceLang: 'ja'), isNull);
      expect(translator.lastErrorMessage, isNotNull);

      // 네트워크 복구 후 재시도 시 정상 다운로드 및 번역 성공
      modelManager.failingDownloads.remove('ja');
      final retried = await translator.translate('こんにちは', detectedSourceLang: 'ja');
      expect(retried, '안녕하세요');
      expect(translator.lastErrorMessage, isNull);
      await translator.dispose();
    });

    test('OnDeviceSubtitleEngine propagates Japanese chunk context to Kanji-only segments in auto mode', () async {
      final modelManager = _FakeModelManager(downloadedModels: {'ko', 'ja'});
      final calls = <(TranslateLanguage, TranslateLanguage, String)>[];

      final translator = MlKitSubtitleTranslator(
        modelManager: modelManager,
        translatorFactory: (src, tgt) => _FakeOnDeviceTranslator(
          sourceLanguage: src,
          targetLanguage: tgt,
          calls: calls,
          onTranslate: (s, t, text) {
            if (s == TranslateLanguage.japanese) {
              return text == '大丈夫' ? '괜찮아' : '안녕하세요';
            }
            return text;
          },
        ),
      );

      final engine = OnDeviceSubtitleEngine(
        extractor: _FakeAudioExtractor(),
        whisperWorker: _FakeWhisperWorker(const [
          SubtitleSegment(
            startTime: Duration(seconds: 1),
            endTime: Duration(seconds: 3),
            originalText: 'こんにちは',
          ),
          SubtitleSegment(
            startTime: Duration(seconds: 4),
            endTime: Duration(seconds: 6),
            originalText: '大丈夫',
          ),
        ]),
        translator: translator,
      );

      await engine.initialize(sourceLanguage: 'auto', targetLanguage: 'ko');
      final segments = await engine
          .generateSubtitlesForChunk(
            const AudioChunkRequest(
              mediaItemId: 'vid_ja',
              streamUrl: 'https://example.com/ja.mp4',
              httpHeaders: {},
              chunkStart: Duration.zero,
              chunkDuration: Duration(seconds: 20),
              sourceLanguage: 'auto',
              targetLanguage: 'ko',
            ),
          )
          .toList();

      expect(segments.length, 2);
      expect(segments[0].translatedText, '안녕하세요');
      expect(segments[1].translatedText, '괜찮아');
      expect(
        calls.every((c) => c.$1 == TranslateLanguage.japanese && c.$2 == TranslateLanguage.korean),
        isTrue,
      );
      await engine.dispose();
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

  group('FreeHybridSubtitleEngine & GoogleWebBatchTranslator Tests', () {
    test('GoogleWebBatchTranslator sends 1 GET request per chunk with delimiter and maps segments', () async {
      var httpCallCount = 0;
      String? capturedClient;
      String? capturedQuery;

      final dio = Dio();
      dio.httpClientAdapter = _MockHttpAdapter((options) async {
        httpCallCount++;
        capturedClient = options.queryParameters['client'] as String?;
        capturedQuery = options.queryParameters['q'] as String?;
        expect(options.path, GoogleWebBatchTranslator.endpointUrl);

        final body = jsonEncode([
          [
            ['안녕하세요.\n|||\n', 'Hello.\n|||\n', null, null, 1],
            ['오늘 날씨가 좋네요.', 'The weather is nice today.', null, null, 1],
          ],
          null,
          'en',
        ]);
        return ResponseBody.fromString(
          body,
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      });

      final translator = GoogleWebBatchTranslator(dio: dio);
      final engine = FreeHybridSubtitleEngine(
        modelTier: AiWhisperModelTier.small,
        extractor: _FakeAudioExtractor(),
        whisperWorker: _FakeWhisperWorker(const [
          SubtitleSegment(
            startTime: Duration(seconds: 1),
            endTime: Duration(seconds: 3),
            originalText: 'Hello.',
          ),
          SubtitleSegment(
            startTime: Duration(seconds: 4),
            endTime: Duration(seconds: 7),
            originalText: 'The weather is nice today.',
          ),
        ]),
        batchTranslator: translator,
      );

      await engine.initialize();
      final segments = await engine
          .generateSubtitlesForChunk(
            const AudioChunkRequest(
              mediaItemId: 'vid_hybrid_1',
              streamUrl: 'https://example.com/movie.mp4',
              httpHeaders: {},
              chunkStart: Duration.zero,
              chunkDuration: Duration(seconds: 45),
              sourceLanguage: 'auto',
              targetLanguage: 'ko',
            ),
          )
          .toList();

      expect(httpCallCount, 1);
      expect(capturedClient, 'gtx');
      expect(capturedQuery, 'Hello.\n|||\nThe weather is nice today.');
      expect(engine.lastTranslationError, isNull);
      expect(segments.length, 2);
      expect(segments[0].originalText, 'Hello.');
      expect(segments[0].translatedText, '안녕하세요.');
      expect(segments[0].languageCode, 'en');
      expect(segments[1].originalText, 'The weather is nice today.');
      expect(segments[1].translatedText, '오늘 날씨가 좋네요.');
      await engine.dispose();
    });

    test('FreeHybridSubtitleEngine falls back to original-only segments on offline translation failure', () async {
      final dio = Dio();
      dio.httpClientAdapter = _MockHttpAdapter((options) async {
        throw DioException.connectionError(
          requestOptions: options,
          reason: 'Offline',
        );
      });

      final engine = FreeHybridSubtitleEngine(
        modelTier: AiWhisperModelTier.largeV3TurboQ5,
        extractor: _FakeAudioExtractor(),
        whisperWorker: _FakeWhisperWorker(const [
          SubtitleSegment(
            startTime: Duration(seconds: 2),
            endTime: Duration(seconds: 5),
            originalText: 'Keep playing even offline.',
          ),
        ]),
        batchTranslator: GoogleWebBatchTranslator(dio: dio),
      );

      await engine.initialize();
      final segments = await engine
          .generateSubtitlesForChunk(
            const AudioChunkRequest(
              mediaItemId: 'vid_hybrid_offline',
              streamUrl: 'file:///local/movie.mp4',
              httpHeaders: {},
              chunkStart: Duration.zero,
              chunkDuration: Duration(seconds: 45),
            ),
          )
          .toList();

      expect(segments.length, 1);
      expect(segments.first.originalText, 'Keep playing even offline.');
      expect(segments.first.translatedText, isNull);
      expect(engine.lastTranslationError, isNotNull);
      await engine.dispose();
    });

    test('AiSubtitleService keeps playback alive on Windows and falls back to onDevice on mobile when free translation stays offline', () async {
      final dio = Dio();
      dio.httpClientAdapter = _MockHttpAdapter((options) async {
        throw DioException.connectionError(
          requestOptions: options,
          reason: 'Offline',
        );
      });

      // 1) Windows (ML Kit 미지원): freeHybrid 유지 + 원어 자막 표시 + 재생 중단 없음
      final winService = AiSubtitleService.forTesting(
        translationSupportedOverride: false,
        initialConfig: const AiSubtitleConfig(
          engineType: AiSubtitleEngineType.freeHybrid,
          modelTier: AiWhisperModelTier.base,
        ),
        freeHybridEngineFactory: (tier) => FreeHybridSubtitleEngine(
          modelTier: tier,
          extractor: _FakeAudioExtractor(),
          whisperWorker: _FakeWhisperWorker(const [
            SubtitleSegment(
              startTime: Duration(seconds: 1),
              endTime: Duration(seconds: 4),
              originalText: 'Offline original line',
            ),
          ]),
          batchTranslator: GoogleWebBatchTranslator(dio: dio),
        ),
      );
      winService.setStreamContextForTesting(
        mediaItemId: 'vid_win_offline',
        streamUrl: 'file:///local/movie.mp4',
      );
      final winNotices = <String>[];
      winService.onNotification = (msg, {bool isWarning = false}) {
        winNotices.add(msg);
      };

      await winService.setEnabled(true);
      winService.processPositionUpdate(const Duration(seconds: 2), isPlaying: true);
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(winService.isEnabled, isTrue);
      expect(winService.config.engineType, AiSubtitleEngineType.freeHybrid);
      expect(winService.currentSegment?.originalText, 'Offline original line');
      expect(winService.currentSegment?.translatedText, isNull);
      expect(winNotices.any((n) => n.contains('원어 자막만 표시')), isTrue);
      await winService.unbindStreamContext();

      // 2) Mobile (ML Kit 지원): 연속 오프라인 번역 실패 시 onDevice 모드로 자동 폴백
      final mobileService = AiSubtitleService.forTesting(
        translationSupportedOverride: true,
        initialConfig: const AiSubtitleConfig(
          engineType: AiSubtitleEngineType.freeHybrid,
          modelTier: AiWhisperModelTier.small,
        ),
        freeHybridEngineFactory: (tier) => FreeHybridSubtitleEngine(
          modelTier: tier,
          extractor: _FakeAudioExtractor(),
          whisperWorker: _FakeWhisperWorker(const [
            SubtitleSegment(
              startTime: Duration(seconds: 1),
              endTime: Duration(seconds: 4),
              originalText: 'Offline line',
            ),
          ]),
          batchTranslator: GoogleWebBatchTranslator(dio: dio),
        ),
        onDeviceEngineFactory: (tier) => _FakeOnDeviceEngine(supportedValue: true),
      );
      mobileService.setStreamContextForTesting(
        mediaItemId: 'vid_mobile_offline',
        streamUrl: 'file:///local/movie.mp4',
      );
      AiSubtitleConfig? fallbackCfg;
      mobileService.onConfigFallback = (cfg) {
        fallbackCfg = cfg;
      };

      await mobileService.setEnabled(true);
      mobileService.processPositionUpdate(const Duration(seconds: 2), isPlaying: true);
      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(mobileService.isEnabled, isTrue);
      expect(mobileService.config.engineType, AiSubtitleEngineType.onDevice);
      expect(mobileService.config.modelTier, AiWhisperModelTier.small);
      expect(fallbackCfg?.engineType, AiSubtitleEngineType.onDevice);
      await mobileService.unbindStreamContext();
    });

    test('AiSubtitleConfig and WhisperModelTier defaults reflect online free recommended mode', () {
      const cfg = AiSubtitleConfig();
      expect(cfg.engineType, AiSubtitleEngineType.freeHybrid);
      expect(cfg.modelTier, AiWhisperModelTier.small);
      expect(cfg.effectiveChunkSeconds, 45);
      expect(AiSubtitleConfig.initialShortChunkSeconds, inInclusiveRange(10, 15));
      expect(AiSubtitleConfig.streamingChunkSeconds, 30);
      expect(AiSubtitleConfig.staleSkipLeadSeconds, inInclusiveRange(10, 30));
      expect(AiWhisperModelTier.fromCode('small'), AiWhisperModelTier.small);
      expect(AiWhisperModelTier.fromCode('small-q5_1'), AiWhisperModelTier.smallQ5_1);
      expect(AiWhisperModelTier.smallQ5_1.modelFileName, 'ggml-small-q5_1.bin');
      expect(
        AiWhisperModelTier.fromCode('large-v3-turbo'),
        AiWhisperModelTier.largeV3TurboQ5,
      );
      expect(
        AiWhisperModelTier.largeV3TurboQ5.modelFileName,
        'ggml-large-v3-turbo-q5_0.bin',
      );
    });

    test('mergeSegmentsIntoSentences merges fragmented segments by punctuation and 1.5s silence gap', () {
      const raw = [
        SubtitleSegment(
          startTime: Duration(seconds: 0),
          endTime: Duration(seconds: 2),
          originalText: 'When I went',
        ),
        SubtitleSegment(
          startTime: Duration(seconds: 2, milliseconds: 200),
          endTime: Duration(seconds: 4),
          originalText: 'to the cafe,',
        ),
        SubtitleSegment(
          startTime: Duration(seconds: 4, milliseconds: 500),
          endTime: Duration(seconds: 7),
          originalText: 'I met an old friend.',
        ),
        // 1.5초 이상 침묵 간격으로 분리 (마침표가 없어도 분리)
        SubtitleSegment(
          startTime: Duration(seconds: 7, milliseconds: 500),
          endTime: Duration(seconds: 9),
          originalText: 'We talked',
        ),
        SubtitleSegment(
          startTime: Duration(seconds: 10, milliseconds: 500),
          endTime: Duration(seconds: 12),
          originalText: '本当に久しぶりですね！',
        ),
        // 일본어 물음표(？) 뒤 바로 이어지는 문장
        SubtitleSegment(
          startTime: Duration(seconds: 12, milliseconds: 300),
          endTime: Duration(seconds: 14),
          originalText: '元気ですか？',
        ),
        SubtitleSegment(
          startTime: Duration(seconds: 14, milliseconds: 100),
          endTime: Duration(seconds: 16),
          originalText: 'はい、元気です。',
        ),
      ];

      final merged = FreeHybridSubtitleEngine.mergeSegmentsIntoSentences(raw);

      expect(merged.length, 5);
      expect(merged[0].mergedText, 'When I went to the cafe, I met an old friend.');
      expect(merged[0].segmentIndices, [0, 1, 2]);
      expect(merged[0].startIndex, 0);
      expect(merged[0].endIndex, 2);

      expect(merged[1].mergedText, 'We talked');
      expect(merged[1].segmentIndices, [3]);

      expect(merged[2].mergedText, '本当に久しぶりですね！');
      expect(merged[2].segmentIndices, [4]);

      expect(merged[3].mergedText, '元気ですか？');
      expect(merged[3].segmentIndices, [5]);

      expect(merged[4].mergedText, 'はい、元気です。');
      expect(merged[4].segmentIndices, [6]);
    });

    test('distributeTranslatedSentence splits Korean translation proportionally at natural word boundaries', () {
      const segments = [
        SubtitleSegment(
          startTime: Duration(seconds: 0),
          endTime: Duration(seconds: 2),
          originalText: 'When I went', // 11 chars
        ),
        SubtitleSegment(
          startTime: Duration(seconds: 2),
          endTime: Duration(seconds: 4),
          originalText: 'to the cafe,', // 12 chars
        ),
        SubtitleSegment(
          startTime: Duration(seconds: 4),
          endTime: Duration(seconds: 7),
          originalText: 'I met an old friend.', // 20 chars
        ),
      ];

      const translated = '내가 어제 카페에 갔을 때, 거기서 오랜 친구를 만났어.';
      final parts = FreeHybridSubtitleEngine.distributeTranslatedSentence(
        translatedText: translated,
        segments: segments,
      );

      expect(parts.length, 3);
      expect(parts.every((p) => p != null && p.isNotEmpty), isTrue);
      // 어절이 중간에 잘리지 않고 재결합 시 원 번역문과 동일
      expect(parts.join(' '), translated);
      // 쉼표 경계 자연 분할 및 세 번째 세그먼트가 가장 긴 원문에 맞게 가장 긴 번역 할당
      expect(parts[2]!.length, greaterThan(parts[0]!.length));

      // 단어 수보다 세그먼트 수가 많은 짧은 구문도 깨짐 없이 분할
      const shortSegments = [
        SubtitleSegment(
          startTime: Duration(seconds: 0),
          endTime: Duration(seconds: 1),
          originalText: 'Thank',
        ),
        SubtitleSegment(
          startTime: Duration(seconds: 1),
          endTime: Duration(seconds: 2),
          originalText: 'you',
        ),
      ];
      final shortParts = FreeHybridSubtitleEngine.distributeTranslatedSentence(
        translatedText: '감사합니다',
        segments: shortSegments,
      );
      expect(shortParts.length, 2);
      expect(shortParts.join(''), '감사합니다');
    });

    test('FreeHybridSubtitleEngine merges fragments before 1 batch request and redistributes translations to timestamps', () async {
      var httpCallCount = 0;
      String? capturedQuery;

      final dio = Dio();
      dio.httpClientAdapter = _MockHttpAdapter((options) async {
        httpCallCount++;
        capturedQuery = options.queryParameters['q'] as String?;

        final body = jsonEncode([
          [
            [
              '내가 카페에 갔을 때, 오랜 친구를 만났어.\n|||\n',
              'When I went to the cafe, I met an old friend.\n|||\n',
              null,
              null,
              1,
            ],
            [
              '정말 기뻤어.',
              'I was really happy.',
              null,
              null,
              1,
            ],
          ],
          null,
          'en',
        ]);
        return ResponseBody.fromString(
          body,
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      });

      const rawWhisperSegments = [
        SubtitleSegment(
          startTime: Duration(seconds: 1),
          endTime: Duration(seconds: 3),
          originalText: 'When I went',
        ),
        SubtitleSegment(
          startTime: Duration(seconds: 3, milliseconds: 100),
          endTime: Duration(seconds: 5),
          originalText: 'to the cafe,',
        ),
        SubtitleSegment(
          startTime: Duration(seconds: 5, milliseconds: 200),
          endTime: Duration(seconds: 8),
          originalText: 'I met an old friend.',
        ),
        SubtitleSegment(
          startTime: Duration(seconds: 10), // 2.0초 간격 + 직전 문장 끝 부호
          endTime: Duration(seconds: 12),
          originalText: 'I was really happy.',
        ),
      ];

      final engine = FreeHybridSubtitleEngine(
        modelTier: AiWhisperModelTier.base,
        extractor: _FakeAudioExtractor(),
        whisperWorker: _FakeWhisperWorker(rawWhisperSegments),
        batchTranslator: GoogleWebBatchTranslator(dio: dio),
      );

      await engine.initialize();
      final result = await engine
          .generateSubtitlesForChunk(
            const AudioChunkRequest(
              mediaItemId: 'vid_merge_1',
              streamUrl: 'https://example.com/movie.mp4',
              httpHeaders: {},
              chunkStart: Duration.zero,
              chunkDuration: Duration(seconds: 45),
              sourceLanguage: 'auto',
              targetLanguage: 'ko',
            ),
          )
          .toList();

      expect(httpCallCount, 1);
      expect(
        capturedQuery,
        'When I went to the cafe, I met an old friend.\n|||\nI was really happy.',
      );
      expect(result.length, 4);

      // 원본 타임스탬프와 원문은 그대로 유지
      for (var i = 0; i < rawWhisperSegments.length; i++) {
        expect(result[i].startTime, rawWhisperSegments[i].startTime);
        expect(result[i].endTime, rawWhisperSegments[i].endTime);
        expect(result[i].originalText, rawWhisperSegments[i].originalText);
        expect(result[i].languageCode, 'en');
        expect(result[i].translatedText, isNotNull);
        expect(result[i].translatedText!.isNotEmpty, isTrue);
      }

      // 첫 번째 병합 문장(0~2번 세그먼트) 재조합 검증
      final rejoinedFirst =
          [result[0].translatedText, result[1].translatedText, result[2].translatedText]
              .join(' ');
      expect(rejoinedFirst, '내가 카페에 갔을 때, 오랜 친구를 만났어.');
      // 두 번째 문장(3번 세그먼트) 단일 매핑 검증
      expect(result[3].translatedText, '정말 기뻤어.');

      await engine.dispose();
    });
  });

  group('Windows Desktop Audio Extraction & Whisper CLI/FFI Fallback Tests', () {
    test('DesktopFfmpegExtractor reports unavailable safely when both ffmpeg.exe and libmpv are missing', () async {
      final extractor = DesktopFfmpegExtractor(
        ffmpegPathFinderOverride: () async => null,
        mpvAvailableOverride: () => false,
      );

      expect(await extractor.isAvailable(), isFalse);
      final reason = await extractor.getUnavailableReason();
      expect(reason, isNotNull);

      expect(
        () => extractor.extractChunk(
          streamUrl: 'file:///local/movie.mp4',
          httpHeaders: const {},
          start: Duration.zero,
          duration: const Duration(seconds: 30),
          outputWavPath: '${Directory.systemTemp.path}/nonexistent_test.wav',
        ),
        throwsA(isA<AudioExtractionException>()),
      );
      await extractor.dispose();
    });

    test('DesktopFfmpegExtractor becomes available when libmpv fallback is present without ffmpeg.exe', () async {
      final extractor = DesktopFfmpegExtractor(
        ffmpegPathFinderOverride: () async => null,
        mpvAvailableOverride: () => true,
      );

      expect(await extractor.isAvailable(), Platform.isWindows);
      await extractor.dispose();
    });

    test('WhisperIsolateWorker parses whisper-cli.exe JSON and stdout timestamp outputs accurately', () {
      const cliJson = '''
{
  "result": { "language": "en" },
  "transcription": [
    {
      "timestamps": { "from": "00:00:01,250", "to": "00:00:03,800" },
      "offsets": { "from": 1250, "to": 3800 },
      "text": " Hello from Windows."
    },
    {
      "timestamps": { "from": "00:00:04,000", "to": "00:00:05,500" },
      "text": " [BLANK_AUDIO] "
    },
    {
      "timestamps": { "from": "00:00:06,100", "to": "00:00:08,900" },
      "text": " How are you?"
    }
  ]
}
''';

      final jsonSegments = WhisperIsolateWorker.parseWhisperCliJson(
        jsonString: cliJson,
        chunkOffset: const Duration(seconds: 45),
        chunkDuration: const Duration(seconds: 45),
        sourceLanguage: 'auto',
      );

      expect(jsonSegments.length, 2);
      expect(jsonSegments[0].startTime, const Duration(seconds: 46, milliseconds: 250));
      expect(jsonSegments[0].endTime, const Duration(seconds: 48, milliseconds: 800));
      expect(jsonSegments[0].originalText, 'Hello from Windows.');
      expect(jsonSegments[0].languageCode, 'en');
      expect(jsonSegments[1].startTime, const Duration(seconds: 51, milliseconds: 100));
      expect(jsonSegments[1].endTime, const Duration(seconds: 53, milliseconds: 900));
      expect(jsonSegments[1].originalText, 'How are you?');

      const cliStdout = '''
[00:00:00.500 --> 00:00:02.400]   [Music]
[00:00:02.500 --> 00:00:05.100]   Welcome to desktop mode.
''';
      final stdoutSegments = WhisperIsolateWorker.parseWhisperCliStdout(
        stdoutText: cliStdout,
        chunkOffset: const Duration(seconds: 90),
        chunkDuration: const Duration(seconds: 45),
        sourceLanguage: 'en',
      );

      expect(stdoutSegments.length, 1);
      expect(stdoutSegments.first.startTime, const Duration(seconds: 92, milliseconds: 500));
      expect(stdoutSegments.first.endTime, const Duration(seconds: 95, milliseconds: 100));
      expect(stdoutSegments.first.originalText, 'Welcome to desktop mode.');
      expect(stdoutSegments.first.languageCode, 'en');
    });

    test('AiSubtitleService safely disables FreeHybridSubtitleEngine and shows notice when Windows binaries are missing', () async {
      final unavailableExtractor = DesktopFfmpegExtractor(
        ffmpegPathFinderOverride: () async => null,
        mpvAvailableOverride: () => false,
      );
      final unavailableWhisper = WhisperIsolateWorker(
        windowsFfiPathFinderOverride: () => null,
        windowsCliPathFinderOverride: () async => null,
      );

      final service = AiSubtitleService.forTesting(
        translationSupportedOverride: false,
        initialConfig: const AiSubtitleConfig(
          engineType: AiSubtitleEngineType.freeHybrid,
          modelTier: AiWhisperModelTier.base,
        ),
        freeHybridEngineFactory: (tier) => FreeHybridSubtitleEngine(
          modelTier: tier,
          extractor: unavailableExtractor,
          whisperWorker: unavailableWhisper,
        ),
      );
      service.setStreamContextForTesting(
        mediaItemId: 'vid_missing_bin',
        streamUrl: 'file:///local/movie.mp4',
      );

      String? notice;
      var isWarn = false;
      service.onNotification = (msg, {bool isWarning = false}) {
        notice = msg;
        isWarn = isWarning;
      };

      await service.setEnabled(true);
      service.processPositionUpdate(const Duration(seconds: 1), isPlaying: true);
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(service.isEnabled, isFalse);
      expect(isWarn, isTrue);
      expect(notice, isNotNull);
      expect(service.lastErrorMessage, isNotNull);
      await service.unbindStreamContext();
    });

    test('AiSubtitleService resumes scheduling after epoch change during slow in-flight chunk and warns on slow Windows CPU model', () async {
      final firstChunkGate = Completer<void>();
      final requestedModelTiers = <AiWhisperModelTier>[];
      final requestedStarts = <Duration>[];

      final service = AiSubtitleService.forTesting(
        translationSupportedOverride: false,
        initialConfig: const AiSubtitleConfig(
          engineType: AiSubtitleEngineType.freeHybrid,
          modelTier: AiWhisperModelTier.largeV3TurboQ5,
          chunkSeconds: 45,
        ),
        freeHybridEngineFactory: (tier) => _SlowDelayedFreeHybridEngine(
          tier: tier,
          onChunkRequested: (req) async {
            requestedModelTiers.add(tier);
            requestedStarts.add(req.chunkStart);
            if (tier == AiWhisperModelTier.largeV3TurboQ5) {
              await firstChunkGate.future;
              return const [];
            }
            return [
              SubtitleSegment(
                startTime: req.chunkStart,
                endTime: req.chunkStart + const Duration(seconds: 5),
                originalText: 'Fast tiny line',
                translatedText: '빠른 타이니 자막',
              ),
            ];
          },
        ),
      );
      service.isWindowsPlatformOverride = true;
      service.setStreamContextForTesting(
        mediaItemId: 'vid_slow_switch',
        streamUrl: 'file:///local/movie.mp4',
      );

      await service.setEnabled(true);
      service.processPositionUpdate(const Duration(seconds: 1), isPlaying: true);
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(requestedModelTiers, [AiWhisperModelTier.largeV3TurboQ5]);
      expect(service.isProcessingChunk, isTrue);
      expect(service.statusMessage, contains('Large v3 Turbo Q5'));

      // 사용자가 분석 대기 중 Tiny 모델로 전환해도 기존 작업 종료 후 새 모델 스케줄링이 재개되어야 함
      await service.updateConfig(
        service.config.copyWith(modelTier: AiWhisperModelTier.tiny),
      );
      firstChunkGate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(requestedModelTiers, contains(AiWhisperModelTier.tiny));
      expect(service.maxConcurrentChunkWorkersObserved, 1);
      service.processPositionUpdate(const Duration(seconds: 2), isPlaying: true);
      expect(service.currentSegment?.translatedText, '빠른 타이니 자막');
      await service.unbindStreamContext();
    });

    test('Adaptive pipeline uses 12s short initial chunk, 30s pre-extracted chunks, skips stale chunks, and jumps +15s ahead', () async {
      final extractedRanges = <(Duration, Duration)>[];
      final transcribedRanges = <(Duration, Duration)>[];
      var simulatedPos = Duration.zero;

      final extractor = _RecordingAudioExtractor(
        onExtract: (start, duration) {
          extractedRanges.add((start, duration));
        },
      );
      final preExtractor = _RecordingAudioExtractor(
        onExtract: (start, duration) {
          extractedRanges.add((start, duration));
        },
      );
      final whisperWorker = _RecordingWhisperWorker(
        onTranscribe: (offset, duration) async {
          transcribedRanges.add((offset, duration));
          if (offset == Duration.zero) {
            // 첫 12초 청크를 분석하는 동안 재생 위치가 50초로 크게 앞서갔다고 시뮬레이션
            // (이미 선행 추출된 12~42초 청크는 종료 시간 42초 <= 50초이므로 Stale 폐기 대상)
            simulatedPos = const Duration(seconds: 50);
          }
          return [
            SubtitleSegment(
              startTime: offset + const Duration(seconds: 1),
              endTime: offset + const Duration(seconds: 4),
              originalText: 'Line at ${offset.inSeconds}s',
            ),
          ];
        },
      );

      final service = AiSubtitleService.forTesting(
        translationSupportedOverride: false,
        initialConfig: const AiSubtitleConfig(
          engineType: AiSubtitleEngineType.freeHybrid,
          modelTier: AiWhisperModelTier.small,
        ),
        freeHybridEngineFactory: (tier) => _TestReadyFreeHybridEngine(
          modelTier: tier,
          extractor: extractor,
          preExtractor: preExtractor,
          whisperWorker: whisperWorker,
        ),
      );
      service.currentPositionOverride = () => simulatedPos;
      service.setStreamContextForTesting(
        mediaItemId: 'vid_stale_skip',
        streamUrl: 'file:///local/movie.mp4',
      );

      await service.setEnabled(true);
      service.processPositionUpdate(Duration.zero, isPlaying: true);
      await Future<void>.delayed(const Duration(milliseconds: 120));

      // 1. 첫 청크는 12초 단위로 추출·전사되고, 선행 청크(12~42s)는 30초 단위로 미리 추출됨
      expect(extractedRanges.first, (Duration.zero, const Duration(seconds: 12)));
      expect(
        extractedRanges,
        contains((const Duration(seconds: 12), const Duration(seconds: 30))),
      );

      // 2. 12~42초 청크는 재생 위치(50s >= 42s)가 이미 지나갔으므로 Whisper 실행 없이 Stale 폐기됨
      expect(
        transcribedRanges.any((r) => r.$1 == const Duration(seconds: 12)),
        isFalse,
      );
      expect(service.skippedStaleChunkCount, greaterThanOrEqualTo(1));

      // 3. Stale 폐기 후 현재 재생 위치(50s) 기준 +15초 앞선 미래 구간(65s~95s)을 새로 추출·전사함
      expect(
        transcribedRanges.any(
          (r) =>
              r.$1 == const Duration(seconds: 65) &&
              r.$2 == const Duration(seconds: 30),
        ),
        isTrue,
      );
      expect(service.maxConcurrentChunkWorkersObserved, 1);
      await service.unbindStreamContext();
    });

    test('Serial worker queue prevents overlapping Whisper runs across rapid position triggers', () async {
      final firstGate = Completer<void>();
      var activeWhisperCount = 0;
      var maxWhisperConcurrent = 0;
      var whisperCallCount = 0;

      final service = AiSubtitleService.forTesting(
        translationSupportedOverride: false,
        initialConfig: const AiSubtitleConfig(
          engineType: AiSubtitleEngineType.freeHybrid,
          modelTier: AiWhisperModelTier.small,
        ),
        freeHybridEngineFactory: (tier) => _TestReadyFreeHybridEngine(
          modelTier: tier,
          extractor: _FakeAudioExtractor(),
          preExtractor: _FakeAudioExtractor(),
          whisperWorker: _RecordingWhisperWorker(
            onTranscribe: (offset, duration) async {
              activeWhisperCount++;
              if (activeWhisperCount > maxWhisperConcurrent) {
                maxWhisperConcurrent = activeWhisperCount;
              }
              whisperCallCount++;
              if (whisperCallCount == 1) {
                await firstGate.future;
              }
              activeWhisperCount--;
              return [
                SubtitleSegment(
                  startTime: offset,
                  endTime: offset + const Duration(seconds: 4),
                  originalText: 'Serial line',
                ),
              ];
            },
          ),
        ),
      );
      service.setStreamContextForTesting(
        mediaItemId: 'vid_serial_mutex',
        streamUrl: 'file:///local/movie.mp4',
      );

      await service.setEnabled(true);
      for (var sec = 1; sec <= 5; sec++) {
        service.processPositionUpdate(Duration(seconds: sec), isPlaying: true);
      }
      await Future<void>.delayed(const Duration(milliseconds: 40));

      // 이전 Whisper가 완료되기 전에 중복 실행되지 않아야 함
      expect(whisperCallCount, 1);
      expect(maxWhisperConcurrent, 1);

      firstGate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(maxWhisperConcurrent, 1);
      expect(service.maxConcurrentChunkWorkersObserved, 1);
      await service.unbindStreamContext();
    });

    test('extractAndTranscribeChunkWithWhisper discards stale WAV before running Whisper', () async {
      var whisperCalled = false;
      final worker = _RecordingWhisperWorker(
        onTranscribe: (offset, duration) async {
          whisperCalled = true;
          return const [];
        },
      );
      final tempWav = File(
        '${Directory.systemTemp.path}/stale_pre_test_${DateTime.now().microsecondsSinceEpoch}.wav',
      );
      await tempWav.writeAsBytes(List<int>.filled(128, 1));

      final segments = await extractAndTranscribeChunkWithWhisper(
        extractor: _FakeAudioExtractor(),
        whisperWorker: worker,
        chunkSequence: 1,
        isCancelled: () => false,
        request: AudioChunkRequest(
          mediaItemId: 'vid_pre_stale',
          streamUrl: 'file:///local/movie.mp4',
          httpHeaders: const {},
          chunkStart: Duration.zero,
          chunkDuration: const Duration(seconds: 30),
          preExtractedWavPath: tempWav.path,
          shouldSkipBeforeTranscribe: () => true,
        ),
      );

      expect(segments, isEmpty);
      expect(whisperCalled, isFalse);
      expect(tempWav.existsSync(), isFalse);
    });

    test('WhisperIsolateWorker builds Vulkan GPU (-ngl 99) args and falls back to CPU (-ngl 0 -t 4) on GPU failure', () async {
      final gpuArgs = WhisperIsolateWorker.buildWindowsCliArgs(
        modelPath: 'ggml-small.bin',
        wavPath: 'chunk.wav',
        sourceLanguage: 'en',
        outPrefix: 'chunk.wav.out',
        useGpu: true,
      );
      expect(gpuArgs, containsAllInOrder(['-ngl', '99']));

      final cpuArgs = WhisperIsolateWorker.buildWindowsCliArgs(
        modelPath: 'ggml-small.bin',
        wavPath: 'chunk.wav',
        sourceLanguage: 'en',
        outPrefix: 'chunk.wav.out',
        useGpu: false,
      );
      expect(cpuArgs, containsAllInOrder(['-ngl', '0', '-t', '4']));

      if (!Platform.isWindows) return;

      final recordedCliArgs = <List<String>>[];
      final worker = WhisperIsolateWorker(
        windowsFfiPathFinderOverride: () => null,
        windowsCliPathFinderOverride: () async => r'C:\tools\whisper-cli.exe',
        vulkanAvailableOverride: true,
        modelPathOverride: (tier) async => 'ggml-${tier.code}.bin',
        windowsCliRunnerOverride: (cliPath, args) async {
          recordedCliArgs.add(args);
          if (args.contains('99')) {
            return (
              exitCode: 1,
              stdout: '',
              stderr: 'ggml_vulkan: Failed to initialize Vulkan device',
            );
          }
          return (
            exitCode: 0,
            stdout: '[00:00:00.000 --> 00:00:02.000]  Fallback CPU success.',
            stderr: '',
          );
        },
      );

      await worker.initialize(tier: AiWhisperModelTier.tiny);
      final tmpWav = File(
        '${Directory.systemTemp.path}/vulkan_fb_${DateTime.now().microsecondsSinceEpoch}.wav',
      );
      await tmpWav.writeAsBytes(List<int>.filled(64, 1));
      try {
        final segments = await worker.transcribeChunk(
          wavPath: tmpWav.path,
          chunkOffset: Duration.zero,
          chunkDuration: const Duration(seconds: 12),
          sourceLanguage: 'en',
        );

        expect(recordedCliArgs.length, 2);
        expect(recordedCliArgs[0], containsAllInOrder(['-ngl', '99']));
        expect(recordedCliArgs[1], containsAllInOrder(['-ngl', '0', '-t', '4']));
        expect(worker.hasFallenBackToCpu, isTrue);
        expect(segments.length, 1);
        expect(segments.first.originalText, 'Fallback CPU success.');
      } finally {
        if (tmpWav.existsSync()) await tmpWav.delete();
        await worker.release();
      }
    });
  });
}

class _RecordingAudioExtractor implements AudioChunkExtractor {
  final void Function(Duration start, Duration duration) onExtract;

  _RecordingAudioExtractor({required this.onExtract});

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
    onExtract(start, duration);
    final file = File(outputWavPath);
    if (!file.parent.existsSync()) {
      file.parent.createSync(recursive: true);
    }
    await file.writeAsBytes(List<int>.filled(64, 1));
    return file;
  }

  @override
  Future<void> cancel() async {}

  @override
  Future<void> dispose() async {}
}

class _RecordingWhisperWorker extends WhisperIsolateWorker {
  final Future<List<SubtitleSegment>> Function(
    Duration offset,
    Duration duration,
  ) onTranscribe;

  _RecordingWhisperWorker({required this.onTranscribe});

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<void> initialize({
    required AiWhisperModelTier tier,
    void Function(double progress, String status)? onProgress,
  }) async {}

  @override
  Future<List<SubtitleSegment>> transcribeChunk({
    required String wavPath,
    required Duration chunkOffset,
    required Duration chunkDuration,
    required String sourceLanguage,
  }) {
    return onTranscribe(chunkOffset, chunkDuration);
  }

  @override
  Future<void> release() async {}
}

class _TestReadyFreeHybridEngine extends FreeHybridSubtitleEngine {
  _TestReadyFreeHybridEngine({
    required super.modelTier,
    required AudioChunkExtractor extractor,
    required AudioChunkExtractor preExtractor,
    required WhisperIsolateWorker whisperWorker,
  }) : super(
          extractor: extractor,
          preExtractor: preExtractor,
          whisperWorker: whisperWorker,
          batchTranslator: GoogleWebBatchTranslator(
            dio: Dio()
              ..httpClientAdapter = _MockHttpAdapter((options) async {
                final body = jsonEncode([
                  [
                    ['테스트 번역', 'test', null, null, 1],
                  ],
                  null,
                  'en',
                ]);
                return ResponseBody.fromString(
                  body,
                  200,
                  headers: {
                    Headers.contentTypeHeader: [Headers.jsonContentType],
                  },
                );
              }),
          ),
        );

  @override
  Future<bool> isSupported() async => true;
}

class _SlowDelayedFreeHybridEngine extends FreeHybridSubtitleEngine {
  final Future<List<SubtitleSegment>> Function(AudioChunkRequest req)
      onChunkRequested;

  _SlowDelayedFreeHybridEngine({
    required AiWhisperModelTier tier,
    required this.onChunkRequested,
  }) : super(
          modelTier: tier,
          extractor: _FakeAudioExtractor(),
          whisperWorker: _FakeWhisperWorker(const []),
        );

  @override
  Future<bool> isSupported() async => true;

  @override
  Future<void> initialize({
    void Function(double progress, String status)? onProgress,
  }) async {
    onProgress?.call(1.0, 'Ready');
  }

  @override
  Stream<SubtitleSegment> generateSubtitlesForChunk(
    AudioChunkRequest request,
  ) async* {
    final segments = await onChunkRequested(request);
    for (final s in segments) {
      yield s;
    }
  }
}
