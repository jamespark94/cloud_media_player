import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import '../../models/ai_subtitle/ai_subtitle_config.dart';
import '../../models/ai_subtitle/subtitle_segment.dart';
import 'ai_subtitle_key_storage.dart';
import 'engines/cloud_ai_subtitle_engine.dart';
import 'engines/free_hybrid_subtitle_engine.dart';
import 'engines/on_device_subtitle_engine.dart';
import 'extractors/local_http_audio_relay.dart';
import 'subtitle_generator_engine.dart';
import 'subtitle_segment_cache.dart';
import 'translators/subtitle_translator.dart';

/// AI 실시간 자막 생성·번역 계층의 최상위 Facade & ChangeNotifier.
///
/// - 기존 플레이어 코어 로직과 완전히 분리되어 `Player.stream.position`과
///   현재 스트림 URL/인증 헤더만 읽기 전용(Read-Only)으로 수신해 동작합니다.
/// - 기본값 `isEnabled = false` 상태에서는 엔진/모델/워커를 메모리에 일절 로드하지 않습니다.
class AiSubtitleService extends ChangeNotifier {
  static final AiSubtitleService instance = AiSubtitleService._internal();

  AiSubtitleService._internal()
      : _injectedEngine = null,
        _config = const AiSubtitleConfig(),
        _cache = SubtitleSegmentCache(
          chunkSeconds: AiSubtitleConfig.defaultFreeHybridChunkSeconds,
        ),
        _keyStorage = AiSubtitleKeyStorage.instance,
        translationSupportedOverride = null,
        seekDebounceDuration = const Duration(milliseconds: 1800),
        _cloudEngineFactory = null,
        _freeHybridEngineFactory = null,
        _onDeviceEngineFactory = null;

  /// 단위 테스트용 격리 생성자.
  @visibleForTesting
  AiSubtitleService.forTesting({
    SubtitleGeneratorEngine? engine,
    SubtitleSegmentCache? cache,
    AiSubtitleKeyStorage? keyStorage,
    AiSubtitleConfig? initialConfig,
    this.translationSupportedOverride,
    this.seekDebounceDuration = const Duration(milliseconds: 1800),
    CloudAiSubtitleEngine Function(String? apiKey, String modelName)?
        cloudEngineFactory,
    FreeHybridSubtitleEngine Function(AiWhisperModelTier tier)?
        freeHybridEngineFactory,
    OnDeviceSubtitleEngine Function(AiWhisperModelTier tier)?
        onDeviceEngineFactory,
  })  : _engine = engine,
        _injectedEngine = engine,
        _config = initialConfig ??
            (engine != null
                ? const AiSubtitleConfig(
                    engineType: AiSubtitleEngineType.onDevice,
                  )
                : const AiSubtitleConfig()),
        _cache = cache ??
            SubtitleSegmentCache(
              chunkSeconds: (initialConfig ??
                      (engine != null
                          ? const AiSubtitleConfig(
                              engineType: AiSubtitleEngineType.onDevice,
                            )
                          : const AiSubtitleConfig()))
                  .effectiveChunkSeconds,
            ),
        _keyStorage = keyStorage ?? AiSubtitleKeyStorage.inMemory(),
        _cloudEngineFactory = cloudEngineFactory,
        _freeHybridEngineFactory = freeHybridEngineFactory,
        _onDeviceEngineFactory = onDeviceEngineFactory;

  final SubtitleGeneratorEngine? _injectedEngine;
  SubtitleGeneratorEngine? _engine;
  SubtitleSegmentCache _cache;
  final AiSubtitleKeyStorage _keyStorage;
  final bool? translationSupportedOverride;
  final Duration seekDebounceDuration;
  final CloudAiSubtitleEngine Function(String? apiKey, String modelName)?
      _cloudEngineFactory;
  final FreeHybridSubtitleEngine Function(AiWhisperModelTier tier)?
      _freeHybridEngineFactory;
  final OnDeviceSubtitleEngine Function(AiWhisperModelTier tier)?
      _onDeviceEngineFactory;

  bool _isEnabled = false;
  bool _isEngineInitialized = false;
  bool _isInitializing = false;
  bool _isProcessingChunk = false;
  double? _initProgress;
  String? _statusMessage;
  String? _lastErrorMessage;
  AiSubtitleConfig _config;

  // Read-only 플레이어 스트림 바인딩 컨텍스트
  Player? _boundPlayer;
  String? _mediaItemId;
  String? _streamUrl;
  Map<String, String> _httpHeaders = const {};
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<bool>? _bufferingSub;
  StreamSubscription<bool>? _playingSub;

  SubtitleSegment? _currentSegment;
  Duration _lastPosition = Duration.zero;
  bool _lastIsPlaying = true;
  int _lastBucketIndex = -1;
  int _consecutiveErrors = 0;
  int _consecutiveTranslationErrors = 0;
  bool _hasNotifiedPlatformMode = false;
  bool _hasNotifiedTranslationError = false;
  bool _hasNotifiedSlowCpuModel = false;
  bool _isSchedulerRunning = false;
  int _runningSchedulerEpoch = -1;
  int? _queuedSchedulerEpoch;
  Future<void> _serialWorkerChain = Future<void>.value();
  int _jobEpoch = 0;
  Timer? _seekDebounceTimer;
  Timer? _chunkProgressTimer;

  // 적응형 실시간 스트리밍 상태 (초기 12초 청크 + 선행 30초 추출 + Stale 폐기)
  Duration? _adaptiveCursor;
  bool _isFirstAdaptiveChunk = true;
  _PreExtractedChunk? _pendingPreExtracted;
  int _preExtractSeq = 0;

  /// 테스트용 Windows CPU 경고 판정 오버라이드.
  @visibleForTesting
  bool? isWindowsPlatformOverride;

  /// 테스트용 적응형 실시간 파이프라인(12초 초기 + 30초 선행 + Stale 스킵) 강제 오버라이드.
  @visibleForTesting
  bool? useAdaptiveStreamingOverride;

  /// 테스트/진단용 현재 재생 위치 오버라이드.
  @visibleForTesting
  Duration Function()? currentPositionOverride;

  /// 테스트용: Stale로 폐기된 청크 수 및 직렬 워커 동시 실행 감지용 카운터.
  @visibleForTesting
  int skippedStaleChunkCount = 0;

  @visibleForTesting
  int maxConcurrentChunkWorkersObserved = 0;
  int _activeChunkWorkers = 0;

  static const int _maxConsecutiveErrors = 3;

  /// PlayerScreen 배너/스낵바와 느슨하게 연결하기 위한 선택적 알림 콜백.
  void Function(String message, {bool isWarning})? onNotification;

  /// Fail-Safe 폴백 등으로 엔진 설정이 자동 변경될 때 UI 설정을 동기화하기 위한 선택적 콜백.
  void Function(AiSubtitleConfig updatedConfig)? onConfigFallback;

  bool get isEnabled => _isEnabled;
  bool get isInitializing => _isInitializing;
  bool get isProcessingChunk => _isProcessingChunk;
  double? get initProgress => _initProgress;
  String? get statusMessage => _statusMessage;
  String? get lastErrorMessage => _lastErrorMessage;
  AiSubtitleConfig get config => _config;
  SubtitleSegment? get currentSegment => _currentSegment;
  SubtitleSegmentCache get cache => _cache;

  bool get hasGeminiApiKey => _keyStorage.hasCachedApiKey;
  String? get maskedGeminiApiKey =>
      AiSubtitleKeyStorage.maskApiKey(_keyStorage.cachedApiKey);

  bool get isTranslationSupported {
    if (_config.engineType == AiSubtitleEngineType.cloudApi ||
        _config.engineType == AiSubtitleEngineType.freeHybrid) {
      return true;
    }
    return translationSupportedOverride ??
        SubtitleTranslator.create().isTranslationSupported;
  }

  String get acceleratorLabel {
    if (_engine != null) return _engine!.acceleratorLabel;
    if (_config.engineType == AiSubtitleEngineType.cloudApi) {
      return 'Gemini Multimodal API';
    }
    if (_config.engineType == AiSubtitleEngineType.freeHybrid) {
      return FreeHybridSubtitleEngine(modelTier: _config.modelTier)
          .acceleratorLabel;
    }
    return OnDeviceSubtitleEngine(modelTier: _config.modelTier).acceleratorLabel;
  }

  Future<String?> loadGeminiApiKey({bool forceRefresh = false}) async {
    final key = await _keyStorage.loadApiKey(forceRefresh: forceRefresh);
    notifyListeners();
    return key;
  }

  Future<void> saveGeminiApiKey(String apiKey) async {
    await _keyStorage.saveApiKey(apiKey);
    if (_config.engineType == AiSubtitleEngineType.cloudApi &&
        _injectedEngine == null) {
      await _disposeActiveEngine();
    }
    notifyListeners();
  }

  Future<void> deleteGeminiApiKey() async {
    await _keyStorage.deleteApiKey();
    if (_config.engineType == AiSubtitleEngineType.cloudApi &&
        _injectedEngine == null) {
      await _disposeActiveEngine();
    }
    notifyListeners();
  }

  /// 기존 플레이어가 스트림을 오픈한 직후 Read-Only 컨텍스트만 등록합니다.
  /// `isEnabled == false`인 동안에는 어떠한 리소스도 초기화하지 않습니다.
  Future<void> bindStreamContext({
    required Player player,
    required String mediaItemId,
    required String streamUrl,
    required Map<String, String> httpHeaders,
    AiSubtitleConfig? initialConfig,
  }) async {
    _boundPlayer = player;
    _mediaItemId = mediaItemId;
    _streamUrl = streamUrl;
    _httpHeaders = Map<String, String>.from(httpHeaders);
    _lastPosition = player.state.position;
    _lastIsPlaying = player.state.playing;
    _lastBucketIndex = -1;
    _consecutiveErrors = 0;
    _consecutiveTranslationErrors = 0;
    _hasNotifiedPlatformMode = false;
    _hasNotifiedTranslationError = false;
    _hasNotifiedSlowCpuModel = false;
    _resetAdaptivePipelineState();

    if (initialConfig != null) {
      _config = initialConfig;
      _recreateCacheIfBucketSizeChanged();
    }

    await _keyStorage.loadApiKey();
    await _cache.switchContext(
      mediaItemId: mediaItemId,
      sourceLanguage: _config.sourceLanguage,
      engineKey: _config.engineType.code,
    );

    if (_isEnabled) {
      _attachPlayerListeners(player);
      _evaluatePosition(_lastPosition);
    }
  }

  /// 듀얼 플레이어 화질 핫스왑 시 자막 캐시를 그대로 유지하면서 새 Player로 재바인딩합니다.
  void onPlayerHotSwapped({
    required Player newPlayer,
    required String newStreamUrl,
    required Map<String, String> newHeaders,
  }) {
    _boundPlayer = newPlayer;
    _streamUrl = newStreamUrl;
    _httpHeaders = Map<String, String>.from(newHeaders);
    _lastIsPlaying = newPlayer.state.playing;
    if (_isEnabled) {
      _attachPlayerListeners(newPlayer);
      _evaluatePosition(newPlayer.state.position);
    }
  }

  /// 플레이어 종료 시 호출되어 모든 백그라운드 워커 및 모델 메모리를 즉시 회수합니다.
  /// 다음 동영상의 기존 자막(.smi/.srt)이 가려지지 않도록 활성화 상태도 초기화합니다.
  Future<void> unbindStreamContext() async {
    _jobEpoch++;
    _seekDebounceTimer?.cancel();
    _seekDebounceTimer = null;
    _chunkProgressTimer?.cancel();
    _chunkProgressTimer = null;
    _resetAdaptivePipelineState();
    _isEnabled = false;
    await _detachPlayerListeners();
    await _cache.persistToDisk();

    _boundPlayer = null;
    _mediaItemId = null;
    _streamUrl = null;
    _httpHeaders = const {};
    _currentSegment = null;
    _lastBucketIndex = -1;
    _isProcessingChunk = false;
    _isInitializing = false;
    _statusMessage = null;

    await _disposeActiveEngine();
    await LocalHttpAudioRelay.instance.dispose();
    notifyListeners();
  }

  /// `[실험실] AI 실시간 자막 생성` 토글 ON/OFF 제어.
  Future<void> setEnabled(bool enable) async {
    if (_isEnabled == enable) return;
    _isEnabled = enable;

    if (!enable) {
      _jobEpoch++;
      _seekDebounceTimer?.cancel();
      _seekDebounceTimer = null;
      _chunkProgressTimer?.cancel();
      _chunkProgressTimer = null;
      _resetAdaptivePipelineState();
      await _detachPlayerListeners();
      await _cache.persistToDisk();
      _currentSegment = null;
      _lastBucketIndex = -1;
      _isInitializing = false;
      _isProcessingChunk = false;
      _initProgress = null;
      _statusMessage = null;
      await _disposeActiveEngine();
      notifyListeners();
      return;
    }

    _consecutiveErrors = 0;
    _consecutiveTranslationErrors = 0;
    _hasNotifiedPlatformMode = false;
    _hasNotifiedTranslationError = false;
    _hasNotifiedSlowCpuModel = false;
    _resetAdaptivePipelineState();
    _lastErrorMessage = null;
    await _keyStorage.loadApiKey();
    notifyListeners();

    final player = _boundPlayer;
    if (player != null) {
      _lastPosition = player.state.position;
      _lastIsPlaying = player.state.playing;
      _attachPlayerListeners(player);
      _evaluatePosition(_lastPosition);
    }
  }

  /// 엔진, 원본 언어, 표시 모드 등 설정 변경.
  Future<void> updateConfig(AiSubtitleConfig nextConfig) async {
    final engineChanged = _config.engineType != nextConfig.engineType;
    final languageChanged = _config.sourceLanguage != nextConfig.sourceLanguage;
    final tierChanged = _config.modelTier != nextConfig.modelTier;
    final cloudModelChanged =
        _config.cloudModelName != nextConfig.cloudModelName;
    _config = nextConfig;

    if (engineChanged || languageChanged || tierChanged || cloudModelChanged) {
      _jobEpoch++;
      _seekDebounceTimer?.cancel();
      _seekDebounceTimer = null;
      _currentSegment = null;
      _lastBucketIndex = -1;
      _consecutiveErrors = 0;
      _consecutiveTranslationErrors = 0;
      _hasNotifiedPlatformMode = false;
      _hasNotifiedTranslationError = false;
      _hasNotifiedSlowCpuModel = false;
      _resetAdaptivePipelineState();
      await _cache.persistToDisk();

      _recreateCacheIfBucketSizeChanged();

      if (_mediaItemId != null) {
        await _cache.switchContext(
          mediaItemId: _mediaItemId!,
          sourceLanguage: _config.sourceLanguage,
          engineKey: _config.engineType.code,
        );
      }

      if ((engineChanged || tierChanged || cloudModelChanged) &&
          _injectedEngine == null) {
        await _disposeActiveEngine();
      } else if (languageChanged &&
          _engine is OnDeviceSubtitleEngine &&
          _isEngineInitialized) {
        await (_engine as OnDeviceSubtitleEngine).updateLanguages(
          sourceLanguage: _config.sourceLanguage,
          targetLanguage: _config.targetLanguage,
        );
      }

      if (_isEnabled && _boundPlayer != null) {
        _evaluatePosition(_boundPlayer!.state.position);
      } else if (_isEnabled && _streamUrl != null) {
        _scheduleWindowIfNeeded(_currentPlaybackPosition());
      }
    }
    notifyListeners();
  }

  /// 현재까지 캐싱된 AI 자막을 `.srt` 문자열로 내보냅니다.
  String exportCachedSubtitlesAsSrt({AiSubtitleDisplayMode? displayMode}) {
    return _cache.exportAsSrt(
      displayMode: displayMode ?? _config.displayMode,
    );
  }

  void _recreateCacheIfBucketSizeChanged() {
    final desiredChunkSec = _config.effectiveChunkSeconds;
    if (_cache.chunkSeconds != desiredChunkSec) {
      _cache = SubtitleSegmentCache(chunkSeconds: desiredChunkSec);
    }
  }

  /// Read-Only 테스트 및 직접 위치 평가용 엔트리포인트.
  @visibleForTesting
  void setStreamContextForTesting({
    required String mediaItemId,
    required String streamUrl,
    Map<String, String> httpHeaders = const {},
  }) {
    _mediaItemId = mediaItemId;
    _streamUrl = streamUrl;
    _httpHeaders = Map<String, String>.from(httpHeaders);
  }

  /// Read-Only 테스트 및 직접 위치 평가용 엔트리포인트.
  @visibleForTesting
  void processPositionUpdate(
    Duration position, {
    bool isBuffering = false,
    bool isPlaying = true,
  }) {
    if (!_isEnabled) return;
    _lastIsPlaying = isPlaying;
    _evaluatePosition(
      position,
      isBuffering: isBuffering,
      isPlaying: isPlaying,
    );
  }

  void _attachPlayerListeners(Player player) {
    _positionSub?.cancel();
    _bufferingSub?.cancel();
    _playingSub?.cancel();

    _positionSub = player.stream.position.listen((pos) {
      if (!_isEnabled) return;
      _evaluatePosition(
        pos,
        isBuffering: player.state.buffering,
        isPlaying: player.state.playing,
      );
    });

    _bufferingSub = player.stream.buffering.listen((buffering) {
      if (!_isEnabled) return;
      if (!buffering &&
          player.state.playing &&
          _seekDebounceTimer?.isActive != true) {
        _scheduleWindowIfNeeded(_lastPosition);
      }
    });

    _playingSub = player.stream.playing.listen((isPlaying) {
      if (!_isEnabled) return;
      _lastIsPlaying = isPlaying;
      if (!isPlaying) {
        // 일시정지 시 대기 중인 Seek 디바운스 타이머를 취소해 불필요한 API 호출 차단
        _seekDebounceTimer?.cancel();
        return;
      }
      if (!player.state.buffering && _seekDebounceTimer?.isActive != true) {
        _scheduleWindowIfNeeded(_lastPosition);
      }
    });
  }

  Future<void> _detachPlayerListeners() async {
    await _positionSub?.cancel();
    _positionSub = null;
    await _bufferingSub?.cancel();
    _bufferingSub = null;
    await _playingSub?.cancel();
    _playingSub = null;
  }

  bool _isPlayerCurrentlyPlaying() {
    final player = _boundPlayer;
    if (player != null) return player.state.playing;
    return _lastIsPlaying;
  }

  bool _isPlayerCurrentlyBuffering() {
    final player = _boundPlayer;
    if (player != null) return player.state.buffering;
    return false;
  }

  void _evaluatePosition(
    Duration position, {
    bool? isBuffering,
    bool? isPlaying,
  }) {
    final prevPosition = _lastPosition;
    final prevBucket = _lastBucketIndex;
    final nextBucket = _cache.bucketIndexFor(position);
    _lastPosition = position;
    _updateCurrentSegment(position);

    final currentlyPlaying = isPlaying ?? _isPlayerCurrentlyPlaying();
    final currentlyBuffering = isBuffering ?? _isPlayerCurrentlyBuffering();

    // 일시정지 상태에서는 이미 캐시된 자막만 표시하고 신규 API/추론 호출을 차단
    if (!currentlyPlaying) {
      _lastBucketIndex = nextBucket;
      return;
    }

    final jumpedBySeek = prevBucket != -1 &&
        ((nextBucket - prevBucket).abs() > 1 ||
            (position - prevPosition).abs() > const Duration(seconds: 3));

    if (jumpedBySeek) {
      _lastBucketIndex = nextBucket;
      // 진행 중인 다른 구간의 비동기 요청/추출 취소 후 1.8초 디바운싱 적용
      if (_usesAdaptiveWhisperPipeline ||
          _cache.getState(nextBucket) != ChunkProcessState.completed) {
        _jobEpoch++;
        _resetAdaptivePipelineState();
        unawaited(_engine?.cancelCurrentJob());
      }
      _seekDebounceTimer?.cancel();
      _seekDebounceTimer = Timer(seekDebounceDuration, () {
        if (!_isEnabled) return;
        if (!_isPlayerCurrentlyPlaying() || _isPlayerCurrentlyBuffering()) {
          return;
        }
        _scheduleWindowIfNeeded(_lastPosition);
      });
      return;
    }

    _lastBucketIndex = nextBucket;
    if (currentlyBuffering || _seekDebounceTimer?.isActive == true) {
      return;
    }
    _scheduleWindowIfNeeded(position);
  }

  void _updateCurrentSegment(Duration position) {
    final found = _cache.findAt(position);
    if (found != _currentSegment) {
      _currentSegment = found;
      notifyListeners();
    }
  }

  bool get _usesAdaptiveWhisperPipeline {
    if (useAdaptiveStreamingOverride != null) {
      return useAdaptiveStreamingOverride!;
    }
    final isLocalWhisperEngine =
        _config.engineType == AiSubtitleEngineType.freeHybrid ||
            _config.engineType == AiSubtitleEngineType.onDevice;
    return isLocalWhisperEngine && _injectedEngine == null;
  }

  Duration _currentPlaybackPosition() {
    if (currentPositionOverride != null) {
      return currentPositionOverride!();
    }
    return _boundPlayer?.state.position ?? _lastPosition;
  }

  bool _isChunkStale(Duration chunkStart, Duration chunkDuration) {
    final curPos = _currentPlaybackPosition();
    return curPos >= chunkStart + chunkDuration;
  }

  Duration _futureLeadStart(Duration curPos) {
    final lead =
        curPos + const Duration(seconds: AiSubtitleConfig.staleSkipLeadSeconds);
    return Duration(seconds: lead.inSeconds);
  }

  void _resetAdaptivePipelineState() {
    _adaptiveCursor = null;
    _isFirstAdaptiveChunk = true;
    final pending = _pendingPreExtracted;
    _pendingPreExtracted = null;
    if (pending != null) {
      pending.cancelled = true;
      unawaited(pending.disposeTempFile());
    }
  }

  void _scheduleWindowIfNeeded(Duration position) {
    if (!_isEnabled) return;
    if (_streamUrl == null || _mediaItemId == null) return;
    if (!_isPlayerCurrentlyPlaying() || _isPlayerCurrentlyBuffering()) return;
    if (_seekDebounceTimer?.isActive == true) return;

    // 단일 워커 큐(Serial Queue): 현재 epoch 워커가 실행 중이거나 이미 대기 중이면 중복 실행 차단
    if (_isSchedulerRunning && _runningSchedulerEpoch == _jobEpoch) {
      return;
    }
    if (_queuedSchedulerEpoch == _jobEpoch) {
      return;
    }

    final scheduledEpoch = _jobEpoch;
    _queuedSchedulerEpoch = scheduledEpoch;
    _serialWorkerChain = _serialWorkerChain.then((_) async {
      if (_queuedSchedulerEpoch == scheduledEpoch) {
        _queuedSchedulerEpoch = null;
      }
      if (!_isEnabled || scheduledEpoch != _jobEpoch) return;
      if (_streamUrl == null || _mediaItemId == null) return;
      if (!_isPlayerCurrentlyPlaying() || _isPlayerCurrentlyBuffering()) return;
      if (_seekDebounceTimer?.isActive == true) return;
      await _runSchedulerLoop(_lastPosition);
    });
  }

  Future<void> _runSchedulerLoop(Duration initialPosition) async {
    if (_isSchedulerRunning) return;
    final epoch = _jobEpoch;
    _isSchedulerRunning = true;
    _runningSchedulerEpoch = epoch;

    try {
      final engineOk = await _ensureEngineReady();
      if (!engineOk || !_isEnabled || epoch != _jobEpoch) return;

      if (!_hasNotifiedPlatformMode) {
        _hasNotifiedPlatformMode = true;
        if (_config.engineType == AiSubtitleEngineType.onDevice &&
            !isTranslationSupported) {
          onNotification?.call(
            'Windows 로컬 오프라인 모드는 한국어 번역이 지원되지 않아 원어 자막으로 표시됩니다. (한국어 번역은 온라인 무료 또는 클라우드 AI 선택)',
            isWarning: _config.displayMode == AiSubtitleDisplayMode.koreanOnly,
          );
        }
      }

      if (_usesAdaptiveWhisperPipeline) {
        await _runAdaptiveWhisperLoop(epoch);
        return;
      }

      final lookahead = _config.effectiveLookaheadChunks;

      // 클라우드 API 또는 테스트용 주입 엔진: 기존 버킷 단위 순차 처리
      while (_isEnabled && epoch == _jobEpoch) {
        if (_engine == null || !_isEngineInitialized) break;
        if (!_isPlayerCurrentlyPlaying() || _isPlayerCurrentlyBuffering()) {
          break;
        }
        if (_seekDebounceTimer?.isActive == true) break;

        final curPos = _currentPlaybackPosition();
        final baseBucket = _cache.bucketIndexFor(curPos);

        int? targetBucket;
        for (var offset = 0; offset <= lookahead; offset++) {
          final candidate = baseBucket + offset;
          if (_cache.isChunkProcessedOrActive(candidate)) {
            continue;
          }
          final state = _cache.getState(candidate);
          if (state == ChunkProcessState.unprocessed ||
              (state == ChunkProcessState.failed &&
                  _cache.getRetryCount(candidate) < 1)) {
            targetBucket = candidate;
            break;
          }
        }

        if (targetBucket == null) break;
        await _processSingleBucket(targetBucket, epoch);
      }
    } catch (e) {
      debugPrint('[AiSubtitleService] 스케줄러 예외 격리: $e');
    } finally {
      _isSchedulerRunning = false;
      _runningSchedulerEpoch = -1;
    }
  }

  Future<void> _runAdaptiveWhisperLoop(int epoch) async {
    while (_isEnabled && epoch == _jobEpoch) {
      final engine = _engine;
      final url = _streamUrl;
      final itemId = _mediaItemId;
      if (engine == null ||
          !_isEngineInitialized ||
          url == null ||
          itemId == null) {
        break;
      }
      if (!_isPlayerCurrentlyPlaying() || _isPlayerCurrentlyBuffering()) {
        break;
      }
      if (_seekDebounceTimer?.isActive == true) break;

      Duration chunkStart;
      Duration chunkDuration;
      String? preWavPath;

      final pending = _pendingPreExtracted;
      _pendingPreExtracted = null;

      if (pending != null) {
        final preFile = await pending.future;
        if (!_isEnabled || epoch != _jobEpoch || pending.cancelled) {
          await pending.disposeTempFile();
          break;
        }
        // 큐에서 꺼낸 청크가 이미 지나간 구간이면 Whisper 실행 없이 즉시 폐기
        if (_isChunkStale(pending.start, pending.duration)) {
          skippedStaleChunkCount++;
          debugPrint(
            '[AiSubtitleService] 선행 청크 Stale 폐기 (${pending.start.inSeconds}s~${(pending.start + pending.duration).inSeconds}s) -> +${AiSubtitleConfig.staleSkipLeadSeconds}s 미래 구간 점프',
          );
          await pending.disposeTempFile();
          _adaptiveCursor = _futureLeadStart(_currentPlaybackPosition());
          _isFirstAdaptiveChunk = false;
          continue;
        }
        chunkStart = pending.start;
        chunkDuration = pending.duration;
        if (preFile != null &&
            preFile.existsSync() &&
            preFile.lengthSync() > 44) {
          preWavPath = preFile.path;
        }
      } else {
        final curPos = _currentPlaybackPosition();
        if (_adaptiveCursor != null) {
          chunkStart = _adaptiveCursor!;
        } else {
          chunkStart = curPos <= const Duration(seconds: 3)
              ? Duration.zero
              : Duration(seconds: curPos.inSeconds);
        }
        chunkDuration = Duration(
          seconds: _isFirstAdaptiveChunk
              ? AiSubtitleConfig.initialShortChunkSeconds
              : AiSubtitleConfig.streamingChunkSeconds,
        );

        if (_isChunkStale(chunkStart, chunkDuration)) {
          skippedStaleChunkCount++;
          chunkStart = _futureLeadStart(curPos);
          chunkDuration = const Duration(
            seconds: AiSubtitleConfig.streamingChunkSeconds,
          );
          _isFirstAdaptiveChunk = false;
        }

        // 재생 위치보다 45초 이상 앞서 있으면 과도한 선행 추출 중단
        if (!_isFirstAdaptiveChunk &&
            chunkStart - curPos > const Duration(seconds: 45)) {
          break;
        }

        // 초기 청크 등 아직 선행 WAV가 없으면 먼저 추출한 뒤, STT와 다음 청크 추출을 중첩 실행
        if (_supportsPreExtraction(engine)) {
          final extracted = await _extractChunkToTemp(
            engine: engine,
            streamUrl: url,
            headers: _httpHeaders,
            start: chunkStart,
            duration: chunkDuration,
          );
          if (!_isEnabled || epoch != _jobEpoch) {
            if (extracted != null && extracted.existsSync()) {
              await extracted.delete().catchError((_) => extracted);
            }
            break;
          }
          if (_isChunkStale(chunkStart, chunkDuration)) {
            skippedStaleChunkCount++;
            if (extracted != null && extracted.existsSync()) {
              await extracted.delete().catchError((_) => extracted);
            }
            _adaptiveCursor = _futureLeadStart(_currentPlaybackPosition());
            _isFirstAdaptiveChunk = false;
            continue;
          }
          if (extracted != null &&
              extracted.existsSync() &&
              extracted.lengthSync() > 44) {
            preWavPath = extracted.path;
          }
        }
      }

      // 다음 30초 청크 백그라운드 선행 추출 시작 (Whisper 연산과 병렬 수행)
      final nextStart = chunkStart + chunkDuration;
      const nextDuration = Duration(
        seconds: AiSubtitleConfig.streamingChunkSeconds,
      );
      if (_supportsPreExtraction(engine) &&
          nextStart - _currentPlaybackPosition() <=
              const Duration(seconds: 45)) {
        _startBackgroundPreExtract(
          engine: engine,
          streamUrl: url,
          headers: _httpHeaders,
          start: nextStart,
          duration: nextDuration,
          epoch: epoch,
        );
      }

      final outcome = await _processAdaptiveChunk(
        chunkStart: chunkStart,
        chunkDuration: chunkDuration,
        preExtractedWavPath: preWavPath,
        epoch: epoch,
      );

      if (!_isEnabled || epoch != _jobEpoch) {
        _resetAdaptivePipelineState();
        break;
      }

      _isFirstAdaptiveChunk = false;
      if (outcome == _AdaptiveChunkOutcome.skippedStale) {
        final stalePending = _pendingPreExtracted;
        if (stalePending != null &&
            _isChunkStale(stalePending.start, stalePending.duration)) {
          _pendingPreExtracted = null;
          stalePending.cancelled = true;
          unawaited(stalePending.disposeTempFile());
        }
        _adaptiveCursor = _futureLeadStart(_currentPlaybackPosition());
      } else if (outcome == _AdaptiveChunkOutcome.completed) {
        _adaptiveCursor = nextStart;
      } else {
        _adaptiveCursor = nextStart;
      }
    }
  }

  bool _supportsPreExtraction(SubtitleGeneratorEngine engine) {
    return engine is FreeHybridSubtitleEngine ||
        engine is OnDeviceSubtitleEngine;
  }

  Future<File?> _extractChunkToTemp({
    required SubtitleGeneratorEngine engine,
    required String streamUrl,
    required Map<String, String> headers,
    required Duration start,
    required Duration duration,
  }) async {
    try {
      final dir = Directory('${Directory.systemTemp.path}/ai_sub_pre_chunks');
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      final outPath =
          '${dir.path}/chunk_${start.inMilliseconds}_${++_preExtractSeq}.wav';
      if (engine is FreeHybridSubtitleEngine) {
        return await engine.preExtractAudioChunk(
          streamUrl: streamUrl,
          httpHeaders: headers,
          start: start,
          duration: duration,
          outputWavPath: outPath,
        );
      }
      if (engine is OnDeviceSubtitleEngine) {
        return await engine.preExtractAudioChunk(
          streamUrl: streamUrl,
          httpHeaders: headers,
          start: start,
          duration: duration,
          outputWavPath: outPath,
        );
      }
    } catch (e) {
      debugPrint('[AiSubtitleService] 오디오 청크 추출 실패(폴백 진행): $e');
    }
    return null;
  }

  void _startBackgroundPreExtract({
    required SubtitleGeneratorEngine engine,
    required String streamUrl,
    required Map<String, String> headers,
    required Duration start,
    required Duration duration,
    required int epoch,
  }) {
    if (_pendingPreExtracted != null) return;
    final dir = Directory('${Directory.systemTemp.path}/ai_sub_pre_chunks');
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    final outPath =
        '${dir.path}/pre_${start.inMilliseconds}_${++_preExtractSeq}.wav';
    final holder = _PreExtractedChunk(
      start: start,
      duration: duration,
      wavPath: outPath,
    );
    _pendingPreExtracted = holder;

    holder.future = (() async {
      try {
        if (!_isEnabled || epoch != _jobEpoch || holder.cancelled) return null;
        File file;
        if (engine is FreeHybridSubtitleEngine) {
          file = await engine.preExtractAudioChunk(
            streamUrl: streamUrl,
            httpHeaders: headers,
            start: start,
            duration: duration,
            outputWavPath: outPath,
          );
        } else if (engine is OnDeviceSubtitleEngine) {
          file = await engine.preExtractAudioChunk(
            streamUrl: streamUrl,
            httpHeaders: headers,
            start: start,
            duration: duration,
            outputWavPath: outPath,
          );
        } else {
          return null;
        }
        if (!_isEnabled || epoch != _jobEpoch || holder.cancelled) {
          if (file.existsSync()) {
            await file.delete().catchError((_) => file);
          }
          return null;
        }
        return file;
      } catch (e) {
        debugPrint('[AiSubtitleService] 백그라운드 선행 오디오 추출 무시: $e');
        await holder.disposeTempFile();
        return null;
      }
    })();
  }

  SubtitleGeneratorEngine _buildEngineForConfig(AiSubtitleConfig cfg) {
    if (_injectedEngine != null) return _injectedEngine;
    switch (cfg.engineType) {
      case AiSubtitleEngineType.cloudApi:
        final cachedKey = _keyStorage.cachedApiKey;
        if (_cloudEngineFactory != null) {
          return _cloudEngineFactory(cachedKey, cfg.cloudModelName);
        }
        return CloudAiSubtitleEngine(
          apiKeyProvider: () => _keyStorage.loadApiKey(),
          modelName: cfg.cloudModelName,
        );
      case AiSubtitleEngineType.freeHybrid:
        if (_freeHybridEngineFactory != null) {
          return _freeHybridEngineFactory(cfg.modelTier);
        }
        return FreeHybridSubtitleEngine(modelTier: cfg.modelTier);
      case AiSubtitleEngineType.onDevice:
        if (_onDeviceEngineFactory != null) {
          return _onDeviceEngineFactory(cfg.modelTier);
        }
        return OnDeviceSubtitleEngine(modelTier: cfg.modelTier);
    }
  }

  Future<bool> _ensureEngineReady() async {
    if (_engine != null && _isEngineInitialized) {
      return true;
    }

    _engine ??= _buildEngineForConfig(_config);

    // 클라우드 AI 선택 시 API Key 사전 검사 (미입력 시 즉시 명확한 안내 및 Fail-Safe)
    if (_config.engineType == AiSubtitleEngineType.cloudApi &&
        _injectedEngine == null) {
      final key = await _keyStorage.loadApiKey();
      if (key == null || key.isEmpty) {
        await _handleCloudFailSafe(
          const CloudAiException(
            CloudAiErrorType.missingApiKey,
            'Gemini API 키가 입력되지 않았습니다.',
          ),
        );
        return false;
      }
    }

    if (!await _engine!.isSupported()) {
      final eng = _engine!;
      String? detailedReason;
      if (eng is FreeHybridSubtitleEngine) {
        detailedReason = await eng.getUnsupportedReason();
      } else if (eng is OnDeviceSubtitleEngine) {
        detailedReason = await eng.getUnsupportedReason();
      } else if (eng is CloudAiSubtitleEngine) {
        detailedReason = await eng.getUnsupportedReason();
      }
      final msg = detailedReason ??
          switch (_config.engineType) {
            AiSubtitleEngineType.cloudApi =>
              '현재 환경에서 클라우드 AI 오디오 추출 모듈을 사용할 수 없습니다.',
            AiSubtitleEngineType.freeHybrid =>
              '현재 기기에서 온라인 무료 Whisper 자막 엔진을 지원하지 않습니다.',
            AiSubtitleEngineType.onDevice =>
              '현재 기기에서 로컬 오프라인 AI 엔진을 지원하지 않습니다.',
          };
      _lastErrorMessage = msg;
      _statusMessage = msg;
      onNotification?.call('$msg 동영상 재생은 정상 유지됩니다.', isWarning: true);
      await setEnabled(false);
      return false;
    }

    _isInitializing = true;
    _statusMessage = switch (_config.engineType) {
      AiSubtitleEngineType.cloudApi => '클라우드 AI 자막 준비 중...',
      AiSubtitleEngineType.freeHybrid =>
        '온라인 무료 Whisper (${_config.modelTier.shortName}) 준비 중...',
      AiSubtitleEngineType.onDevice =>
        '로컬 오프라인 Whisper (${_config.modelTier.shortName}) 준비 중...',
    };
    notifyListeners();

    try {
      final eng = _engine!;
      if (eng is OnDeviceSubtitleEngine) {
        await eng.initialize(
          sourceLanguage: _config.sourceLanguage,
          targetLanguage: _config.targetLanguage,
          onProgress: (progress, status) {
            _initProgress = progress;
            _statusMessage = status;
            notifyListeners();
          },
        );
      } else {
        await eng.initialize(
          onProgress: (progress, status) {
            _initProgress = progress;
            _statusMessage = status;
            notifyListeners();
          },
        );
      }
      _isEngineInitialized = true;
      _isInitializing = false;
      _initProgress = null;
      _statusMessage = null;
      _lastErrorMessage = null;
      notifyListeners();
      return true;
    } on CloudAiException catch (e) {
      _isEngineInitialized = false;
      _isInitializing = false;
      _initProgress = null;
      _statusMessage = null;
      await _handleCloudFailSafe(e);
      return false;
    } catch (e) {
      debugPrint('[AiSubtitleService] 엔진 초기화 실패(재생 유지): $e');
      _isEngineInitialized = false;
      _isInitializing = false;
      _initProgress = null;
      _statusMessage = null;
      _lastErrorMessage = 'AI 모델 준비에 실패했습니다. 동영상 재생은 정상 유지됩니다.';
      onNotification?.call(
        _lastErrorMessage!,
        isWarning: true,
      );
      await setEnabled(false);
      return false;
    }
  }

  Future<void> _processSingleBucket(int bucketIndex, int epoch) async {
    final engine = _engine;
    final url = _streamUrl;
    final itemId = _mediaItemId;
    if (engine == null || url == null || itemId == null) return;
    if (_cache.isChunkProcessedOrActive(bucketIndex)) return;

    _cache.markProcessing(bucketIndex);
    _isProcessingChunk = true;
    _activeChunkWorkers++;
    if (_activeChunkWorkers > maxConcurrentChunkWorkersObserved) {
      maxConcurrentChunkWorkersObserved = _activeChunkWorkers;
    }
    final usesLocalWhisper = _config.engineType != AiSubtitleEngineType.cloudApi;
    final modelLabel = usesLocalWhisper
        ? _config.modelTier.shortName
        : _config.cloudModelName;
    final chunkSw = Stopwatch()..start();
    _statusMessage = 'AI 자막 분석 중 ($modelLabel)...';
    _chunkProgressTimer?.cancel();
    _chunkProgressTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!_isEnabled || !_isProcessingChunk) return;
      final elapsedSec = chunkSw.elapsed.inSeconds;
      if (epoch != _jobEpoch) {
        _statusMessage = '이전 분석 마무리 후 새 구간 적용 중 ($elapsedSec초)...';
      } else if (_isWindowsCpuHeavyWhisper() && elapsedSec >= 25) {
        _statusMessage =
            '$modelLabel 분석 중 ($elapsedSec초)... (실시간은 Small/Small Q5_1/Tiny 권장)';
        _notifySlowCpuModelOnce(
          elapsedSec: elapsedSec,
          chunkSec: _config.effectiveChunkSeconds,
        );
      } else {
        _statusMessage = 'AI 자막 분석 중 ($modelLabel · $elapsedSec초)...';
      }
      notifyListeners();
    });
    notifyListeners();

    final req = AudioChunkRequest(
      mediaItemId: itemId,
      streamUrl: url,
      httpHeaders: _httpHeaders,
      chunkStart: _cache.bucketStartFor(bucketIndex),
      chunkDuration: _cache.bucketDuration(),
      sourceLanguage: _config.sourceLanguage,
      targetLanguage: _config.targetLanguage,
    );

    var yieldedCount = 0;
    var translatedCount = 0;

    try {
      await for (final segment in engine.generateSubtitlesForChunk(req)) {
        if (!_isEnabled || epoch != _jobEpoch) {
          _cache.resetProcessingToUnprocessed(bucketIndex);
          return;
        }
        yieldedCount++;
        if ((segment.translatedText ?? '').trim().isNotEmpty) {
          translatedCount++;
        }
        _cache.insertSegment(bucketIndex, segment);
        _updateCurrentSegment(_currentPlaybackPosition());
      }
      if (!_isEnabled || epoch != _jobEpoch) {
        _cache.resetProcessingToUnprocessed(bucketIndex);
        return;
      }
      _cache.markCompleted(bucketIndex);
      _consecutiveErrors = 0;
      if (_isWindowsCpuHeavyWhisper() &&
          chunkSw.elapsed.inSeconds > _config.effectiveChunkSeconds) {
        _notifySlowCpuModelOnce(
          elapsedSec: chunkSw.elapsed.inSeconds,
          chunkSec: _config.effectiveChunkSeconds,
        );
      }
      if (engine is FreeHybridSubtitleEngine) {
        await _handleFreeHybridTranslationOutcome(
          engine: engine,
          yieldedCount: yieldedCount,
          translatedCount: translatedCount,
        );
      } else if (!_hasNotifiedTranslationError &&
          engine is OnDeviceSubtitleEngine &&
          engine.isTranslationSupported &&
          engine.lastTranslationError != null) {
        _hasNotifiedTranslationError = true;
        final rawErr = engine.lastTranslationError!;
        final shortErr =
            rawErr.length > 120 ? '${rawErr.substring(0, 120)}...' : rawErr;
        onNotification?.call(
          '온디바이스 한국어 번역 모델 준비에 실패해 원어 자막으로 표시됩니다. ($shortErr)',
          isWarning: true,
        );
      }
      unawaited(_cache.persistToDisk());
    } on CloudAiException catch (e) {
      if (e.type == CloudAiErrorType.cancelled ||
          !_isEnabled ||
          epoch != _jobEpoch) {
        _cache.resetProcessingToUnprocessed(bucketIndex);
        return;
      }
      debugPrint('[AiSubtitleService] 클라우드 AI 청크 #$bucketIndex 오류: $e');
      _cache.markFailed(bucketIndex);

      if (e.type == CloudAiErrorType.missingApiKey ||
          e.type == CloudAiErrorType.invalidApiKey ||
          e.type == CloudAiErrorType.quotaExceeded) {
        await _handleCloudFailSafe(e);
        return;
      }

      _consecutiveErrors++;
      if (_consecutiveErrors >= _maxConsecutiveErrors) {
        await _handleCloudFailSafe(e);
      }
    } catch (e) {
      if (!_isEnabled || epoch != _jobEpoch) {
        _cache.resetProcessingToUnprocessed(bucketIndex);
        return;
      }
      debugPrint('[AiSubtitleService] 청크 #$bucketIndex 처리 실패(조용히 스킵): $e');
      _cache.markFailed(bucketIndex);
      _consecutiveErrors++;

      if (_consecutiveErrors >= _maxConsecutiveErrors) {
        onNotification?.call(
          '현재 스트림에서 AI 오디오 분석이 연속 제한되어 실험 기능을 일시 중지했습니다.',
          isWarning: true,
        );
        await setEnabled(false);
      }
    } finally {
      _activeChunkWorkers--;
      _chunkProgressTimer?.cancel();
      _chunkProgressTimer = null;
      _isProcessingChunk = false;
      if (!_isInitializing) {
        _statusMessage = null;
      }
      notifyListeners();
    }
  }

  Future<_AdaptiveChunkOutcome> _processAdaptiveChunk({
    required Duration chunkStart,
    required Duration chunkDuration,
    required String? preExtractedWavPath,
    required int epoch,
  }) async {
    final engine = _engine;
    final url = _streamUrl;
    final itemId = _mediaItemId;
    if (engine == null || url == null || itemId == null) {
      return _AdaptiveChunkOutcome.cancelled;
    }

    _isProcessingChunk = true;
    _activeChunkWorkers++;
    if (_activeChunkWorkers > maxConcurrentChunkWorkersObserved) {
      maxConcurrentChunkWorkersObserved = _activeChunkWorkers;
    }

    final modelLabel = _config.modelTier.shortName;
    final chunkSw = Stopwatch()..start();
    _statusMessage = 'AI 자막 분석 중 ($modelLabel)...';
    _chunkProgressTimer?.cancel();
    _chunkProgressTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!_isEnabled || !_isProcessingChunk) return;
      final elapsedSec = chunkSw.elapsed.inSeconds;
      if (epoch != _jobEpoch) {
        _statusMessage = '이전 분석 마무리 후 새 구간 적용 중 ($elapsedSec초)...';
      } else if (_isWindowsCpuHeavyWhisper() && elapsedSec >= 25) {
        _statusMessage =
            '$modelLabel 분석 중 ($elapsedSec초)... (실시간은 Small/Small Q5_1/Tiny 권장)';
        _notifySlowCpuModelOnce(
          elapsedSec: elapsedSec,
          chunkSec: chunkDuration.inSeconds,
        );
      } else {
        _statusMessage = 'AI 자막 분석 중 ($modelLabel · $elapsedSec초)...';
      }
      notifyListeners();
    });
    notifyListeners();

    var skippedBeforeWhisper = false;
    final req = AudioChunkRequest(
      mediaItemId: itemId,
      streamUrl: url,
      httpHeaders: _httpHeaders,
      chunkStart: chunkStart,
      chunkDuration: chunkDuration,
      sourceLanguage: _config.sourceLanguage,
      targetLanguage: _config.targetLanguage,
      preExtractedWavPath: preExtractedWavPath,
      shouldSkipBeforeTranscribe: () {
        final stale = _isChunkStale(chunkStart, chunkDuration);
        if (stale) {
          skippedBeforeWhisper = true;
        }
        return stale;
      },
    );

    var yieldedCount = 0;
    var translatedCount = 0;

    try {
      await for (final segment in engine.generateSubtitlesForChunk(req)) {
        if (!_isEnabled || epoch != _jobEpoch) {
          return _AdaptiveChunkOutcome.cancelled;
        }
        yieldedCount++;
        if ((segment.translatedText ?? '').trim().isNotEmpty) {
          translatedCount++;
        }
        final segBucket = _cache.bucketIndexFor(segment.startTime);
        _cache.insertSegment(segBucket, segment);
        _cache.markCompleted(segBucket);
        _updateCurrentSegment(_currentPlaybackPosition());
      }

      if (!_isEnabled || epoch != _jobEpoch) {
        return _AdaptiveChunkOutcome.cancelled;
      }

      if (skippedBeforeWhisper ||
          (yieldedCount == 0 && _isChunkStale(chunkStart, chunkDuration))) {
        skippedStaleChunkCount++;
        return _AdaptiveChunkOutcome.skippedStale;
      }

      _consecutiveErrors = 0;
      if (_isWindowsCpuHeavyWhisper() &&
          chunkSw.elapsed.inSeconds > chunkDuration.inSeconds) {
        _notifySlowCpuModelOnce(
          elapsedSec: chunkSw.elapsed.inSeconds,
          chunkSec: chunkDuration.inSeconds,
        );
      }

      if (engine is FreeHybridSubtitleEngine) {
        await _handleFreeHybridTranslationOutcome(
          engine: engine,
          yieldedCount: yieldedCount,
          translatedCount: translatedCount,
        );
      } else if (!_hasNotifiedTranslationError &&
          engine is OnDeviceSubtitleEngine &&
          engine.isTranslationSupported &&
          engine.lastTranslationError != null) {
        _hasNotifiedTranslationError = true;
        final rawErr = engine.lastTranslationError!;
        final shortErr =
            rawErr.length > 120 ? '${rawErr.substring(0, 120)}...' : rawErr;
        onNotification?.call(
          '온디바이스 한국어 번역 모델 준비에 실패해 원어 자막으로 표시됩니다. ($shortErr)',
          isWarning: true,
        );
      }
      unawaited(_cache.persistToDisk());
      return _AdaptiveChunkOutcome.completed;
    } catch (e) {
      if (!_isEnabled || epoch != _jobEpoch) {
        return _AdaptiveChunkOutcome.cancelled;
      }
      debugPrint(
        '[AiSubtitleService] 적응형 청크(${chunkStart.inSeconds}s) 처리 실패(스킵): $e',
      );
      _consecutiveErrors++;
      if (_consecutiveErrors >= _maxConsecutiveErrors) {
        onNotification?.call(
          '현재 스트림에서 AI 오디오 분석이 연속 제한되어 실험 기능을 일시 중지했습니다.',
          isWarning: true,
        );
        await setEnabled(false);
      }
      return _AdaptiveChunkOutcome.failed;
    } finally {
      _activeChunkWorkers--;
      _chunkProgressTimer?.cancel();
      _chunkProgressTimer = null;
      _isProcessingChunk = false;
      if (!_isInitializing) {
        _statusMessage = null;
      }
      notifyListeners();
    }
  }

  bool _isWindowsCpuHeavyWhisper() {
    if (_config.engineType == AiSubtitleEngineType.cloudApi) return false;
    final isWin = isWindowsPlatformOverride ??
        defaultTargetPlatform == TargetPlatform.windows;
    if (!isWin) return false;
    return _config.modelTier == AiWhisperModelTier.largeV3TurboQ5;
  }

  void _notifySlowCpuModelOnce({
    required int elapsedSec,
    required int chunkSec,
  }) {
    if (_hasNotifiedSlowCpuModel) return;
    _hasNotifiedSlowCpuModel = true;
    onNotification?.call(
      '${_config.modelTier.shortName} 모델 처리 시간($elapsedSec초+)이 재생 구간($chunkSec초)보다 길어 실시간 번역이 지연됩니다. 기본 추천 모델(Small / Small Q5_1) 또는 Tiny 사용을 권장합니다.',
      isWarning: true,
    );
  }

  /// 클라우드 AI 실패 시 재생을 절대 멈추지 않고 안전 중단 또는 온디바이스 폴백 수행.
  Future<void> _handleCloudFailSafe(CloudAiException error) async {
    switch (error.type) {
      case CloudAiErrorType.missingApiKey:
        onNotification?.call(
          'Gemini API 키가 설정되지 않았습니다. 자막 설정에서 API 키를 입력해 주세요.',
          isWarning: true,
        );
        await setEnabled(false);
        return;

      case CloudAiErrorType.invalidApiKey:
        onNotification?.call(
          'Gemini API 키가 유효하지 않아 클라우드 AI 자막을 중지했습니다.',
          isWarning: true,
        );
        await setEnabled(false);
        return;

      case CloudAiErrorType.quotaExceeded:
        if (_injectedEngine == null) {
          final onDeviceEngine = _onDeviceEngineFactory != null
              ? _onDeviceEngineFactory(_config.modelTier)
              : OnDeviceSubtitleEngine(modelTier: _config.modelTier);
          if (await onDeviceEngine.isSupported()) {
            await onDeviceEngine.dispose();
            onNotification?.call(
              'Gemini API 할당량(Quota)을 초과하여 로컬 온디바이스 모드로 전환합니다.',
              isWarning: true,
            );
            await _switchEngineFallback(AiSubtitleEngineType.onDevice);
            return;
          }
          await onDeviceEngine.dispose();
        }
        onNotification?.call(
          'Gemini API 할당량(Quota)을 초과하여 AI 자막을 안전하게 중지했습니다.',
          isWarning: true,
        );
        await setEnabled(false);
        return;

      case CloudAiErrorType.networkError:
      case CloudAiErrorType.audioExtractionFailed:
      case CloudAiErrorType.invalidResponse:
        onNotification?.call(
          '${error.message} AI 자막을 안전하게 중지했습니다. (재생은 정상 유지)',
          isWarning: true,
        );
        await setEnabled(false);
        return;

      case CloudAiErrorType.cancelled:
        return;
    }
  }

  Future<void> _handleFreeHybridTranslationOutcome({
    required FreeHybridSubtitleEngine engine,
    required int yieldedCount,
    required int translatedCount,
  }) async {
    final err = engine.lastTranslationError;
    if (err == null) {
      if (yieldedCount > 0 && translatedCount > 0) {
        _consecutiveTranslationErrors = 0;
      }
      return;
    }

    if (yieldedCount > 0 && translatedCount == 0) {
      _consecutiveTranslationErrors++;
      if (!_hasNotifiedTranslationError) {
        _hasNotifiedTranslationError = true;
        onNotification?.call(
          '오프라인 상태이거나 무료 번역 요청에 실패해 원어 자막만 표시합니다. (재생은 정상 유지)',
          isWarning: true,
        );
      }

      final mobileMlKitSupported = translationSupportedOverride ??
          SubtitleTranslator.create().isTranslationSupported;
      if (_consecutiveTranslationErrors >= 2 &&
          mobileMlKitSupported &&
          _injectedEngine == null) {
        final onDeviceEngine = _onDeviceEngineFactory != null
            ? _onDeviceEngineFactory(_config.modelTier)
            : OnDeviceSubtitleEngine(modelTier: _config.modelTier);
        if (await onDeviceEngine.isSupported()) {
          await onDeviceEngine.dispose();
          onNotification?.call(
            '오프라인 상태가 지속되어 로컬 오프라인 (ML Kit) 모드로 자동 전환합니다.',
            isWarning: true,
          );
          await _switchEngineFallback(AiSubtitleEngineType.onDevice);
          return;
        }
        await onDeviceEngine.dispose();
      }
    }
  }

  Future<void> _switchEngineFallback(AiSubtitleEngineType targetEngine) async {
    _jobEpoch++;
    await _disposeActiveEngine();
    final fallbackCfg = _config.copyWith(engineType: targetEngine);
    _config = fallbackCfg;
    _recreateCacheIfBucketSizeChanged();
    if (_mediaItemId != null) {
      await _cache.switchContext(
        mediaItemId: _mediaItemId!,
        sourceLanguage: _config.sourceLanguage,
        engineKey: _config.engineType.code,
      );
    }
    _consecutiveErrors = 0;
    _consecutiveTranslationErrors = 0;
    _hasNotifiedPlatformMode = true;
    onConfigFallback?.call(fallbackCfg);
    notifyListeners();
    scheduleMicrotask(() => _scheduleWindowIfNeeded(_lastPosition));
  }

  Future<void> _disposeActiveEngine() async {
    _isEngineInitialized = false;
    final eng = _engine;
    _engine = null;
    if (eng != null) {
      try {
        await eng.dispose();
      } catch (e) {
        debugPrint('[AiSubtitleService] 엔진 해제 경고(무시): $e');
      }
    }
  }
}

enum _AdaptiveChunkOutcome {
  completed,
  skippedStale,
  cancelled,
  failed,
}

class _PreExtractedChunk {
  final Duration start;
  final Duration duration;
  final String wavPath;
  bool cancelled = false;
  Future<File?> future = Future<File?>.value(null);

  _PreExtractedChunk({
    required this.start,
    required this.duration,
    required this.wavPath,
  });

  Future<void> disposeTempFile() async {
    try {
      final f = File(wavPath);
      if (f.existsSync()) {
        await f.delete();
      }
    } catch (_) {}
  }
}
