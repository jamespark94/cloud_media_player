import 'dart:convert';
import 'dart:io';
import 'package:cloud_media_player/models/ai_subtitle/ai_subtitle_config.dart';
import 'package:cloud_media_player/models/ai_subtitle/subtitle_segment.dart';
import 'package:cloud_media_player/services/ai_subtitle/ai_subtitle_key_storage.dart';
import 'package:cloud_media_player/services/ai_subtitle/ai_subtitle_service.dart';
import 'package:cloud_media_player/services/ai_subtitle/engines/free_hybrid_subtitle_engine.dart';
import 'package:cloud_media_player/services/ai_subtitle/engines/on_device_subtitle_engine.dart';
import 'package:cloud_media_player/services/ai_subtitle/extractors/audio_chunk_extractor.dart';
import 'package:cloud_media_player/services/ai_subtitle/stt/whisper_isolate_worker.dart';
import 'package:cloud_media_player/services/ai_subtitle/subtitle_generator_engine.dart';
import 'package:cloud_media_player/services/ai_subtitle/translators/fallback_subtitle_translator.dart';
import 'package:cloud_media_player/services/ai_subtitle/translators/gcp_cloud_batch_translator.dart';
import 'package:cloud_media_player/services/ai_subtitle/translators/gcp_cloud_subtitle_translator.dart';
import 'package:cloud_media_player/services/ai_subtitle/translators/mlkit_subtitle_translator.dart';
import 'package:cloud_media_player/ui/screens/app_settings_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _FakeAudioExtractor implements AudioChunkExtractor {
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

class _FakeWhisperWorker extends WhisperIsolateWorker {
  final List<SubtitleSegment> segments;
  _FakeWhisperWorker(this.segments);

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
  }) async =>
      segments;

  @override
  Future<void> release() async {}
}

class _FakeModelManager extends OnDeviceTranslatorModelManager {
  final Set<String> downloaded;
  _FakeModelManager(this.downloaded);

  @override
  Future<bool> isModelDownloaded(String model) async =>
      downloaded.contains(model);

  @override
  Future<bool> downloadModel(String model, {bool isWifiRequired = true}) async {
    downloaded.add(model);
    return true;
  }
}

class _FakeMlKitOnDeviceTranslator extends OnDeviceTranslator {
  final String Function(
    TranslateLanguage source,
    TranslateLanguage target,
    String text,
  ) onTranslate;

  _FakeMlKitOnDeviceTranslator({
    required super.sourceLanguage,
    required super.targetLanguage,
    required this.onTranslate,
  });

  @override
  Future<String> translateText(String text) async =>
      onTranslate(sourceLanguage, targetLanguage, text);

  @override
  Future<void> close() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('GCP Cloud Translation API v2 Batch Translator Tests', () {
    test('Sends direct POST with {"q", "target": "ko", "format": "html"} and no source, joins with <span translate="no">|||</span>, and decodes HTML entities', () async {
      Uri? capturedUri;
      String? capturedMethod;
      Map<String, dynamic>? capturedBody;
      var callCount = 0;

      final mockClient = MockClient((request) async {
        callCount++;
        capturedUri = request.url;
        capturedMethod = request.method;
        capturedBody = jsonDecode(request.body) as Map<String, dynamic>;

        final responsePayload = jsonEncode({
          'data': {
            'translations': [
              {
                'translatedText':
                    '안녕, &quot;친구&quot;! &amp; 반가워.<span translate="no">|||</span>그건 &#39;정말&#39; 멋지네요&#x21;',
                'detectedSourceLanguage': 'en',
              }
            ],
          },
        });
        return http.Response.bytes(
          utf8.encode(responsePayload),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });

      final translator = GcpCloudBatchTranslator(httpClient: mockClient);
      final result = await translator.translateBatch(
        const [
          'Hello, "friend"! & nice to meet you.',
          "That's 'really' cool!",
        ],
        apiKey: 'AIzaTestKey123456',
      );

      expect(callCount, 1);
      expect(capturedMethod, 'POST');
      expect(
        capturedUri.toString(),
        'https://translation.googleapis.com/language/translate/v2?key=AIzaTestKey123456',
      );
      expect(capturedBody, isNotNull);
      expect(capturedBody!.containsKey('source'), isFalse);
      expect(capturedBody!['target'], 'ko');
      expect(capturedBody!['format'], 'html');
      expect(
        capturedBody!['q'],
        'Hello, "friend"! & nice to meet you.<span translate="no">|||</span>That\'s \'really\' cool!',
      );
      expect(result.detectedSourceLanguage, 'en');
      expect(result.translations, [
        '안녕, "친구"! & 반가워.',
        "그건 '정말' 멋지네요!",
      ]);
      translator.dispose();
    });

    test('Chunks multi-line batches to at most 3,500 chars including delimiter', () async {
      final sentQueries = <String>[];

      final mockClient = MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final q = body['q'] as String;
        sentQueries.add(q);

        final parts = q.split('<span translate="no">|||</span>');
        final translatedParts =
            parts.map((p) => '번역:${p.substring(0, 6)}').join('<span translate="no"> ||| </span>');

        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'data': {
                'translations': [
                  {'translatedText': translatedParts, 'detectedSourceLanguage': 'en'},
                ],
              },
            }),
          ),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });

      // 5 sentences x 900 chars -> 4,500+ chars, must split into 2 batches <= 3500 chars each
      final inputs = List<String>.generate(
        5,
        (i) => 'Line0$i ${'a' * 893}',
      );

      final translator = GcpCloudBatchTranslator(httpClient: mockClient);
      final result = await translator.translateBatch(
        inputs,
        apiKey: 'AIzaBatchKey',
      );

      expect(sentQueries.length, 2);
      for (final q in sentQueries) {
        expect(q.length, lessThanOrEqualTo(3500));
      }
      expect(result.translations.length, 5);
      for (var i = 0; i < 5; i++) {
        expect(result.translations[i], '번역:Line0$i');
      }
      translator.dispose();
    });

    test('decodeHtmlEntities decodes numeric, hex, and named entities in single pass', () {
      expect(
        GcpCloudBatchTranslator.decodeHtmlEntities(
          'Don&#39;t say &quot;Hello &amp; Bye&quot; &lt;tag&gt; &#x27;ok&#x27; &amp;quot;',
        ),
        'Don\'t say "Hello & Bye" <tag> \'ok\' &quot;',
      );
    });
  });

  group('GCP Translation Automatic Fallback Tests', () {
    test('Falls back to ML Kit when API key is missing', () async {
      var httpCalled = false;
      final gcpBatch = GcpCloudBatchTranslator(
        httpClient: MockClient((_) async {
          httpCalled = true;
          return http.Response('{}', 200);
        }),
      );

      final mlKit = MlKitSubtitleTranslator(
        modelManager: _FakeModelManager({'ko', 'en'}),
        translatorFactory: (src, tgt) => _FakeMlKitOnDeviceTranslator(
          sourceLanguage: src,
          targetLanguage: tgt,
          onTranslate: (s, t, text) => '로컬번역:$text',
        ),
      );

      final translator = GcpCloudSubtitleTranslator(
        apiKeyProvider: () async => null,
        hasApiKeySync: () => false,
        gcpTranslator: gcpBatch,
        fallbackTranslator: mlKit,
      );

      await translator.initialize(sourceLang: 'en', targetLang: 'ko');
      final results = await translator.translateBatch(['Hello', 'World']);

      expect(httpCalled, isFalse);
      expect(translator.isUsingFallback, isTrue);
      expect(results, ['로컬번역:Hello', '로컬번역:World']);
      await translator.dispose();
    });

    for (final statusCode in [403, 429]) {
      test('Automatically switches to ML Kit fallback on HTTP $statusCode error', () async {
        var gcpCallCount = 0;
        String? fallbackNotice;

        final gcpBatch = GcpCloudBatchTranslator(
          httpClient: MockClient((_) async {
            gcpCallCount++;
            return http.Response(
              jsonEncode({
                'error': {'code': statusCode, 'message': 'Quota/Auth error'},
              }),
              statusCode,
            );
          }),
        );

        final mlKit = MlKitSubtitleTranslator(
          modelManager: _FakeModelManager({'ko', 'en'}),
          translatorFactory: (src, tgt) => _FakeMlKitOnDeviceTranslator(
            sourceLanguage: src,
            targetLanguage: tgt,
            onTranslate: (s, t, text) => 'MLKit:$text',
          ),
        );

        var currentKey = 'AIzaFailingKey_$statusCode';
        final translator = GcpCloudSubtitleTranslator(
          apiKeyProvider: () async => currentKey,
          hasApiKeySync: () => currentKey.isNotEmpty,
          gcpTranslator: gcpBatch,
          fallbackTranslator: mlKit,
          onFallback: (reason) => fallbackNotice = reason,
        );

        await translator.initialize(sourceLang: 'auto', targetLang: 'ko');
        final first = await translator.translateBatch(['Hello']);
        expect(first, ['MLKit:Hello']);
        expect(translator.isUsingFallback, isTrue);
        expect(fallbackNotice, contains('$statusCode'));

        // Subsequent calls with same failed key stay on fallback without retrying GCP
        final second = await translator.translateBatch(['Next line']);
        expect(second, ['MLKit:Next line']);
        expect(gcpCallCount, 1);
        await translator.dispose();
      });
    }

    test('Falls back safely to FallbackSubtitleTranslator (null) on HTTP 403/429 when ML Kit is unavailable', () async {
      final gcpBatch = GcpCloudBatchTranslator(
        httpClient: MockClient((_) async => http.Response('{}', 403)),
      );

      final translator = GcpCloudSubtitleTranslator(
        apiKeyProvider: () async => 'AIzaForbiddenKey',
        hasApiKeySync: () => true,
        gcpTranslator: gcpBatch,
        fallbackTranslator: FallbackSubtitleTranslator(),
      );

      await translator.initialize(sourceLang: 'en', targetLang: 'ko');
      final res = await translator.translateBatch(['Hello']);
      expect(translator.isUsingFallback, isTrue);
      expect(res, [null]);
      await translator.dispose();
    });

    test('OnDeviceSubtitleEngine & FreeHybridSubtitleEngine use GCP Cloud Translation batch when key is configured', () async {
      var gcpCalls = 0;
      final gcpBatch = GcpCloudBatchTranslator(
        httpClient: MockClient((request) async {
          gcpCalls++;
          final payload = jsonEncode({
            'data': {
              'translations': [
                {
                  'translatedText': '첫 번째<span translate="no">|||</span>두 번째',
                  'detectedSourceLanguage': 'en',
                }
              ],
            },
          });
          return http.Response.bytes(
            utf8.encode(payload),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );

      final onDeviceEngine = OnDeviceSubtitleEngine(
        extractor: _FakeAudioExtractor(),
        whisperWorker: _FakeWhisperWorker(const [
          SubtitleSegment(
            startTime: Duration(seconds: 1),
            endTime: Duration(seconds: 3),
            originalText: 'First line.',
          ),
          SubtitleSegment(
            startTime: Duration(seconds: 4),
            endTime: Duration(seconds: 6),
            originalText: 'Second line.',
          ),
        ]),
        translator: GcpCloudSubtitleTranslator(
          apiKeyProvider: () async => 'AIzaActiveKey',
          hasApiKeySync: () => true,
          gcpTranslator: gcpBatch,
          fallbackTranslator: FallbackSubtitleTranslator(),
        ),
      );

      await onDeviceEngine.initialize(sourceLanguage: 'auto', targetLanguage: 'ko');
      final segments = await onDeviceEngine
          .generateSubtitlesForChunk(
            const AudioChunkRequest(
              mediaItemId: 'vid_gcp_1',
              streamUrl: 'https://example.com/v.mp4',
              httpHeaders: {},
              chunkStart: Duration.zero,
              chunkDuration: Duration(seconds: 20),
            ),
          )
          .toList();

      expect(gcpCalls, 1);
      expect(segments.map((s) => s.translatedText).toList(), ['첫 번째', '두 번째']);
      expect(segments.first.languageCode, 'en');
      await onDeviceEngine.dispose();

      // FreeHybridSubtitleEngine also routes through GCP when key is present
      var hybridGcpCalls = 0;
      final hybridEngine = FreeHybridSubtitleEngine(
        extractor: _FakeAudioExtractor(),
        whisperWorker: _FakeWhisperWorker(const [
          SubtitleSegment(
            startTime: Duration(seconds: 1),
            endTime: Duration(seconds: 3),
            originalText: 'Hello!',
          ),
          SubtitleSegment(
            startTime: Duration(seconds: 4),
            endTime: Duration(seconds: 6),
            originalText: 'Goodbye!',
          ),
        ]),
        gcpApiKeyProvider: () async => 'AIzaActiveKey',
        gcpTranslator: GcpCloudSubtitleTranslator(
          apiKeyProvider: () async => 'AIzaActiveKey',
          hasApiKeySync: () => true,
          gcpTranslator: GcpCloudBatchTranslator(
            httpClient: MockClient((_) async {
              hybridGcpCalls++;
              return http.Response.bytes(
                utf8.encode(
                  jsonEncode({
                    'data': {
                      'translations': [
                        {
                          'translatedText': '안녕!<span translate="no">|||</span>잘 가!',
                          'detectedSourceLanguage': 'en',
                        }
                      ],
                    },
                  }),
                ),
                200,
                headers: {'content-type': 'application/json; charset=utf-8'},
              );
            }),
          ),
          fallbackTranslator: FallbackSubtitleTranslator(),
        ),
      );

      await hybridEngine.initialize();
      final hybridSegments = await hybridEngine
          .generateSubtitlesForChunk(
            const AudioChunkRequest(
              mediaItemId: 'vid_gcp_2',
              streamUrl: 'https://example.com/v.mp4',
              httpHeaders: {},
              chunkStart: Duration.zero,
              chunkDuration: Duration(seconds: 45),
            ),
          )
          .toList();

      expect(hybridGcpCalls, 1);
      expect(hybridSegments.map((s) => s.translatedText).toList(), ['안녕!', '잘 가!']);
      await hybridEngine.dispose();
    });
  });

  group('Key Storage & App Settings UI Tests', () {
    test('AiSubtitleKeyStorage stores, masks, and deletes GCP Translation API key', () async {
      final storage = AiSubtitleKeyStorage.inMemory();
      expect(storage.hasCachedGcpTranslationApiKey, isFalse);

      await storage.saveGcpTranslationApiKey('  AIzaSyGcpTestKey9876  ');
      expect(storage.hasCachedGcpTranslationApiKey, isTrue);
      expect(storage.cachedGcpTranslationApiKey, 'AIzaSyGcpTestKey9876');
      expect(
        AiSubtitleKeyStorage.maskApiKey(storage.cachedGcpTranslationApiKey),
        'AIza••••9876',
      );

      await storage.deleteGcpTranslationApiKey();
      expect(storage.hasCachedGcpTranslationApiKey, isFalse);
      expect(await storage.loadGcpTranslationApiKey(), isNull);
    });

    testWidgets('AppSettingsDialog saves and deletes GCP Cloud Translation API key', (tester) async {
      final testService = AiSubtitleService.forTesting(
        keyStorage: AiSubtitleKeyStorage.inMemory(),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppSettingsDialog(aiSubtitleService: testService),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('앱 설정'), findsOneWidget);
      expect(find.text('GCP Cloud Translation API 키'), findsOneWidget);

      final gcpField = find.byWidgetPredicate(
        (w) =>
            w is TextField &&
            (w.decoration?.hintText?.contains('GCP Translation') ?? false),
      );
      expect(gcpField, findsOneWidget);

      await tester.enterText(gcpField, 'AIzaSyDemoGcpKey4321');
      await tester.tap(find.widgetWithText(ElevatedButton, '저장').first);
      await tester.pumpAndSettle();

      expect(testService.hasGcpTranslationApiKey, isTrue);
      expect(testService.maskedGcpTranslationApiKey, 'AIza••••4321');
      expect(find.text('저장됨 (AIza••••4321)'), findsOneWidget);

      await tester.tap(find.byTooltip('저장된 API Key 삭제').first);
      await tester.pumpAndSettle();

      expect(testService.hasGcpTranslationApiKey, isFalse);
    });
  });
}
