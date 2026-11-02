import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:audio_session/audio_session.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:flutter_volume_controller/flutter_volume_controller.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';
import 'package:provider/provider.dart';
import '../../models/cloud_account.dart';
import '../../models/media_item.dart';
import '../../models/player_orientation_mode.dart';
import '../../models/video_quality.dart';
import '../../services/account_manager.dart';
import '../../services/cloud_playback_sync_service.dart';
import '../../services/cloud_service_interface.dart';
import '../../services/local_stream_proxy.dart';
import '../../services/playback_history_service.dart';
import '../../services/subtitle_settings_service.dart';
import '../../utils/platform_utils.dart';
import '../../utils/subtitle_utils.dart';
import '../widgets/subtitle_dialog.dart';
import '../widgets/custom_subtitle_view.dart';

class PlayerScreen extends StatefulWidget {
  final MediaItem item;
  final CloudService service;

  const PlayerScreen({
    super.key,
    required this.item,
    required this.service,
  });

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> with WidgetsBindingObserver {
  late Player _player;
  late VideoController _controller;
  Player? _standbyPlayer;
  VideoController? _standbyController;
  bool _isStandbyFrameReady = false;
  int _switchQualityToken = 0;
  Uint8List? _freezeFrameBytes;
  String? _activeProxyStreamUrl;

  bool _isLoading = true;
  String? _errorMessage;
  bool _showControls = true;
  Timer? _hideControlsTimer;
  double _playbackSpeed = 1.0;
  Duration _totalDuration = Duration.zero;
  Duration? _dragPosition;
  bool _isFullScreen = !Platform.isWindows && !Platform.isLinux && !Platform.isMacOS;
  PlayerOrientationMode _orientationMode = PlayerOrientationMode.landscape;

  StreamSubscription? _autoPlaySub;
  StreamSubscription? _tracksSub;
  StreamSubscription? _completedSub;
  StreamSubscription? _positionSub;
  Timer? _positionSaveTimer;
  bool _hasAutoSelectedSubtitle = false;
  bool _hasResumed = false;

  // 재생/일시정지 즉각 반응용 낙관적 상태
  bool? _optimisticPlaying;
  Timer? _optimisticTimer;
  StreamSubscription? _optimisticClearSub;

  // 이전 재생 위치 이동 안내 상태
  Duration? _resumeSeekTarget;
  StreamSubscription? _resumeSeekSub;
  Timer? _resumeSeekTimeout;

  // 오디오 포커스 세션 관리 (유튜브 등 타 앱 오디오 제어)
  AudioSession? _audioSession;
  StreamSubscription? _interruptionSub;
  StreamSubscription? _becomingNoisySub;
  StreamSubscription? _playingSub;

  // 하드웨어 가속 상태 관리
  bool _isHwDec = true;

  // 비디오 스트리밍 화질 관리
  VideoQuality _currentQuality = VideoQuality.autoQuality;
  List<VideoQuality> _availableQualities = const [VideoQuality.original];
  bool _isSwitchingQuality = false;

  // 제스처 기반 비디오 콘트라스트(명암비) 및 볼륨 조절 상태
  double _contrast = 0.5; // UI 레벨 0.0~1.0 (0~100, 0.5 = 원본)
  double _gestureVolume = 100.0;
  bool _showContrastIndicator = false;
  bool _showVolumeIndicator = false;
  Timer? _gestureIndicatorTimer;
  bool _isDraggingLeft = false;
  bool _isDraggingRight = false;
  double? _doubleTapDownX; // 더블탭 위치(좌/우 10초 점프 판별용)

  // 이전 시청 시 사용한 자막 파일 및 언어 설정 기억 변수
  String? _currentSubtitleType;
  String? _currentSubtitleId;
  String? _currentSubtitleName;
  String? _currentSubtitleLanguage;
  File? _activeExternalSubtitleFile;
  bool _isApplyingSubtitle = false;
  Duration? _pendingSeekAfterSubtitle;
  SubtitleTrack? _pendingInitialSubtitleTrack;

  // 비디오 썸네일 캡처 상태
  bool _hasCapturedThumbnail = false;
  String? _localThumbnailPath;

  // 투명 알림 배너 상태 변수
  String? _bannerMessage;
  IconData? _bannerIcon;
  Color? _bannerIconColor;
  String? _bannerActionLabel;
  VoidCallback? _bannerAction;
  Timer? _bannerDismissTimer;

  StreamSubscription? _durationSub;

  Player _createConfiguredPlayer() {
    final player = Player(
      configuration: const PlayerConfiguration(
        bufferSize: 64 * 1024 * 1024,
      ),
    );
    _applyPlayerPlatformProperties(player);
    return player;
  }

  VideoController _createConfiguredController(Player player) {
    final videoConfig = Platform.isAndroid
        ? (PlatformUtils.isAndroidEmulator
            ? const VideoControllerConfiguration(
                vo: 'mediacodec_embed',
                hwdec: 'mediacodec',
              )
            : const VideoControllerConfiguration(
                hwdec: 'mediacodec',
              ))
        : const VideoControllerConfiguration();
    return VideoController(player, configuration: videoConfig);
  }

  Future<void> _applyPlayerPlatformProperties(Player player) async {
    try {
      final platform = (player.platform as dynamic);
      await platform?.setProperty('slang', 'ko,kor,korean,kr');
      await platform?.setProperty('sub-codepage', 'auto:cp949');
      await platform?.setProperty('demuxer-max-bytes', '67108864'); // 64MB 대용량 버퍼
      await platform?.setProperty('demuxer-max-back-bytes', '33554432'); // 32MB 역방향 캐시
      await platform?.setProperty('demuxer-readahead-secs', '30'); // 30초 선행 버퍼링
      await platform?.setProperty('cache', 'yes');
      await platform?.setProperty('cache-secs', '30');
      try {
        final cacheDir = Directory('${Directory.systemTemp.path}/mpv_cache');
        if (!cacheDir.existsSync()) cacheDir.createSync(recursive: true);
        await platform?.setProperty('cache-dir', cacheDir.path);
      } catch (_) {}
      await platform?.setProperty('network-timeout', '15');
      await platform?.setProperty('force-seekable', 'yes');
      await platform?.setProperty('hr-seek', 'yes');
      await platform?.setProperty('hr-seek-framedrop', 'yes');
      final hwValue = _isHwDec ? (Platform.isAndroid ? 'mediacodec' : 'auto') : 'no';
      await platform?.setProperty('hwdec', hwValue);

      final streamHeaders = await widget.service.getStreamHeaders();
      if (streamHeaders.isNotEmpty) {
        final headerString = streamHeaders.entries
            .map((e) => '${e.key}: ${e.value}')
            .join('\r\n');
        await platform?.setProperty('demuxer-lavf-o', 'headers=$headerString\r\n');
      }
    } catch (_) {}
  }

  void _bindPlayerStreams(Player player) {
    _durationSub?.cancel();
    _durationSub = player.stream.duration.listen((d) {
      if (d > Duration.zero && mounted) {
        setState(() {
          _totalDuration = d;
        });
      }
    });

    _tracksSub?.cancel();
    _tracksSub = player.stream.tracks.listen((tracks) {
      if (!mounted) return;

      final trackListLog = tracks.subtitle.map((t) => '[id=${t.id}, title=${t.title}, lang=${t.language}]').join(', ');
      debugPrint('[PlayerScreen] 자막 트랙 목록 갱신 (${tracks.subtitle.length}개): $trackListLog');

      // 1. 자막 끄기 설정이면 'no' 유지
      if (_currentSubtitleType == 'none') {
        if (player.state.track.subtitle.id != 'no') {
          player.setSubtitleTrack(SubtitleTrack.no());
        }
        return;
      }

      // 2. 초기 사전 다운로드된 외부 자막이 있으면 미디어 트랙 준비 완료 시점에 최우선 적용
      if (_pendingInitialSubtitleTrack != null) {
        final trackToApply = _pendingInitialSubtitleTrack!;
        final active = player.state.track.subtitle;
        // 이미 유효한 자막 트랙이 선택되어 있다면 덮어쓰지 않음
        if (active.id == 'no' || active.id == 'auto') {
          debugPrint('[PlayerScreen] 미디어 트랙 생성 완료 -> 초기 자막 적용 (${trackToApply.title})');
          player.setSubtitleTrack(trackToApply);
        }
        _pendingInitialSubtitleTrack = null;
        _hasAutoSelectedSubtitle = true;
        return;
      }

      // 3. SAMI/SMI 자막의 KRCC 가상 트랙이 mpv에 의해 생성되었는지 확인
      for (final track in tracks.subtitle) {
        final title = (track.title ?? '').toLowerCase();
        final lang = (track.language ?? '').toLowerCase();
        if (title.contains('krcc') || lang == 'ko' || lang == 'kor') {
          final active = player.state.track.subtitle;
          if (active.id != track.id) {
            debugPrint('[PlayerScreen] 한국어/SAMI KRCC 트랙 활성화: id=${track.id}, title=${track.title}, lang=${track.language}');
            player.setSubtitleTrack(track);
            _hasAutoSelectedSubtitle = true;
          }
          return;
        }
      }

      // 이미 자막 트랙이 선택되었거나 로드된 경우 중복 호출 차단
      if (_hasAutoSelectedSubtitle) return;

      // 4. 외부 자막(클라우드/로컬) 적용 상태인 경우: 일반 내장 트랙 오버라이드 방지
      if (_currentSubtitleType == 'cloud' || _currentSubtitleType == 'local') {
        return;
      }

      // 5. 내장 자막 복원 또는 한국어 트랙 자동 선택
      if (_currentSubtitleType == 'track') {
        _restoreTrackSubtitle(tracks.subtitle);
      } else if (_currentSubtitleType == null) {
        _selectKoreanTrack(tracks.subtitle);
      }
    });

    _completedSub?.cancel();
    _completedSub = player.stream.completed.listen((completed) {
      if (completed) {
        PlaybackHistoryService.instance.clearPosition(
          accountId: widget.service.account.id,
          item: widget.item,
        );
      }
    });

    _positionSub?.cancel();
    _positionSub = player.stream.position.listen((pos) {
      if (!_hasCapturedThumbnail && pos >= const Duration(seconds: 5) && player.state.playing) {
        _captureThumbnailIfNeeded();
      }
    });

    _optimisticClearSub?.cancel();
    _optimisticClearSub = player.stream.playing.listen((_) {
      if (mounted && _optimisticPlaying != null) {
        setState(() => _optimisticPlaying = null);
      }
    });

    _playingSub?.cancel();
    _playingSub = player.stream.playing.listen((playing) async {
      if (playing) {
        try {
          await _audioSession?.setActive(true);
        } catch (_) {}
      } else {
        try {
          await _audioSession?.setActive(false);
        } catch (_) {}
      }
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _totalDuration = widget.item.duration ?? Duration.zero;
    _player = _createConfiguredPlayer();
    _controller = _createConfiguredController(_player);
    _bindPlayerStreams(_player);

    // 5초마다 시청 위치 주기적 자동 저장
    _positionSaveTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _saveCurrentPosition();
    });

    _initAudioSession();
    _initContrast();
    _initVolume();
    SubtitleSettingsService.instance.init();
    _initOrientationMode();
    _initAndPlay();
  }

  Future<void> _initOrientationMode() async {
    final mode = await PlayerOrientationMode.load();
    if (mounted) {
      setState(() {
        _orientationMode = mode;
      });
      if (_isFullScreen) {
        _applyMobileFullScreen(true);
      }
    }
  }

  Future<void> _initAndPlay() async {
    try {
      // 1. 이전 이어보기 기록 및 자막 설정 조회
      final record = await PlaybackHistoryService.instance.getRecord(
        accountId: widget.service.account.id,
        item: widget.item,
      );

      final resumePos = (record != null &&
              record.positionMillis > 5000 &&
              (record.durationMillis <= 0 ||
                  (record.positionMillis < record.durationMillis - 15000 && record.progress <= 0.95)))
          ? record.position
          : null;

      if (record?.subtitleType != null) {
        _currentSubtitleType = record!.subtitleType;
        _currentSubtitleId = record.subtitleId;
        _currentSubtitleName = record.subtitleName;
        _currentSubtitleLanguage = record.subtitleLanguage;
      }

      _localThumbnailPath = record?.localThumbnailPath;
      if (_localThumbnailPath != null && File(_localThumbnailPath!).existsSync()) {
        _hasCapturedThumbnail = true;
      }

      // libmpv / HLS 고성능 네트워크 스트리밍 버퍼 캐시 및 헤더 설정
      try {
        final platform = (_player.platform as dynamic);
        await platform?.setProperty('slang', 'ko,kor,korean,kr');
        await platform?.setProperty('sub-codepage', 'auto:cp949');
        await platform?.setProperty('demuxer-max-bytes', '67108864'); // 64MB 대용량 버퍼
        await platform?.setProperty('demuxer-max-back-bytes', '33554432'); // 32MB 역방향 캐시
        await platform?.setProperty('demuxer-readahead-secs', '30'); // 30초 선행 버퍼링
        await platform?.setProperty('cache', 'yes');
        await platform?.setProperty('cache-secs', '30');
        try {
          final cacheDir = Directory('${Directory.systemTemp.path}/mpv_cache');
          if (!cacheDir.existsSync()) cacheDir.createSync(recursive: true);
          await platform?.setProperty('cache-dir', cacheDir.path);
        } catch (_) {}
        await platform?.setProperty('network-timeout', '15');
        await platform?.setProperty('force-seekable', 'yes');
        await platform?.setProperty('hr-seek', 'yes');
        await platform?.setProperty('hr-seek-framedrop', 'yes');

        // HLS(.m3u8) 세그먼트 및 암호화 키 요청 시 인증 쿠키/헤더 유지용 demuxer-lavf-o 설정
        final streamHeaders = await widget.service.getStreamHeaders();
        if (streamHeaders.isNotEmpty) {
          final headerString = streamHeaders.entries
              .map((e) => '${e.key}: ${e.value}')
              .join('\r\n');
          await platform?.setProperty('demuxer-lavf-o', 'headers=$headerString\r\n');
        }
      } catch (_) {}

      // 2. 외부 자막 사전 탐색 및 다운로드
      // 로컬에 이미 캐시된 자막이 있으면 즉시 바인딩 준비하고,
      // 네트워크 다운로드가 필요한 자막은 비디오 재생(player.open)을 차단하지 않도록 백그라운드로 처리
      File? initialSubtitleFile;
      String? initialSubtitleName;
      bool needBackgroundSubtitleDownload = false;

      if (_currentSubtitleType == 'cloud' && _currentSubtitleId != null) {
        final cached = _getSafeSubtitleCacheFile(_currentSubtitleId!, _currentSubtitleName);
        if (cached.existsSync() && cached.lengthSync() > 0) {
          initialSubtitleFile = cached;
          initialSubtitleName = _currentSubtitleName;
        } else {
          needBackgroundSubtitleDownload = true;
        }
      } else if (_currentSubtitleType == 'local' && _currentSubtitleId != null) {
        final local = File(_currentSubtitleId!);
        if (local.existsSync() && local.lengthSync() > 0) {
          initialSubtitleFile = local;
          initialSubtitleName = _currentSubtitleName;
        }
      } else if (_currentSubtitleType == null && widget.item.parentId != null) {
        needBackgroundSubtitleDownload = true;
      }

      // 3. 바이두/테라박스 스트리밍:
      // HLS(.m3u8)는 로컬 프록시를 통해 세그먼트 헤더를 주입하고,
      // MP4 직링크(dlink)는 libmpv가 자체 캐시(64MB)로 직접 연결하여 다중 Range 병목 차단
      await widget.service.refreshTokensIfNeeded();
      final qualities = await widget.service.getAvailableQualities(widget.item);
      final defaultQuality = widget.service.getDefaultPlaybackQuality();
      _availableQualities = qualities;
      _currentQuality = defaultQuality;

      final isBaiduOrTeraBox = widget.service.account.type == CloudType.baidu ||
          widget.service.account.type == CloudType.terabox;
      final isNaver = widget.service.account.type == CloudType.naver;
      final isMega = widget.service.account.type == CloudType.mega;

      final rawStreamUrl = await widget.service.getStreamUrlWithQuality(widget.item, defaultQuality);
      final rawHeaders = await widget.service.getStreamHeaders();

      final isHls = rawStreamUrl.contains('.m3u8') ||
          rawStreamUrl.contains('api/streaming') ||
          rawStreamUrl.contains('method=streaming');
      final isFallbackToOriginal = !defaultQuality.isOriginal && !isHls;
      if (isFallbackToOriginal) {
        _currentQuality = VideoQuality.original;
      }

      // Baidu/TeraBox HLS 및 네이버 MYBOX(단기 유효 서명 토큰/Range 문제 해결)는 LocalStreamProxy 경유
      final playUrl = ((isBaiduOrTeraBox && isHls) || isNaver || isMega)
          ? LocalStreamProxy.instance.registerStream(widget.service, widget.item, quality: defaultQuality, initialUrl: isMega ? null : rawStreamUrl)
          : rawStreamUrl;
      final headers = ((isBaiduOrTeraBox && isHls) || isNaver || isMega) ? <String, String>{} : rawHeaders;
      if (playUrl.contains('127.0.0.1')) {
        _activeProxyStreamUrl = playUrl;
      } else {
        _activeProxyStreamUrl = null;
      }

      // 다른 가용 화질(480p, 720p 등)은 재생 시작 직후의 네트워크 및 쿠키 병목을 방지하기 위해
      // 실제 재생이 안정화된 시점(position > 3초) 10초 뒤에 지연 프리페치
      if (qualities.length > 1) {
        StreamSubscription? prefetchSub;
        prefetchSub = _player.stream.position.listen((pos) {
          if (pos > const Duration(seconds: 3)) {
            prefetchSub?.cancel();
            Future.delayed(const Duration(seconds: 10), () {
              if (!mounted) return;
              widget.service.prefetchQualities(
                widget.item,
                qualities.where((q) => q != defaultQuality).toList(),
              );
            });
          }
        });
      }

      // mpv 내부 에러/로그 수집 (프록시 응답을 mpv가 어떻게 해석하는지 진단)
      _player.stream.error.listen((e) => debugPrint('[PlayerScreen] mpv error: $e'));
      _player.stream.log.listen((l) => debugPrint('[mpv] ${l.prefix}: ${l.text}'));

      debugPrint('[PlayerScreen] 스트림 오픈 시작 (isHls: $isHls, isFallback: $isFallbackToOriginal, quality: ${_currentQuality.label}): $playUrl');

      // 4. Media에 start: resumePos를 전달하여 첫 프레임부터 이전 위치에서 디코딩 개시!
      await _player.open(
        Media(
          playUrl,
          httpHeaders: headers.isNotEmpty ? headers : null,
          start: resumePos,
        ),
        play: true,
      );

      _ensureAutoPlay();

      if (isFallbackToOriginal) {
        _showNotificationBanner(
          message: '저해상도(${defaultQuality.label})를 지원하지 않아 원본으로 재생됩니다. 네트워크에 따라 버퍼링이 발생할 수 있습니다.',
          icon: Icons.warning_amber_rounded,
          iconColor: Colors.orangeAccent,
          duration: const Duration(seconds: 5),
        );
      }

      // 5. 다운로드 완료된 외부 자막이 있으면 즉시 연결 및 미디어 트랙 완료 시 보장 등록
      if (initialSubtitleFile != null && initialSubtitleFile.existsSync()) {
        _activeExternalSubtitleFile = initialSubtitleFile;
        final subTrack = SubtitleTrack.uri(
          initialSubtitleFile.path,
          title: initialSubtitleName,
          language: _currentSubtitleLanguage ?? 'ko',
        );
        _pendingInitialSubtitleTrack = subTrack;
        _saveCurrentPosition();

        if (mounted && initialSubtitleName != null) {
          final isRestored = _currentSubtitleType != null;
          _showNotificationBanner(
            message: isRestored ? '이전 자막 설정 복원: $initialSubtitleName' : '한국어 자막 자동 적용: $initialSubtitleName',
            icon: Icons.subtitles,
            iconColor: isRestored ? Colors.blueAccent : Colors.amber,
            duration: const Duration(seconds: 3),
          );
        }

        final finalSubFile = initialSubtitleFile;
        // 미디어 로드 완료 후 안전하게 자막 트랙 연결 (mpv 로딩 중 트랙 덮어씀 방지)
        () async {
          try {
            await _player.stream.duration
                .firstWhere((d) => d > Duration.zero)
                .timeout(const Duration(seconds: 15), onTimeout: () => Duration.zero);
          } catch (_) {}
          if (!mounted) return;
          if (_currentSubtitleType == 'none') return;
          try {
            debugPrint('[PlayerScreen] 미디어 재생 준비 완료 -> 초기 자막 트랙 설정: ${finalSubFile.path}');
            await _player.setSubtitleTrack(subTrack);
            _hasAutoSelectedSubtitle = true;
          } catch (e) {
            debugPrint('[PlayerScreen] 초기 자막 트랙 설정 오류: $e');
          }
        }();
      } else {
        _restoreOrAutoLoadSubtitle();
      }

      // 5-1. 온디맨드 자막 다운로드가 필요한 경우 백그라운드 비동기 다운로드 및 완료 후 자동 연결
      if (needBackgroundSubtitleDownload) {
        () async {
          try {
            MediaItem? subToDownload;
            final parentId = widget.item.parentId ?? record?.parentId;
            if (parentId != null && parentId.isNotEmpty) {
              final items = await widget.service.listItems(folderId: parentId);
              if (_currentSubtitleType == 'cloud' && _currentSubtitleId != null) {
                subToDownload = items.cast<MediaItem?>().firstWhere(
                  (it) => it != null && it.isSubtitle && (it.id == _currentSubtitleId || (_currentSubtitleName != null && it.name == _currentSubtitleName)),
                  orElse: () => null,
                );
              } else if (_currentSubtitleType == null) {
                final videoName = widget.item.name;
                final matchingSubs = items.where((it) => it.isSubtitle && SubtitleUtils.isSubtitleForVideo(it.name, videoName)).toList();
                if (matchingSubs.isNotEmpty) {
                  matchingSubs.sort((a, b) => SubtitleUtils.koreanScore(b.name).compareTo(SubtitleUtils.koreanScore(a.name)));
                  subToDownload = matchingSubs.first;
                }
              }
            }

            if (subToDownload != null) {
              final downloaded = await _downloadAndNormalizeSubtitle(subToDownload);
              if (downloaded != null && downloaded.existsSync() && downloaded.lengthSync() > 0 && mounted) {
                _activeExternalSubtitleFile = downloaded;
                _currentSubtitleType = 'cloud';
                _currentSubtitleId = subToDownload.id;
                _currentSubtitleName = subToDownload.name;
                _currentSubtitleLanguage = 'ko';
                _saveCurrentPosition();

                final subTrack = SubtitleTrack.uri(
                  downloaded.path,
                  title: subToDownload.name,
                  language: 'ko',
                );
                await _player.setSubtitleTrack(subTrack);
                _hasAutoSelectedSubtitle = true;

                _showNotificationBanner(
                  message: '한국어 자막 자동 적용: ${subToDownload.name}',
                  icon: Icons.subtitles,
                  iconColor: Colors.amber,
                  duration: const Duration(seconds: 3),
                );
              }
            }
          } catch (e) {
            debugPrint('[PlayerScreen] 백그라운드 자막 다운로드 실패: $e');
          }
        }();
      }

      // 6. 로딩 스피너 탈출 안전장치: duration뿐 아니라 buffering 또는 playing 상태 감지 시 즉시 로딩 해제
      _player.stream.buffering.firstWhere((b) => !b).timeout(
        const Duration(seconds: 2),
        onTimeout: () => false,
      ).then((_) {
        if (mounted && _isLoading) setState(() => _isLoading = false);
      });

      _player.stream.playing.firstWhere((p) => p).timeout(
        const Duration(seconds: 2),
        onTimeout: () => false,
      ).then((_) {
        if (mounted && _isLoading) setState(() => _isLoading = false);
      });

      try {
        final d = await _player.stream.duration.firstWhere((val) => val > Duration.zero).timeout(
          const Duration(seconds: 2),
          onTimeout: () => _totalDuration,
        );
        if (d > Duration.zero && mounted) {
          setState(() => _totalDuration = d);
          // start: resumePos로 이미 지정되어 있으므로, 실제 재생 시작(position > 0) 확인 후 필요한 경우에만 보조 seek
          if (resumePos != null && !_hasResumed && _player.state.position < const Duration(seconds: 1)) {
            () async {
              try {
                await _player.stream.position.firstWhere((p) => p > Duration.zero).timeout(const Duration(seconds: 3));
                if (!_hasResumed && mounted && _player.state.position < const Duration(seconds: 3)) {
                  _hasResumed = true;
                  await _safeSeek(resumePos);
                }
              } catch (_) {}
            }();
          }
        }
      } catch (_) {}

      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
      _beginResumeIndicator(resumePos);
      _startHideTimer();
    } catch (e) {
      // 직접 연결 오류 시 로컬 프록시로 폴백
      try {
        final record = await PlaybackHistoryService.instance.getRecord(
          accountId: widget.service.account.id,
          item: widget.item,
        );

        final resumePos = (record != null &&
                record.positionMillis > 5000 &&
                (record.durationMillis <= 0 ||
                    (record.positionMillis < record.durationMillis - 15000 && record.progress <= 0.95)))
            ? record.position
            : null;

        if (record?.subtitleType != null) {
          _currentSubtitleType = record!.subtitleType;
          _currentSubtitleId = record.subtitleId;
          _currentSubtitleName = record.subtitleName;
          _currentSubtitleLanguage = record.subtitleLanguage;
        }

        final streamUrl = LocalStreamProxy.instance.registerStream(widget.service, widget.item, quality: _currentQuality);
        await _player.open(
          Media(
            streamUrl,
            start: resumePos,
          ),
          play: true,
        );
        _ensureAutoPlay();

        try {
          final d = await _player.stream.duration.firstWhere((val) => val > Duration.zero).timeout(
            const Duration(seconds: 3),
            onTimeout: () => _totalDuration,
          );
          if (d > Duration.zero && mounted) {
            setState(() => _totalDuration = d);
            if (resumePos != null && !_hasResumed && _player.state.position < const Duration(seconds: 1)) {
              () async {
                try {
                  await _player.stream.position.firstWhere((p) => p > Duration.zero).timeout(const Duration(seconds: 3));
                  if (!_hasResumed && mounted && _player.state.position < const Duration(seconds: 3)) {
                    _hasResumed = true;
                    await _safeSeek(resumePos);
                  }
                } catch (_) {}
              }();
            }
          }
        } catch (_) {}

        if (mounted) {
          setState(() {
            _isLoading = false;
          });
        }
        _beginResumeIndicator(resumePos);
        _startHideTimer();
        _restoreOrAutoLoadSubtitle();
      } catch (e2) {
        if (mounted) {
          setState(() {
            _isLoading = false;
            _errorMessage = '스트리밍 준비 중 오류가 발생했습니다: $e2';
          });
        }
      }
    }
  }

  void _ensureAutoPlay() {
    _autoPlaySub?.cancel();
    _autoPlaySub = _player.stream.buffering.listen((buffering) {
      if (!buffering && !_player.state.playing && mounted) {
        _player.play();
      }
    });
  }

  void _startHideTimer() {
    _hideControlsTimer?.cancel();
    _hideControlsTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && _player.state.playing) {
        setState(() {
          _showControls = false;
        });
      }
    });
  }

  void _toggleControls() {
    setState(() {
      _showControls = !_showControls;
    });
    if (_showControls) {
      _startHideTimer();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _isFullScreen) {
      _applyMobileFullScreen(true);
    }
  }

  /// 모바일(Android/iOS) 전체화면 및 시스템 UI(상단바 날짜/배터리 등) 제어
  Future<void> _applyMobileFullScreen(bool enable) async {
    if (enable) {
      // 1. Flutter SystemChrome 화면 회전 모드 및 ImmersiveSticky 모드 적용
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      await SystemChrome.setPreferredOrientations(_orientationMode.deviceOrientations);
      // 2. Android 플랫폼 네이티브 WindowInsetsController로 시스템 상태바(시간/날짜/배터리) 및 회전 제어
      if (Platform.isAndroid) {
        try {
          const channel = MethodChannel('com.example.cloud_media_player/window');
          await channel.invokeMethod('setFullScreen', {'enable': true});
          await channel.invokeMethod('setOrientation', {'mode': _orientationMode.name});
        } catch (_) {}
      }
    } else {
      // 1. Flutter SystemChrome 복원
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
      // 2. Android 네이티브 상태바 및 회전 복원
      if (Platform.isAndroid) {
        try {
          const channel = MethodChannel('com.example.cloud_media_player/window');
          await channel.invokeMethod('setFullScreen', {'enable': false});
          await channel.invokeMethod('setOrientation', {'mode': 'unspecified'});
        } catch (_) {}
      }
    }
  }

  /// 화면 회전 모드 변경 및 영구 저장
  Future<void> _setOrientationMode(PlayerOrientationMode mode) async {
    setState(() {
      _orientationMode = mode;
    });
    await mode.save();
    if (_isFullScreen && !Platform.isWindows && !Platform.isLinux && !Platform.isMacOS) {
      await SystemChrome.setPreferredOrientations(mode.deviceOrientations);
      if (Platform.isAndroid) {
        try {
          const channel = MethodChannel('com.example.cloud_media_player/window');
          await channel.invokeMethod('setOrientation', {'mode': mode.name});
        } catch (_) {}
      }
    }
    _showNotificationBanner(
      message: '화면 회전: ${mode.label}',
      icon: _getOrientationIcon(mode),
      iconColor: Colors.lightBlueAccent,
      duration: const Duration(seconds: 2),
    );
  }

  IconData _getOrientationIcon(PlayerOrientationMode mode) {
    switch (mode) {
      case PlayerOrientationMode.landscape:
        return Icons.screen_lock_landscape;
      case PlayerOrientationMode.portrait:
        return Icons.screen_lock_portrait;
      case PlayerOrientationMode.sensor:
        return Icons.screen_rotation;
    }
  }

  Future<void> _toggleFullScreen() async {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      final isFull = await windowManager.isFullScreen();
      await windowManager.setFullScreen(!isFull);
      if (mounted) {
        setState(() {
          _isFullScreen = !isFull;
        });
      }
    } else {
      final nextState = !_isFullScreen;
      await _applyMobileFullScreen(nextState);
      if (mounted) {
        setState(() {
          _isFullScreen = nextState;
        });
      }
    }
  }

  Future<void> _exitFullScreen() async {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      final isFull = await windowManager.isFullScreen();
      if (isFull) {
        await windowManager.setFullScreen(false);
        if (mounted) {
          setState(() {
            _isFullScreen = false;
          });
        }
      }
    } else {
      if (_isFullScreen) {
        await _applyMobileFullScreen(false);
        if (mounted) {
          setState(() {
            _isFullScreen = false;
          });
        }
      }
    }
  }

  /// 구형 기기 및 자막 로딩 중 Seek 충돌을 방지하는 안전한 Seek 래퍼
  Future<void> _safeSeek(Duration target) async {
    final clampedTarget = target < Duration.zero
        ? Duration.zero
        : (_totalDuration > Duration.zero && target > _totalDuration ? _totalDuration : target);

    if (_isApplyingSubtitle) {
      // 자막 디먹서 재정렬 및 파싱 중일 때는 Seek 명령을 보류하여 락/드롭 방지
      _pendingSeekAfterSubtitle = clampedTarget;
      debugPrint('[PlayerScreen] 자막 처리 중 Seek 보류 -> $clampedTarget');
      if (mounted) {
        setState(() => _dragPosition = clampedTarget);
      }
      return;
    }

    try {
      await _player.seek(clampedTarget);
    } catch (e) {
      debugPrint('[PlayerScreen] Seek 실패: $e');
    }
  }

  /// 화면 좌/우 더블탭 시 [seconds]초 만큼 상대 이동 (음수=뒤로)
  Future<void> _doubleTapSeek(int seconds) async {
    final current = _dragPosition ?? _player.state.position;
    await _safeSeek(current + Duration(seconds: seconds));
    _showNotificationBanner(
      message: seconds < 0 ? '${-seconds}초 뒤로' : '$seconds초 앞으로',
      icon: seconds < 0 ? Icons.replay_10 : Icons.forward_10,
      iconColor: Colors.white,
      duration: const Duration(milliseconds: 700),
    );
  }

  void _flushPendingSeek() {
    if (_pendingSeekAfterSubtitle != null) {
      final pending = _pendingSeekAfterSubtitle!;
      _pendingSeekAfterSubtitle = null;
      if (mounted) {
        setState(() => _dragPosition = null);
      }
      debugPrint('[PlayerScreen] 자막 파이프라인 안정화 -> 보류된 Seek 즉각 실행 ($pending)');
      try {
        _player.seek(pending);
      } catch (_) {}
    }
  }

  /// 클라우드 자막 ID 및 파일명에 포함된 특수문자(|, /, \ 등)를 안전하게 치환하여 로컬 캐시 파일 반환
  /// (안드로이드 파일명 255바이트 한도 초과(OS Error: File name too long)를 방지하기 위해 해시 기반 고유 키 사용)
  File _getSafeSubtitleCacheFile(String id, String? name) {
    final tempDir = Directory.systemTemp;
    var ext = SubtitleUtils.getExtension(name ?? id);
    // SMI는 SRT로 변환하여 캐시하므로 확장자도 .srt 사용
    if (ext == '.smi') ext = '.srt';
    // id와 name을 조합하여 짧은 32비트 hex 고유 해시 키 생성 (안드로이드 255바이트 한도 방지)
    final hashKey = '${id}_${name ?? ''}'.hashCode.toUnsigned(32).toRadixString(16);
    final subDir = Directory('${tempDir.path}/subtitles');
    if (!subDir.existsSync()) {
      subDir.createSync(recursive: true);
    }
    // 예: temp/subtitles/sub_a1b2c3d4.smi (mpv demuxer 포맷 감지용 확장자 유지)
    final safeFileName = ext.isNotEmpty ? 'sub_$hashKey$ext' : 'sub_$hashKey';
    return File('${subDir.path}/$safeFileName');
  }

  /// 클라우드 자막 파일을 안전하게 다운로드하고, CP949/EUC-KR 등을 UTF-8로 자동 변환하여 캐시 저장
  Future<File?> _downloadAndNormalizeSubtitle(MediaItem subItem, {File? targetFile}) async {
    final cached = targetFile ?? _getSafeSubtitleCacheFile(subItem.id, subItem.name);
    if (cached.existsSync() && cached.lengthSync() > 10) {
      return cached;
    }

    try {
      debugPrint('[PlayerScreen] 자막 다운로드 요청 시작: ${subItem.name} (id: ${subItem.id})');
      Uint8List bytes;
      if (widget.service.account.type == CloudType.mega || widget.service.account.type == CloudType.baidu) {
        bytes = await widget.service.downloadBytes(subItem);
      } else {
        final url = await widget.service.getStreamUrl(subItem);
        final headers = await widget.service.getStreamHeaders();
        final res = await http.get(Uri.parse(url), headers: headers);
        debugPrint('[PlayerScreen] 자막 응답 상태: ${res.statusCode}, 바이트 크기: ${res.bodyBytes.length}');
        if (res.statusCode != 200 || res.bodyBytes.isEmpty) {
          // 실패 시 downloadBytes로 2차 시도
          bytes = await widget.service.downloadBytes(subItem);
        } else {
          bytes = res.bodyBytes;
        }
      }

      if (bytes.isNotEmpty) {
        final sample = String.fromCharCodes(bytes.take(200)).trim().toLowerCase();
        // HTML 에러 페이지(403, 404 등)가 200 OK로 반환되는 경우 방지
        if (sample.contains('<!doctype html') || (sample.contains('<html') && !sample.contains('<sami'))) {
          debugPrint('[PlayerScreen] 자막 다운로드 결과가 HTML 에러 페이지입니다. 저장 생략.');
          return null;
        }
        // 바이두/테라박스 API 실패 JSON 응답({"errno":...}) 방어
        if (sample.startsWith('{') && (sample.contains('errno') || sample.contains('error'))) {
          debugPrint('[PlayerScreen] 자막 다운로드 결과가 API 에러 JSON입니다. 저장 생략.');
          return null;
        }

        // CP949 / EUC-KR / GBK -> UTF-8 트랜스코딩
        var normalizedBytes = await SubtitleUtils.normalizeSubtitleToUtf8Bytes(bytes);
        // SMI는 mpv가 트랙으로 인식하지 못하므로 SRT로 변환하여 저장
        if (SubtitleUtils.getExtension(subItem.name) == '.smi') {
          final srt = SubtitleUtils.smiToSrt(utf8.decode(normalizedBytes, allowMalformed: true));
          if (srt.isEmpty) {
            debugPrint('[PlayerScreen] SMI -> SRT 변환 결과가 비어있습니다.');
            return null;
          }
          normalizedBytes = Uint8List.fromList(utf8.encode(srt));
        }
        await cached.writeAsBytes(normalizedBytes);
        debugPrint('[PlayerScreen] 자막 UTF-8 변환 및 캐시 완료: ${cached.path} (${normalizedBytes.length} bytes)');
        return cached;
      }
    } catch (e) {
      debugPrint('[PlayerScreen] 자막 다운로드/변환 실패: $e');
    }
    return null;
  }

  /// 자막 창 닫힌 직후 백그라운드로 안전하게 자막을 다운로드 및 적용
  Future<void> _applySelectedSubtitleAsync({
    required String type,
    String? id,
    String? name,
    String? language,
  }) async {
    _isApplyingSubtitle = true;
    _currentSubtitleType = type;
    _currentSubtitleId = id;
    _currentSubtitleName = name;
    _currentSubtitleLanguage = language ?? 'ko';
    _saveCurrentPosition();

    if (type == 'none') {
      try {
        await _player.setSubtitleTrack(SubtitleTrack.no());
      } catch (_) {}
      _isApplyingSubtitle = false;
      _flushPendingSeek();
      return;
    }

    if (mounted && name != null) {
      _showNotificationBanner(
        message: '자막 적용 중: $name',
        icon: Icons.subtitles,
        iconColor: Colors.amber,
        duration: const Duration(seconds: 2),
      );
    }

    try {
      if (type == 'local' && id != null) {
        final localFile = File(id);
        if (localFile.existsSync()) {
          _activeExternalSubtitleFile = localFile;
          await _player.setSubtitleTrack(
            SubtitleTrack.uri(localFile.path, title: name ?? 'local', language: language ?? 'ko'),
          );
        }
      } else if (type == 'cloud' && id != null) {
        final subItem = MediaItem(id: id, name: name ?? 'subtitle', isFolder: false);
        final cached = await _downloadAndNormalizeSubtitle(subItem);
        if (cached != null && cached.existsSync() && cached.lengthSync() > 0) {
          _activeExternalSubtitleFile = cached;
          final subTrack = SubtitleTrack.uri(cached.path, title: name, language: language ?? 'ko');
          debugPrint('[PlayerScreen] 자막 트랙 설정 완료: ${cached.path}');
          await _player.setSubtitleTrack(subTrack);
          _hasAutoSelectedSubtitle = true;
        } else {
          debugPrint('[PlayerScreen] 자막 다운로드/캐시 파일이 비어있거나 생성 실패');
        }
      } else if (type == 'track' && id != null) {
        _activeExternalSubtitleFile = null;
        _restoreTrackSubtitle(_player.state.tracks.subtitle);
      } else if (type == 'none') {
        _activeExternalSubtitleFile = null;
      }

      if (mounted && name != null) {
        _showNotificationBanner(
          message: '자막 적용 완료: $name',
          icon: Icons.subtitles,
          iconColor: Colors.tealAccent,
          duration: const Duration(seconds: 2),
        );
      }
    } catch (e) {
      debugPrint('[PlayerScreen] 자막 적용 오류: $e');
    } finally {
      // mpv 디먹서 파이프라인이 안정화될 수 있도록 약간의 딜레이(200ms) 후 대기 중인 Seek 실행
      await Future.delayed(const Duration(milliseconds: 200));
      _isApplyingSubtitle = false;
      _flushPendingSeek();
    }
  }

  void _openSubtitleDialog({int initialTab = 0}) {
    _hideControlsTimer?.cancel();
    showDialog(
      context: context,
      builder: (_) => SubtitleDialog(
        player: _player,
        item: widget.item,
        service: widget.service,
        initialTabIndex: initialTab,
        onSubtitleChanged: (type, id, name, language) {
          _applySelectedSubtitleAsync(
            type: type,
            id: id,
            name: name,
            language: language,
          );
        },
      ),
    ).then((_) {
      _startHideTimer();
    });
  }

  String _formatDuration(Duration d) {
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (hours > 0) {
      return '$hours:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }

  Future<void> _autoLoadKoreanSubtitle() async {
    if (_hasAutoSelectedSubtitle) return;
    final parentId = widget.item.parentId;
    if (parentId == null) {
      _selectKoreanTrack(_player.state.tracks.subtitle);
      return;
    }

    try {
      final items = await widget.service.listItems(folderId: parentId);
      final videoName = widget.item.name;

      // 같은 폴더 내에서 확장자를 제외한 이름이 동일하거나 매칭되는 자막 파일 필터링
      final matchingSubs = items.where((it) {
        if (!it.isSubtitle) return false;
        return SubtitleUtils.isSubtitleForVideo(it.name, videoName);
      }).toList();

      if (matchingSubs.isEmpty) {
        // 일치하는 외부 자막이 없으면 영상 내장 자막 중 한국어 트랙 확인
        _selectKoreanTrack(_player.state.tracks.subtitle);
        return;
      }

      // 한국어 우선순위 점수 기준 내림차순 정렬 (높은 점수 우선)
      matchingSubs.sort((a, b) => SubtitleUtils.koreanScore(b.name).compareTo(SubtitleUtils.koreanScore(a.name)));

      MediaItem? selectedSub;
      File? localSubFile;

      // 최상위 후보부터 다운로드 및 검증
      for (final candidate in matchingSubs) {
        try {
          final downloaded = await _downloadAndNormalizeSubtitle(candidate);
          if (downloaded != null && downloaded.existsSync() && downloaded.lengthSync() > 0) {
            final score = SubtitleUtils.koreanScore(candidate.name);
            final bytes = await downloaded.readAsBytes();
            final hasKorean = SubtitleUtils.hasKoreanContent(bytes);

            // 파일명에 한국어 표기가 있거나 내용에 한글/KRCC가 포함된 경우 채택
            if (score >= 50 || hasKorean || selectedSub == null) {
              selectedSub = candidate;
              localSubFile = downloaded;
              break;
            }
          }
        } catch (_) {}
      }

      if (selectedSub != null && localSubFile != null && mounted) {
        _activeExternalSubtitleFile = localSubFile;
        await _player.setSubtitleTrack(
          SubtitleTrack.uri(localSubFile.path, title: selectedSub.name, language: 'ko'),
        );
        _hasAutoSelectedSubtitle = true;
        _currentSubtitleType = 'cloud';
        _currentSubtitleId = selectedSub.id;
        _currentSubtitleName = selectedSub.name;
        _currentSubtitleLanguage = 'ko';
        _saveCurrentPosition();

        // SAMI 다중 언어 클래스(KRCC/ENCC) 또는 로드된 트랙 중 한국어 트랙 활성화
        Future.delayed(const Duration(milliseconds: 250), () {
          if (mounted) {
            _selectKoreanTrack(_player.state.tracks.subtitle);
          }
        });

        if (mounted) {
          _showNotificationBanner(
            message: '한국어 자막 자동 적용: ${selectedSub.name}',
            icon: Icons.subtitles,
            iconColor: Colors.amber,
            duration: const Duration(seconds: 3),
          );
        }
      } else {
        _selectKoreanTrack(_player.state.tracks.subtitle);
      }
    } catch (e) {
      debugPrint('자막 자동 로드 중 오류: $e');
      _selectKoreanTrack(_player.state.tracks.subtitle);
    }
  }

  Future<void> _restoreOrAutoLoadSubtitle() async {
    if (_hasAutoSelectedSubtitle) return;

    // 1. 이전 설정이 '자막 끄기'였던 경우
    if (_currentSubtitleType == 'none') {
      await _player.setSubtitleTrack(SubtitleTrack.no());
      _hasAutoSelectedSubtitle = true;
      return;
    }

    // 2. 이전 설정이 '로컬 파일'이었던 경우
    if (_currentSubtitleType == 'local' && _currentSubtitleId != null) {
      final localFile = File(_currentSubtitleId!);
      if (localFile.existsSync()) {
        _activeExternalSubtitleFile = localFile;
        await _player.setSubtitleTrack(
          SubtitleTrack.uri(localFile.path, title: _currentSubtitleName ?? 'local', language: _currentSubtitleLanguage ?? 'ko'),
        );
        _hasAutoSelectedSubtitle = true;
        if (mounted && _currentSubtitleName != null) {
          _showNotificationBanner(
            message: '이전 로컬 자막 복원: $_currentSubtitleName',
            icon: Icons.subtitles,
            iconColor: Colors.blueAccent,
            duration: const Duration(seconds: 3),
          );
        }
        return;
      }
    }

    // 3. 이전 설정이 '클라우드 자막 파일'이었던 경우
    if (_currentSubtitleType == 'cloud' && _currentSubtitleId != null) {
      await _restoreSavedCloudSubtitle(_currentSubtitleId!, _currentSubtitleName, _currentSubtitleLanguage);
      return;
    }

    // 4. 이전 설정이 '내장 자막 트랙'이었던 경우
    if (_currentSubtitleType == 'track' && _currentSubtitleId != null) {
      _restoreTrackSubtitle(_player.state.tracks.subtitle);
      return;
    }

    // 저장된 설정이 없으면 기본 한국어 자막 자동 로드
    _autoLoadKoreanSubtitle();
  }

  Future<void> _restoreSavedCloudSubtitle(String cloudId, String? cloudName, String? lang) async {
    final record = await PlaybackHistoryService.instance.getRecord(accountId: widget.service.account.id, item: widget.item);
    final parentId = widget.item.parentId ?? record?.parentId ?? 'root';

    try {
      final items = await widget.service.listItems(folderId: parentId);
      MediaItem? subItem = items.cast<MediaItem?>().firstWhere(
        (it) => it != null && it.isSubtitle && (it.id == cloudId || (cloudName != null && it.name == cloudName)),
        orElse: () => null,
      );
      subItem ??= items.cast<MediaItem?>().firstWhere(
        (it) => it != null && it.isSubtitle && SubtitleUtils.isSubtitleForVideo(it.name, widget.item.name),
        orElse: () => null,
      );
      subItem ??= MediaItem(id: cloudId, name: cloudName ?? 'subtitle', parentId: parentId, isFolder: false);

      if (subItem.id.isNotEmpty) {
        final downloadedFile = await _downloadAndNormalizeSubtitle(subItem);
        if (downloadedFile != null && downloadedFile.existsSync() && downloadedFile.lengthSync() > 0) {
          if (!mounted) return;
          _activeExternalSubtitleFile = downloadedFile;
          await _player.setSubtitleTrack(
            SubtitleTrack.uri(downloadedFile.path, title: subItem.name, language: lang ?? 'ko'),
          );
          _hasAutoSelectedSubtitle = true;
          _currentSubtitleType = 'cloud';
          _currentSubtitleId = subItem.id;
          _currentSubtitleName = subItem.name;
          _currentSubtitleLanguage = lang ?? 'ko';

          // SAMI의 경우 mpv가 내부 클래스(KRCC/ENCC)를 파싱할 때까지 대기 후 KRCC 선택
          Future.delayed(const Duration(milliseconds: 250), () {
            if (mounted) {
              if (lang != null && lang != 'ko') {
                _selectTrackByLanguage(lang, cloudName);
              } else {
                _selectKoreanTrack(_player.state.tracks.subtitle);
              }
            }
          });

          if (mounted) {
            _showNotificationBanner(
              message: '이전 자막 설정 복원: ${subItem.name}',
              icon: Icons.subtitles,
              iconColor: Colors.blueAccent,
              duration: const Duration(seconds: 3),
            );
          }
          return;
        }
      }
    } catch (_) {}

    // 이전 자막 복원 실패 시 기본 한국어 자막 자동 로드
    _autoLoadKoreanSubtitle();
  }

  bool _isKoreanTrack(SubtitleTrack track) {
    if (track.id == 'no' || track.id == 'auto') return false;
    final l = (track.language ?? '').toLowerCase();
    final t = (track.title ?? '').toLowerCase();
    return l == 'ko' ||
        l == 'kor' ||
        l == 'korean' ||
        l == 'kr' ||
        l.startsWith('ko') ||
        t.contains('krcc') ||
        t.contains('korean') ||
        t.contains('kor') ||
        t.contains('한국') ||
        t.contains('ko');
  }

  bool _restoreTrackSubtitle(List<SubtitleTrack> tracks, [Player? targetPlayer]) {
    final p = targetPlayer ?? _player;
    for (final track in tracks) {
      if (track.id == 'no' || track.id == 'auto') continue;
      if (track.id == _currentSubtitleId) {
        p.setSubtitleTrack(track);
        _hasAutoSelectedSubtitle = true;
        return true;
      }
    }
    for (final track in tracks) {
      if (track.id == 'no' || track.id == 'auto') continue;
      if (_currentSubtitleName != null &&
          (track.title ?? '').toLowerCase() == _currentSubtitleName!.toLowerCase()) {
        p.setSubtitleTrack(track);
        _hasAutoSelectedSubtitle = true;
        return true;
      }
    }
    for (final track in tracks) {
      if (track.id == 'no' || track.id == 'auto') continue;
      if (_currentSubtitleLanguage != null && _isKoreanTrack(track)) {
        p.setSubtitleTrack(track);
        _hasAutoSelectedSubtitle = true;
        return true;
      }
    }
    return false;
  }

  void _selectTrackByLanguage(String lang, String? title, [Player? targetPlayer]) {
    final p = targetPlayer ?? _player;
    final tracks = p.state.tracks.subtitle;
    for (final track in tracks) {
      if (track.id == 'no' || track.id == 'auto') continue;
      final tLang = (track.language ?? '').toLowerCase();
      final tTitle = (track.title ?? '').toLowerCase();
      if (tLang == lang.toLowerCase() || (title != null && tTitle == title.toLowerCase())) {
        p.setSubtitleTrack(track);
        break;
      }
    }
  }

  bool _selectKoreanTrack(List<SubtitleTrack> tracks, [Player? targetPlayer]) {
    final p = targetPlayer ?? _player;
    SubtitleTrack? targetTrack;

    // 1. krcc 트랙 최우선 (SAMI 자막 한국어 클래스)
    for (final track in tracks) {
      if (track.id == 'no' || track.id == 'auto') continue;
      final title = (track.title ?? '').toLowerCase();
      if (title.contains('krcc')) {
        targetTrack = track;
        break;
      }
    }

    // 2. 한국어 언어 태그 / 제목 매칭
    if (targetTrack == null) {
      for (final track in tracks) {
        if (track.id == 'no' || track.id == 'auto') continue;
        if (_isKoreanTrack(track)) {
          targetTrack = track;
          break;
        }
      }
    }

    if (targetTrack != null) {
      p.setSubtitleTrack(targetTrack);
      _hasAutoSelectedSubtitle = true;

      // 이미 클라우드/로컬 자막 파일로 지정되어 있는 경우 타입 보존 (오버라이트 방지)
      if (_currentSubtitleType != 'cloud' && _currentSubtitleType != 'local') {
        _currentSubtitleType = 'track';
        _currentSubtitleId = targetTrack.id;
        _currentSubtitleName = targetTrack.title;
        _currentSubtitleLanguage = targetTrack.language;
        _saveCurrentPosition();
      }
      return true;
    }
    return false;
  }

  /// 해상도 전환 후 대상 플레이어(targetPlayer)에 현재 설정된 자막을 확실히 재적용
  Future<void> _reapplySubtitleToPlayer(Player targetPlayer) async {
    try {
      if (_currentSubtitleType == 'none') {
        await targetPlayer.setSubtitleTrack(SubtitleTrack.no());
        return;
      }

      // 외부 자막 (클라우드 캐시 또는 로컬 파일)
      final extFile = _activeExternalSubtitleFile;
      if ((_currentSubtitleType == 'cloud' || _currentSubtitleType == 'local') &&
          extFile != null &&
          extFile.existsSync() &&
          extFile.lengthSync() > 0) {
        final subTrack = SubtitleTrack.uri(
          extFile.path,
          title: _currentSubtitleName ?? 'subtitle',
          language: _currentSubtitleLanguage ?? 'ko',
        );
        await targetPlayer.setSubtitleTrack(subTrack);
        _hasAutoSelectedSubtitle = true;
        debugPrint('[PlayerScreen] 외부 자막 재바인딩 완료: ${extFile.path}');
        return;
      }

      // 내장 트랙 자막
      final subTracks = targetPlayer.state.tracks.subtitle;
      if (_currentSubtitleType == 'track') {
        final restored = _restoreTrackSubtitle(subTracks, targetPlayer);
        if (!restored) {
          _selectKoreanTrack(subTracks, targetPlayer);
        }
      } else {
        _selectKoreanTrack(subTracks, targetPlayer);
      }
    } catch (e) {
      debugPrint('[PlayerScreen] 자막 재적용 실패: $e');
    }
  }

  Future<void> _captureThumbnailIfNeeded({bool force = false}) async {
    final pos = _player.state.position;
    // 영상 초반 5초 미만은 인트로 암전 구간일 수 있으므로 건너뜀 (단, 일시정지/종료 시 force인 경우 2초 이상이면 허용)
    if (!force && pos < const Duration(seconds: 5)) return;
    if (force && pos < const Duration(seconds: 2)) return;
    if (!force && !_player.state.playing) return;
    if (!force && _hasCapturedThumbnail) return;

    try {
      final bytes = await _player.screenshot(format: 'image/jpeg');
      if (bytes != null && bytes.isNotEmpty) {
        // 완전한 단색 검은 화면(대개 3KB 미만) 방지
        if (!force && bytes.length < 5000 && pos < const Duration(seconds: 15)) {
          return;
        }
        _hasCapturedThumbnail = true;
        final cacheDir = await PlaybackHistoryService.instance.getThumbnailDir();
        final safeItemId = widget.item.id.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
        final filePath = '$cacheDir\\${widget.service.account.id}_$safeItemId.jpg';
        final file = File(filePath);
        await file.writeAsBytes(bytes);
        _localThumbnailPath = filePath;
        await PlaybackHistoryService.instance.updateLocalThumbnail(
          accountId: widget.service.account.id,
          itemId: widget.item.id,
          path: filePath,
        );
      }
    } catch (e) {
      debugPrint('비디오 썸네일 캡처 실패: $e');
    }
  }

  void _togglePlayPause() {
    final wasPlaying = _player.state.playing;
    final wasCompleted = _player.state.completed;

    // 즉시 반응: 아이콘을 먼저 바꾸고 플레이어 명령을 바로 전달
    if (mounted) {
      setState(() => _optimisticPlaying = wasCompleted ? true : !wasPlaying);
    }
    if (wasCompleted) {
      _player.seek(Duration.zero);
      _player.play();
    } else {
      _player.playOrPause();
    }
    // 실제 상태가 오지 않는 경우 대비 안전장치
    _optimisticTimer?.cancel();
    _optimisticTimer = Timer(const Duration(milliseconds: 800), () {
      if (mounted) setState(() => _optimisticPlaying = null);
    });

    // 썸네일 캡처는 응답과 무관하게 이후에 수행
    if (wasPlaying) {
      Future.microtask(() => _captureThumbnailIfNeeded(force: true));
    }
  }

  /// 로딩 스피너 종료 후 이전 재생 위치로 이동 중임을 안내 (실제 재생 위치에 도달할 때까지 표시)
  void _beginResumeIndicator(Duration? target) {
    if (target == null || target <= const Duration(seconds: 5) || !mounted) return;
    setState(() => _resumeSeekTarget = target);

    _resumeSeekSub?.cancel();
    _resumeSeekTimeout?.cancel();
    void finish() {
      _resumeSeekSub?.cancel();
      _resumeSeekTimeout?.cancel();
      if (mounted && _resumeSeekTarget != null) {
        setState(() => _resumeSeekTarget = null);
        _showResumeNotice(target);
      }
    }

    // 목표 위치 근처에 도달하고 버퍼링이 끝나면 안내 종료
    _resumeSeekSub = _player.stream.position.listen((pos) {
      if (pos >= target - const Duration(seconds: 3) && !_player.state.buffering) {
        finish();
      }
    });
    // 최대 20초 후에는 안내 종료
    _resumeSeekTimeout = Timer(const Duration(seconds: 20), finish);
  }

  void _cancelAutoResume() {
    _hasResumed = true;
  }

  void _saveCurrentPosition() {
    final pos = _player.state.position;
    final dur = _totalDuration;
    if (pos > Duration.zero) {
      PlaybackHistoryService.instance.savePosition(
        accountId: widget.service.account.id,
        item: widget.item,
        position: pos,
        totalDuration: dur,
        subtitleType: _currentSubtitleType,
        subtitleId: _currentSubtitleId,
        subtitleName: _currentSubtitleName,
        subtitleLanguage: _currentSubtitleLanguage,
        localThumbnailPath: _localThumbnailPath,
      );
      if (!_hasCapturedThumbnail) {
        _captureThumbnailIfNeeded();
      }
      if (mounted) {
        try {
          final accountMgr = context.read<AccountManager>();
          CloudPlaybackSyncService.instance.scheduleAutoPush(accountMgr);
        } catch (_) {}
      }
    }
  }


  void _dismissBanner() {
    _bannerDismissTimer?.cancel();
    if (mounted) {
      setState(() {
        _bannerMessage = null;
        _bannerAction = null;
      });
    }
  }

  void _showNotificationBanner({
    required String message,
    IconData? icon,
    Color? iconColor,
    String? actionLabel,
    VoidCallback? onAction,
    Duration duration = const Duration(seconds: 4),
  }) {
    if (!mounted) return;
    _bannerDismissTimer?.cancel();
    setState(() {
      _bannerMessage = message;
      _bannerIcon = icon;
      _bannerIconColor = iconColor;
      _bannerActionLabel = actionLabel;
      _bannerAction = onAction;
    });

    _bannerDismissTimer = Timer(duration, () {
      if (mounted) {
        setState(() {
          _bannerMessage = null;
          _bannerAction = null;
        });
      }
    });
  }

  void _showResumeNotice(Duration target) {
    _showNotificationBanner(
      message: '이전 재생 위치(${_formatDuration(target)})에서 이어봅니다.',
      icon: Icons.history,
      iconColor: Colors.blueAccent,
      actionLabel: '처음부터 보기',
      onAction: () {
        _player.seek(Duration.zero);
        PlaybackHistoryService.instance.clearPosition(
          accountId: widget.service.account.id,
          item: widget.item,
        );
      },
      duration: const Duration(seconds: 4),
    );
  }

  /// Android / iOS 오디오 세션 초기화 및 인터럽션(전화, 유튜브 등) 처리
  Future<void> _initAudioSession() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
      _audioSession = session;

      // 오디오 포커스 중단 이벤트 리스너 (전화 수신, 다른 미디어 재생 시작 등)
      _interruptionSub = session.interruptionEventStream.listen((event) {
        if (event.begin) {
          switch (event.type) {
            case AudioInterruptionType.duck:
            case AudioInterruptionType.pause:
            case AudioInterruptionType.unknown:
              if (_player.state.playing) {
                _player.pause();
              }
              break;
          }
        } else {
          if (event.type == AudioInterruptionType.pause) {
            _player.play();
          }
        }
      });

      // 이어폰 또는 블루투스 오디오 장치 분리 시 즉시 일시정지 (사용자 프라이버시 보호)
      _becomingNoisySub = session.becomingNoisyEventStream.listen((_) {
        if (_player.state.playing) {
          _player.pause();
          _showNotificationBanner(
            message: '오디오 장치 연결 해제로 일시정지됨',
            icon: Icons.headset_off,
            iconColor: Colors.amber,
            duration: const Duration(seconds: 3),
          );
        }
      });
    } catch (_) {}
  }

  /// 하드웨어 가속 [HW] ↔ 소프트웨어 디코딩 [SW] 실시간 원터치 전환
  Future<void> _toggleHardwareAcceleration() async {
    final nextHw = !_isHwDec;
    final hwValue = nextHw ? (Platform.isAndroid ? 'mediacodec' : 'auto') : 'no';
    try {
      final platform = (_player.platform as dynamic);
      await platform?.setProperty('hwdec', hwValue);
      setState(() {
        _isHwDec = nextHw;
      });
      _showNotificationBanner(
        message: nextHw
            ? '하드웨어 가속 활성화됨 (GPU / MediaCodec)'
            : '소프트웨어 디코딩 모드로 전환됨 (CPU)',
        icon: nextHw ? Icons.speed : Icons.memory,
        iconColor: nextHw ? Colors.tealAccent : Colors.orangeAccent,
        duration: const Duration(seconds: 3),
      );
    } catch (e) {
      _showNotificationBanner(
        message: '가속 모드 전환 실패: $e',
        icon: Icons.error_outline,
        iconColor: Colors.redAccent,
        duration: const Duration(seconds: 2),
      );
    }
  }

  /// 플레이어 상단바에 표시할 세련된 [HW] / [SW] 뱃지 위젯
  Widget _buildHwSwBadge() {
    final isHw = _isHwDec;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: _toggleHardwareAcceleration,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: Colors.white24,
              width: 0.8,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isHw ? Icons.flash_on : Icons.memory,
                size: 13,
                color: Colors.white70,
              ),
              const SizedBox(width: 3),
              Text(
                isHw ? 'HW' : 'SW',
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 화면 밝기 초기화 (현재 기기 화면 밝기 0.0~1.0을 그대로 사용)
  /// (_contrast 변수는 화면 밝기 값을 의미)
  Future<void> _initContrast() async {
    try {
      final current = await ScreenBrightness().application;
      _contrast = current.clamp(0.0, 1.0);
      if (mounted) {
        setState(() {});
      }
    } catch (_) {
      _contrast = 0.5;
    }
  }

  /// 제스처에 의한 기기 화면 밝기 변경 (0.0 ~ 1.0)
  Future<void> _setContrast(double value) async {
    final clamped = value.clamp(0.0, 1.0);
    setState(() {
      _contrast = clamped;
      _showContrastIndicator = true;
      _showVolumeIndicator = false;
    });
    try {
      await ScreenBrightness().setApplicationScreenBrightness(clamped);
    } catch (_) {}
    _startGestureDismissTimer();
  }

  /// 밝기를 50% 이상 올렸을 때 적용하는 약한 콘트라스트 + 채도 보정 (쨍한 느낌)
  /// - 중간 회색(0.5)을 기준으로 대비를 키워 블랙/화이트 끝단은 크게 손상되지 않음
  List<double> _getBoostMatrix(double level) {
    final t = ((level - 0.5) * 2.0).clamp(0.0, 1.0);
    final c = 1.0 + 0.12 * t; // 콘트라스트
    final s = 1.0 + 0.15 * t; // 채도
    final o = 255.0 * 0.5 * (1.0 - c); // 중간값 고정 오프셋
    const lr = 0.2126, lg = 0.7152, lb = 0.0722;
    final ir = lr * (1 - s), ig = lg * (1 - s), ib = lb * (1 - s);
    return <double>[
      c * (ir + s), c * ig, c * ib, 0, o,
      c * ir, c * (ig + s), c * ib, 0, o,
      c * ir, c * ig, c * (ib + s), 0, o,
      0, 0, 0, 1, 0,
    ];
  }

  /// 시스템 볼륨 초기화 및 기기 볼륨 리스너 등록
  Future<void> _initVolume() async {
    try {
      await FlutterVolumeController.updateShowSystemUI(false);
      final sysVol = await FlutterVolumeController.getVolume();
      if (sysVol != null && mounted) {
        setState(() {
          _gestureVolume = (sysVol * 100.0).clamp(0.0, 100.0);
        });
      }
    } catch (_) {
      _gestureVolume = 100.0;
    }

    try {
      FlutterVolumeController.addListener((volume) {
        if (mounted) {
          setState(() {
            _gestureVolume = (volume * 100.0).clamp(0.0, 100.0);
          });
        }
      });
    } catch (_) {}

    // 플레이어 소프트웨어 볼륨은 100%로 설정하여 왜곡 없이 시스템 볼륨과 1:1 매핑
    try {
      await _player.setVolume(100.0);
    } catch (_) {}
  }

  /// 제스처에 의한 시스템 볼륨 변경 (0.0 ~ 100.0)
  Future<void> _setVolume(double value) async {
    final clamped = value.clamp(0.0, 100.0);
    setState(() {
      _gestureVolume = clamped;
      _showVolumeIndicator = true;
      _showContrastIndicator = false;
    });
    try {
      await FlutterVolumeController.setVolume(clamped / 100.0);
    } catch (_) {
      // 기기 시스템 볼륨 제어 실패 시 플레이어 내부 볼륨 폴백
      await _player.setVolume(clamped);
    }
    _startGestureDismissTimer();
  }

  /// 제스처 인디케이터 오버레이 자동 숨김 타이머 (1.2초)
  void _startGestureDismissTimer() {
    _gestureIndicatorTimer?.cancel();
    _gestureIndicatorTimer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) {
        setState(() {
          _showContrastIndicator = false;
          _showVolumeIndicator = false;
        });
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _gestureIndicatorTimer?.cancel();
    try {
      FlutterVolumeController.removeListener();
    } catch (_) {}
    try {
      ScreenBrightness().resetApplicationScreenBrightness();
    } catch (_) {}
    _interruptionSub?.cancel();
    _becomingNoisySub?.cancel();
    _playingSub?.cancel();
    _optimisticClearSub?.cancel();
    _optimisticTimer?.cancel();
    _resumeSeekSub?.cancel();
    _resumeSeekTimeout?.cancel();
    try {
      _audioSession?.setActive(false);
    } catch (_) {}
    _bannerDismissTimer?.cancel();
    _positionSaveTimer?.cancel();
    _completedSub?.cancel();
    _positionSub?.cancel();
    _saveCurrentPosition();
    _autoPlaySub?.cancel();
    _durationSub?.cancel();
    _tracksSub?.cancel();
    _hideControlsTimer?.cancel();
    _exitFullScreen();
    _disposeStandbyPlayer();
    _player.dispose();
    super.dispose();
  }

  void _disposeStandbyPlayer() {
    _isStandbyFrameReady = false;
    final standby = _standbyPlayer;
    _standbyPlayer = null;
    _standbyController = null;
    if (standby != null) {
      standby.setVolume(0.0).catchError((_) {});
      standby.pause().catchError((_) {});
      standby.dispose().catchError((_) {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: PopScope(
        canPop: !_isFullScreen,
        onPopInvokedWithResult: (didPop, result) async {
          if (didPop) {
            _exitFullScreen();
            if (!_hasCapturedThumbnail && _player.state.position >= const Duration(seconds: 2)) {
              await _captureThumbnailIfNeeded(force: true);
            }
            _saveCurrentPosition();
          } else if (_isFullScreen) {
            await _exitFullScreen();
          }
        },
        child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () {
            _exitFullScreen();
          },
          const SingleActivator(LogicalKeyboardKey.keyF): () {
            _toggleFullScreen();
          },
          const SingleActivator(LogicalKeyboardKey.space): () {
            _togglePlayPause();
            setState(() => _showControls = true);
            _startHideTimer();
          },
          const SingleActivator(LogicalKeyboardKey.arrowRight): () {
            final target = _player.state.position + const Duration(seconds: 10);
            _safeSeek(target);
          },
          const SingleActivator(LogicalKeyboardKey.arrowLeft): () {
            final target = _player.state.position - const Duration(seconds: 10);
            _safeSeek(target < Duration.zero ? Duration.zero : target);
          },
        },
        child: Focus(
          autofocus: true,
          child: MouseRegion(
            onHover: (event) {
              if (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS) return;
              final size = MediaQuery.of(context).size;
              final isEdge = event.position.dy < size.height * 0.30 || event.position.dy > size.height * 0.70;

              if (isEdge) {
                // 마우스 포인터가 화면 상단 30% 또는 하단 30% 영역으로 이동하면 UI 자동 노출
                if (!_showControls) {
                  setState(() => _showControls = true);
                }
                _startHideTimer();
              } else {
                // 마우스 포인터가 중앙 영역(30% ~ 70%)으로 이동하면 UI 즉시 숨김
                if (_showControls && _dragPosition == null) {
                  _hideControlsTimer?.cancel();
                  setState(() => _showControls = false);
                }
              }
            },
            onExit: (event) {
              if (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS) return;
              // 마우스 포인터가 화면 밖으로 벗어난 경우 즉시 UI 숨김
              if (_showControls && _dragPosition == null && _player.state.playing) {
                _hideControlsTimer?.cancel();
                setState(() => _showControls = false);
              }
            },
            child: GestureDetector(
              onTap: _toggleControls,
              onDoubleTapDown: (details) {
                _doubleTapDownX = details.localPosition.dx;
              },
              onDoubleTap: () {
                final width = MediaQuery.of(context).size.width;
                final x = _doubleTapDownX ?? width / 2;
                if (x < width * 0.4) {
                  _doubleTapSeek(-10);
                } else if (x > width * 0.6) {
                  _doubleTapSeek(10);
                } else {
                  _toggleFullScreen();
                }
              },
              onVerticalDragStart: (details) {
                final size = MediaQuery.of(context).size;
                final x = details.localPosition.dx;
                if (x < size.width / 2) {
                  _isDraggingLeft = true;
                  _isDraggingRight = false;
                } else {
                  _isDraggingRight = true;
                  _isDraggingLeft = false;
                }
                _gestureIndicatorTimer?.cancel();
              },
              onVerticalDragUpdate: (details) {
                final size = MediaQuery.of(context).size;
                final delta = -details.primaryDelta! / (size.height * 0.35);

                if (_isDraggingLeft) {
                  // 화면 왼쪽: 비디오 콘트라스트(명암비) 조절 (UI 0~100, 기본 50)
                  final newC = (_contrast + delta).clamp(0.0, 1.0);
                  _setContrast(newC);
                } else if (_isDraggingRight) {
                  // 화면 오른쪽: 시스템 볼륨 조절 (0.0 ~ 100.0)
                  final newV = (_gestureVolume + delta * 100).clamp(0.0, 100.0);
                  _setVolume(newV);
                }
              },
              onVerticalDragEnd: (details) {
                _isDraggingLeft = false;
                _isDraggingRight = false;
                _startGestureDismissTimer();
              },
              onVerticalDragCancel: () {
                _isDraggingLeft = false;
                _isDraggingRight = false;
                _startGestureDismissTimer();
              },
              behavior: HitTestBehavior.opaque,
              child: Stack(
                children: [
                  // 1. 비디오 화면 렌더링 (시스템 밝기 + 밝기를 올릴 때만 약한 콘트라스트/채도 보정)
                  Center(
                    child: _contrast > 0.55
                        ? ColorFiltered(
                            colorFilter: ColorFilter.matrix(_getBoostMatrix(_contrast)),
                            child: Video(
                              key: ValueKey(_controller),
                              controller: _controller,
                              controls: NoVideoControls,
                              subtitleViewConfiguration: const SubtitleViewConfiguration(visible: false),
                            ),
                          )
                        : Video(
                            key: ValueKey(_controller),
                            controller: _controller,
                            controls: NoVideoControls,
                            subtitleViewConfiguration: const SubtitleViewConfiguration(visible: false),
                          ),
                  ),

                  // 1-1. 스탠바이 플레이어 레이어 (워밍업 중 0.001, 프레임 준비 완료 시 1.0으로 위를 덮음)
                  if (_standbyController != null)
                    Positioned.fill(
                      child: Opacity(
                        opacity: _isStandbyFrameReady ? 1.0 : 0.001,
                        child: Center(
                          child: _contrast > 0.55
                              ? ColorFiltered(
                                  colorFilter: ColorFilter.matrix(_getBoostMatrix(_contrast)),
                                  child: Video(
                                    key: ValueKey(_standbyController),
                                    controller: _standbyController!,
                                    controls: NoVideoControls,
                                    subtitleViewConfiguration: const SubtitleViewConfiguration(visible: false),
                                  ),
                                )
                              : Video(
                                  key: ValueKey(_standbyController),
                                  controller: _standbyController!,
                                  controls: NoVideoControls,
                                  subtitleViewConfiguration: const SubtitleViewConfiguration(visible: false),
                                ),
                        ),
                      ),
                    ),

                  // 1-0. 폴백 시 검은 화면 방지용 마지막 프레임 프리즈 오버레이
                  if (_freezeFrameBytes != null)
                    Positioned.fill(
                      child: Image.memory(
                        _freezeFrameBytes!,
                        fit: BoxFit.contain,
                      ),
                    ),

                  // 1-1. 커스텀 자막 오버레이 (크기, 위치, 글자색, 배경색 & 투명도 완벽 지원)
                  CustomSubtitleView(player: _player),

                  // 2. 로딩 인디케이터
                  if (_isLoading)
                    Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
                        decoration: BoxDecoration(
                          color: Colors.black87,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: Colors.white24, width: 0.8),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: const [
                            CircularProgressIndicator(color: Colors.blueAccent, strokeWidth: 3.5),
                            SizedBox(height: 14),
                            Text(
                              '동영상 스트림 로딩 중...',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                  // 2-1. 이전 재생 위치 이동 안내 (스피너 종료 후, 실제 재생 시작 전까지)
                  if (_resumeSeekTarget != null && !_isLoading && _errorMessage == null)
                    Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
                        decoration: BoxDecoration(
                          color: Colors.black87,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: Colors.white24, width: 0.8),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.history, color: Colors.blueAccent, size: 30),
                            const SizedBox(height: 10),
                            Text(
                              '이전 재생 위치(${_formatDuration(_resumeSeekTarget!)})로 이동 중...',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const SizedBox(height: 4),
                            const Text(
                              '잠시만 기다려 주세요',
                              style: TextStyle(color: Colors.white60, fontSize: 12),
                            ),
                            const SizedBox(height: 12),
                            const SizedBox(
                              width: 120,
                              child: LinearProgressIndicator(
                                color: Colors.blueAccent,
                                backgroundColor: Colors.white12,
                                minHeight: 3,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                  // 3. 에러 메시지
                  if (_errorMessage != null)
                    Center(
                      child: Container(
                        padding: const EdgeInsets.all(24),
                        margin: const EdgeInsets.all(32),
                        decoration: BoxDecoration(
                          color: Colors.black87,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.redAccent.withAlpha(128)),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.error_outline, color: Colors.redAccent, size: 48),
                            const SizedBox(height: 16),
                            Text(_errorMessage!,
                                textAlign: TextAlign.center,
                                style: const TextStyle(color: Colors.white)),
                            const SizedBox(height: 16),
                            ElevatedButton(
                              onPressed: () => Navigator.pop(context),
                              child: const Text('돌아가기'),
                            )
                          ],
                        ),
                      ),
                    ),

                  // 4. 오버레이 컨트롤 바
                  if (_showControls && !_isLoading && _errorMessage == null)
                    Positioned.fill(
                      child: AnimatedOpacity(
                        opacity: _showControls ? 1.0 : 0.0,
                        duration: const Duration(milliseconds: 250),
                        child: Container(
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Colors.black87,
                                Colors.transparent,
                                Colors.transparent,
                                Colors.black87,
                              ],
                              stops: [0.0, 0.25, 0.75, 1.0],
                            ),
                          ),
                          child: SafeArea(
                            child: Column(
                              children: [
                                // 상단 헤더 바
                                _buildTopBar(),

                                const Spacer(),

                                // 하단 탐색 & 볼륨 컨트롤
                                _buildBottomControls(),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),

                  // 5. 알림 배너 (반투명 오버레이 & 자동 소멸)
                  _buildNotificationBanner(),

                  // 6. 제스처 밝기 및 볼륨 인디케이터 오버레이
                  _buildGestureIndicators(),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

  /// 화면 왼쪽(콘트라스트) 및 오른쪽(볼륨) 제스처 조절 시 표시되는 세로형 피드백 인디케이터
  Widget _buildGestureIndicators() {
    return Positioned.fill(
      child: IgnorePointer(
        child: Stack(
          children: [
            // 밝기 인디케이터: 왼쪽 스와이프 → 오른쪽에 표시
            if (_showContrastIndicator)
              Positioned(
                right: 36,
                top: 0,
                bottom: 0,
                child: Center(
                  child: _buildVerticalIndicator(
                    icon: Icons.brightness_6,
                    iconColor: Colors.amberAccent,
                    percent: _contrast.clamp(0.0, 1.0),
                    label: '${(_contrast * 100).round()}',
                  ),
                ),
              ),

            // 볼륨 인디케이터: 오른쪽 스와이프 → 왼쪽에 표시
            if (_showVolumeIndicator)
              Positioned(
                left: 36,
                top: 0,
                bottom: 0,
                child: Center(
                  child: _buildVerticalIndicator(
                    icon: _gestureVolume == 0
                        ? Icons.volume_off
                        : (_gestureVolume < 50
                            ? Icons.volume_down
                            : Icons.volume_up),
                    iconColor: Colors.lightBlueAccent,
                    percent: _gestureVolume / 100.0,
                    label: '${_gestureVolume.round()}%',
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildVerticalIndicator({
    required IconData icon,
    required Color iconColor,
    required double percent,
    required String label,
  }) {
    final clampedPercent = percent.clamp(0.0, 1.0);
    return Container(
      width: 68,
      padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.78),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.18), width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.55),
            blurRadius: 16,
            spreadRadius: 2,
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: iconColor, size: 28),
          const SizedBox(height: 14),
          // 세로형 프로그레스 바
          Container(
            width: 8,
            height: 90,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Stack(
              alignment: Alignment.bottomCenter,
              children: [
                Container(
                  height: 90 * clampedPercent,
                  decoration: BoxDecoration(
                    color: iconColor,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }

  /// 비디오 스트리밍 해상도(화질) 심리스(Seamless) 변경 처리
  Future<void> _switchQuality(VideoQuality targetQuality) async {
    if (_currentQuality == targetQuality || _isSwitchingQuality) return;

    final token = ++_switchQualityToken;
    _disposeStandbyPlayer();

    setState(() {
      _isSwitchingQuality = true;
    });

    _showNotificationBanner(
      message: '해상도 전환 준비 중 (${targetQuality.label})...',
      icon: Icons.hd,
      iconColor: Colors.amber,
      duration: const Duration(seconds: 4),
    );

    try {
      await widget.service.refreshTokensIfNeeded();
      if (token != _switchQualityToken) return;

      final isBaiduOrTeraBox = widget.service.account.type == CloudType.baidu ||
          widget.service.account.type == CloudType.terabox;
      final isNaver = widget.service.account.type == CloudType.naver;
      final isMega = widget.service.account.type == CloudType.mega;

      final rawStreamUrl = await widget.service.getStreamUrlWithQuality(widget.item, targetQuality);
      if (token != _switchQualityToken) return;
      final rawHeaders = await widget.service.getStreamHeaders();

      final isHls = rawStreamUrl.contains('.m3u8') ||
          rawStreamUrl.contains('api/streaming') ||
          rawStreamUrl.contains('method=streaming');
      final isFallbackToOriginal = !targetQuality.isOriginal && !isHls;
      final effectiveQuality = isFallbackToOriginal ? VideoQuality.original : targetQuality;

      final playUrl = ((isBaiduOrTeraBox && isHls) || isNaver || isMega)
          ? LocalStreamProxy.instance.registerStream(widget.service, widget.item, quality: targetQuality)
          : rawStreamUrl;
      final headers = ((isBaiduOrTeraBox && isHls) || isNaver || isMega) ? <String, String>{} : rawHeaders;

      // 1단계: 듀얼 플레이어 프리버퍼링 시도
      bool hotSwapSuccess = false;
      try {
        hotSwapSuccess = await _tryHotSwapQuality(
          playUrl: playUrl,
          headers: headers,
          targetQuality: effectiveQuality,
          token: token,
          isFallbackToOriginal: isFallbackToOriginal,
        );
      } catch (e) {
        debugPrint('[PlayerScreen] 듀얼 플레이어 스왑 실패, 폴백 시도: $e');
      }

      // 2단계: 듀얼 플레이어 실패 시 프레임 프리즈 단일 플레이어 폴백
      if (!hotSwapSuccess && token == _switchQualityToken && mounted) {
        await _fallbackSinglePlayerSwitch(
          playUrl: playUrl,
          headers: headers,
          targetQuality: effectiveQuality,
          token: token,
          isFallbackToOriginal: isFallbackToOriginal,
        );
      }
    } catch (e) {
      if (token == _switchQualityToken && mounted) {
        setState(() {
          _isSwitchingQuality = false;
        });
        _showNotificationBanner(
          message: '화질 전환 실패: $e',
          icon: Icons.error_outline,
          iconColor: Colors.redAccent,
          duration: const Duration(seconds: 4),
        );
      }
    }
  }

  /// 듀얼 플레이어(백그라운드 스탠바이) 프리버퍼링 및 핫스왑 수행
  Future<bool> _tryHotSwapQuality({
    required String playUrl,
    required Map<String, String> headers,
    required VideoQuality targetQuality,
    required int token,
    required bool isFallbackToOriginal,
  }) async {
    final standby = Player(
      configuration: const PlayerConfiguration(
        bufferSize: 64 * 1024 * 1024,
      ),
    );
    await _applyPlayerPlatformProperties(standby);
    final standbyCtrl = _createConfiguredController(standby);

    if (token != _switchQualityToken || !mounted) {
      standby.dispose();
      return false;
    }

    _standbyPlayer = standby;
    _standbyController = standbyCtrl;
    _isStandbyFrameReady = false;
    if (mounted) setState(() {});

    // 보조 플레이어는 볼륨 0(Muted) 및 배속 동기화
    await standby.setVolume(0.0);
    await standby.setRate(_playbackSpeed);

    // 네트워크 버퍼링 소요 시간(1~2초)을 고려하여 충분한 선행 위치 지정
    final curPos = _player.state.position;
    final leadMs = (2000 * _playbackSpeed).round();
    final targetStart = curPos + Duration(milliseconds: leadMs);

    await standby.open(
      Media(
        playUrl,
        httpHeaders: headers.isNotEmpty ? headers : null,
        start: targetStart,
      ),
      play: true,
    );

    // 첫 비디오 프레임 디코딩 및 실제 렌더링 준비 대기 (최대 10초)
    final readyCompleter = Completer<bool>();
    StreamSubscription? posSub;
    Timer? timeoutTimer;

    void checkReady() {
      if (readyCompleter.isCompleted) return;
      final hasWidth = standby.state.width != null && standby.state.width! > 0;
      final notBuffering = !standby.state.buffering;
      final posAdvancing = standby.state.position > Duration.zero;
      if (hasWidth && notBuffering && posAdvancing) {
        readyCompleter.complete(true);
      }
    }

    posSub = standby.stream.position.listen((_) => checkReady());
    timeoutTimer = Timer(const Duration(seconds: 10), () {
      if (!readyCompleter.isCompleted) {
        final hasWidth = standby.state.width != null && standby.state.width! > 0;
        final notBuffering = !standby.state.buffering;
        readyCompleter.complete(hasWidth && notBuffering);
      }
    });

    final isReady = await readyCompleter.future;
    posSub.cancel();
    timeoutTimer.cancel();

    if (!isReady || token != _switchQualityToken || !mounted) {
      if (_standbyPlayer == standby) {
        _disposeStandbyPlayer();
      }
      return false;
    }

    // 디먹서가 열린 시점에 새 플레이어에 자막 미리 재바인딩
    await _reapplySubtitleToPlayer(standby);

    if (token != _switchQualityToken || !mounted) {
      if (_standbyPlayer == standby) _disposeStandbyPlayer();
      return false;
    }

    // =========================================================================
    // [프레임 싱크: 선행 파킹 후 랑데부 (Park & Rendezvous)]
    // 움직이는 대상을 뒤쫓지 않고, standby를 미래 위치에 먼저 pause()로 파킹해 둔 뒤
    // Primary 플레이어가 해당 프레임에 도달하는 찰나에 출발시킴
    // =========================================================================
    await standby.pause();
    var parkedPos = standby.state.position;
    var livePos = _player.state.position;

    // standby가 livePos보다 뒤처졌거나 (오차 음수) 너무 먼 미래(>1200ms)인 경우
    // 미래 시점(livePos + 600ms)으로 정밀 seek 후 다시 파킹
    final diffMs = (parkedPos - livePos).inMilliseconds;
    if (diffMs < 80 || diffMs > 1200) {
      final targetSyncPos = livePos + Duration(milliseconds: (650 * _playbackSpeed).round());
      try {
        await standby.seek(targetSyncPos);
        // hr-seek 디코딩 완료 대기 (최대 2초)
        await standby.stream.buffering.firstWhere((b) => !b).timeout(
          const Duration(seconds: 2),
          onTimeout: () => false,
        );
      } catch (_) {}
      await standby.pause();
      parkedPos = standby.state.position;
    }

    if (token != _switchQualityToken || !mounted) {
      if (_standbyPlayer == standby) _disposeStandbyPlayer();
      return false;
    }

    // 랑데부(Rendezvous) 카운트다운:
    // standby는 parkedPos 프레임이 비디오 버퍼에 디코딩된 채 멈춰있고,
    // _player는 livePos에서 parkedPos를 향해 정상 재생 중임
    // 30ms는 standby.play() 호출 후 하드웨어 오디오/비디오 출력 파이프라인 기상 지연 보정치
    const leadWakeup = Duration(milliseconds: 30);
    final targetHitPos = parkedPos > leadWakeup ? parkedPos - leadWakeup : parkedPos;

    final maxWaitWatch = Stopwatch()..start();
    while (mounted && token == _switchQualityToken && _player.state.playing) {
      final currentLive = _player.state.position;
      if (currentLive >= targetHitPos) {
        break;
      }
      if (maxWaitWatch.elapsedMilliseconds > 2000) {
        // 안전장치: 최대 2초 초과 시 루프 탈출
        break;
      }
      await Future.delayed(const Duration(milliseconds: 16));
    }

    if (token != _switchQualityToken || !mounted) {
      if (_standbyPlayer == standby) _disposeStandbyPlayer();
      return false;
    }

    // 1단계: 스탠바이 위젯 불투명도를 1.0으로 먼저 전환 (화면 덮음)
    if (mounted) {
      setState(() {
        _isStandbyFrameReady = true;
      });
    }

    // 다음 UI 렌더링 프레임까지 대기하여 새 프레임이 화면에 완전히 노출되도록 보장
    await WidgetsBinding.instance.endOfFrame;

    if (token != _switchQualityToken || !mounted) {
      if (_standbyPlayer == standby) _disposeStandbyPlayer();
      return false;
    }

    // 2단계 [핫스왑 수행]: 오디오 선차단 및 무지연 동시 전환 (Zero-Overlap Audio Handoff)
    final oldPlayer = _player;
    final oldProxyUrl = _activeProxyStreamUrl;
    final wasPlaying = oldPlayer.state.playing;

    // 구 플레이어 소리를 즉시 끄면서 새 플레이어 재생 및 볼륨 병렬 실행
    await Future.wait([
      oldPlayer.setVolume(0.0),
      if (wasPlaying) standby.play(),
      standby.setVolume(100.0),
    ]);
    oldPlayer.pause().catchError((_) {});

    _player = standby;
    _controller = standbyCtrl;
    _standbyPlayer = null;
    _standbyController = null;
    _isStandbyFrameReady = false;
    if (playUrl.contains('127.0.0.1')) {
      _activeProxyStreamUrl = playUrl;
    } else {
      _activeProxyStreamUrl = null;
    }

    _bindPlayerStreams(_player);
    // 자막 안전망 재검증
    _reapplySubtitleToPlayer(_player);

    if (mounted) {
      setState(() {
        _currentQuality = targetQuality;
        _isSwitchingQuality = false;
      });

      final actualW = _player.state.width;
      final actualH = _player.state.height;
      final resInfo = (actualW != null && actualH != null && actualW > 0 && actualH > 0)
          ? ' (${actualW}x$actualH)'
          : '';

      if (isFallbackToOriginal) {
        _showNotificationBanner(
          message: '선택한 화질(${targetQuality.label})을 지원하지 않아 원본$resInfo으로 재생됩니다.',
          icon: Icons.warning_amber_rounded,
          iconColor: Colors.orangeAccent,
          duration: const Duration(seconds: 4),
        );
      } else {
        _showNotificationBanner(
          message: '화질 전환 완료: ${targetQuality.label}$resInfo',
          icon: Icons.check_circle_outline,
          iconColor: Colors.greenAccent,
          duration: const Duration(seconds: 2),
        );
      }
    }

    // 구 플레이어 및 구 프록시 세션 지연 정리
    Future.delayed(const Duration(milliseconds: 600), () {
      oldPlayer.dispose().catchError((_) {});
      if (oldProxyUrl != null && oldProxyUrl != _activeProxyStreamUrl) {
        LocalStreamProxy.instance.unregisterStream(oldProxyUrl);
      }
    });

    return true;
  }

  /// 단일 플레이어 프레임 프리즈 폴백 (저사양/단일 디코더 기기 대응)
  Future<void> _fallbackSinglePlayerSwitch({
    required String playUrl,
    required Map<String, String> headers,
    required VideoQuality targetQuality,
    required int token,
    required bool isFallbackToOriginal,
  }) async {
    _disposeStandbyPlayer();

    // 1. 검은 화면 방지용 스냅샷 캡처
    try {
      final shot = await _player.screenshot(format: 'image/jpeg');
      if (shot != null && shot.isNotEmpty && mounted) {
        setState(() {
          _freezeFrameBytes = shot;
        });
      }
    } catch (_) {}

    final currentPos = _player.state.position;
    final activeSub = _player.state.track.subtitle;
    final externalSubFile = _activeExternalSubtitleFile;
    final savedSubName = _currentSubtitleName;
    final savedSubLang = _currentSubtitleLanguage;
    final savedSubType = _currentSubtitleType;

    final oldProxyUrl = _activeProxyStreamUrl;
    if (playUrl.contains('127.0.0.1')) {
      _activeProxyStreamUrl = playUrl;
    } else {
      _activeProxyStreamUrl = null;
    }

    await _player.open(
      Media(
        playUrl,
        httpHeaders: headers.isNotEmpty ? headers : null,
        start: currentPos,
      ),
      play: true,
    );

    _ensureAutoPlay();

    // 새 스트림 첫 프레임 렌더링 감지 시 프리즈 오버레이 해제
    StreamSubscription? frameSub;
    frameSub = _player.stream.buffering.listen((buffering) {
      if (!buffering && _player.state.playing && mounted) {
        setState(() {
          _freezeFrameBytes = null;
          _isSwitchingQuality = false;
          _currentQuality = targetQuality;
        });
        frameSub?.cancel();
      }
    });
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted && _freezeFrameBytes != null) {
        setState(() {
          _freezeFrameBytes = null;
          _isSwitchingQuality = false;
          _currentQuality = targetQuality;
        });
      }
      frameSub?.cancel();
    });

    if (savedSubType != 'none') {
      if (externalSubFile != null && externalSubFile.existsSync()) {
        final subTrack = SubtitleTrack.uri(
          externalSubFile.path,
          title: savedSubName,
          language: savedSubLang ?? 'ko',
        );
        _pendingInitialSubtitleTrack = subTrack;
      } else if (activeSub.id != 'no') {
        _player.setSubtitleTrack(activeSub).catchError((_) {});
      }
      _reapplySubtitleToPlayer(_player);
    }

    if (oldProxyUrl != null && oldProxyUrl != _activeProxyStreamUrl) {
      LocalStreamProxy.instance.unregisterStream(oldProxyUrl);
    }
  }

  /// 화질 선택 다이얼로그 노출
  void _openQualityDialog() {
    _startHideTimer();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        final screenHeight = MediaQuery.of(ctx).size.height;
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: screenHeight * 0.85,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
                  child: Row(
                    children: [
                      const Icon(Icons.hd_outlined, color: Colors.blueAccent),
                      const SizedBox(width: 10),
                      const Text(
                        '해상도(화질) 선택',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white70),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                ),
                const Divider(color: Colors.white12, height: 1),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ..._availableQualities.map((quality) {
                          final isSelected = quality == _currentQuality;
                          return ListTile(
                            leading: Icon(
                              isSelected ? Icons.radio_button_checked : Icons.radio_button_off,
                              color: isSelected ? Colors.blueAccent : Colors.white38,
                            ),
                            title: Text(
                              quality.label,
                              style: TextStyle(
                                color: isSelected ? Colors.blueAccent : Colors.white,
                                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                              ),
                            ),
                            subtitle: quality.isOriginal
                                ? const Text(
                                    '무료 계정 속도 제한으로 버퍼링이 발생할 수 있습니다.',
                                    style: TextStyle(color: Colors.white38, fontSize: 11),
                                  )
                                : (quality == VideoQuality.q360p
                                    ? const Text(
                                        '저속 회선/무료 계정에 최적화된 빠른 시작 모드',
                                        style: TextStyle(color: Colors.white38, fontSize: 11),
                                      )
                                    : null),
                            onTap: () {
                              Navigator.pop(ctx);
                              _switchQuality(quality);
                            },
                          );
                        }),
                        const SizedBox(height: 12),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildNotificationBanner() {
    if (_bannerMessage == null) return const SizedBox.shrink();

    return Positioned(
      bottom: 110,
      left: 20,
      right: 20,
      child: Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 540),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.black.withAlpha(140),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.white.withAlpha(50), width: 0.8),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withAlpha(70),
                blurRadius: 8,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_bannerIcon != null) ...[
                Icon(_bannerIcon, color: _bannerIconColor ?? Colors.blueAccent, size: 18),
                const SizedBox(width: 8),
              ],
              Flexible(
                child: Text(
                  _bannerMessage!,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (_bannerActionLabel != null && _bannerAction != null) ...[
                const SizedBox(width: 12),
                TextButton(
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.amber,
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: () {
                    final act = _bannerAction;
                    _dismissBanner();
                    act?.call();
                  },
                  child: Text(
                    _bannerActionLabel!,
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  ),
                ),
              ],
              const SizedBox(width: 6),
              InkWell(
                onTap: _dismissBanner,
                borderRadius: BorderRadius.circular(14),
                child: const Padding(
                  padding: EdgeInsets.all(3.0),
                  child: Icon(Icons.close, size: 16, color: Colors.white60),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white, size: 28),
            onPressed: () async {
              await _exitFullScreen();
              if (!_hasCapturedThumbnail && _player.state.position >= const Duration(seconds: 2)) {
                await _captureThumbnailIfNeeded(force: true);
              }
              _saveCurrentPosition();
              if (mounted) Navigator.pop(context);
            },
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        widget.item.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _buildHwSwBadge(),
                  ],
                ),
                Text(
                  '${widget.service.account.name} • ${widget.item.formattedSize}',
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.subtitles, color: Colors.white),
            tooltip: '자막 설정 (SMI/SRT/다국어)',
            onPressed: _openSubtitleDialog,
          ),
          IconButton(
            icon: Stack(
              clipBehavior: Clip.none,
              children: [
                const Icon(Icons.hd_outlined, color: Colors.white),
                if (_currentQuality != VideoQuality.original)
                  Positioned(
                    right: -4,
                    bottom: -2,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
                      decoration: BoxDecoration(
                        color: Colors.blueAccent,
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: Text(
                        _currentQuality.id.replaceAll('p', ''),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 8,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            tooltip: '해상도(화질) 선택: ${_currentQuality.label}',
            onPressed: _openQualityDialog,
          ),
          if (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS)
            PopupMenuButton<PlayerOrientationMode>(
              icon: Icon(
                _getOrientationIcon(_orientationMode),
                color: Colors.white,
              ),
              tooltip: '화면 회전 모드: ${_orientationMode.label}',
              initialValue: _orientationMode,
              onSelected: (mode) {
                _setOrientationMode(mode);
                _startHideTimer();
              },
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: PlayerOrientationMode.landscape,
                  child: Row(
                    children: [
                      Icon(Icons.screen_lock_landscape, size: 20, color: Colors.white70),
                      SizedBox(width: 8),
                      Text('가로 고정'),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: PlayerOrientationMode.portrait,
                  child: Row(
                    children: [
                      Icon(Icons.screen_lock_portrait, size: 20, color: Colors.white70),
                      SizedBox(width: 8),
                      Text('세로 고정'),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: PlayerOrientationMode.sensor,
                  child: Row(
                    children: [
                      Icon(Icons.screen_rotation, size: 20, color: Colors.white70),
                      SizedBox(width: 8),
                      Text('센서 자동 가변'),
                    ],
                  ),
                ),
              ],
            ),
          IconButton(
            icon: Icon(
              _isFullScreen ? Icons.fullscreen_exit : Icons.fullscreen,
              color: Colors.white,
            ),
            tooltip: _isFullScreen ? '전체화면 종료 (ESC / 더블클릭)' : '전체화면 (더블클릭)',
            onPressed: _toggleFullScreen,
          ),
        ],
      ),
    );
  }

  Widget _buildCenterPlayPause({double size = 72}) {
    return StreamBuilder<bool>(
      stream: _player.stream.playing,
      initialData: _player.state.playing,
      builder: (context, playSnap) {
        final isPlaying = playSnap.data ?? _player.state.playing;
        return StreamBuilder<bool>(
          stream: _player.stream.buffering,
          initialData: _player.state.buffering,
          builder: (context, bufSnap) {
            final isBuffering = bufSnap.data ?? _player.state.buffering;
            if (_isLoading || isBuffering) {
              return Container(
                width: size + 16,
                height: size + 16,
                padding: const EdgeInsets.all(14),
                decoration: const BoxDecoration(
                  color: Colors.black54,
                  shape: BoxShape.circle,
                ),
                child: const CircularProgressIndicator(
                  color: Colors.blueAccent,
                  strokeWidth: 3.5,
                ),
              );
            }
            final showPlaying = _optimisticPlaying ?? isPlaying;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              // 손가락이 닿는 즉시 반응 (onTap의 지연 없이)
              onTapDown: (_) {
                _togglePlayPause();
                _startHideTimer();
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                child: Icon(
                  showPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled,
                  size: size,
                  color: Colors.white.withAlpha(220),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildBottomControls() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 탐색 슬라이더 (Seek Bar)
          StreamBuilder<Duration>(
            stream: _player.stream.position,
            builder: (context, posSnap) {
              final position = posSnap.data ?? Duration.zero;
              return StreamBuilder<Duration>(
                stream: _player.stream.duration,
                builder: (context, durSnap) {
                  final streamDuration = durSnap.data ?? Duration.zero;
                  final effectiveDuration = streamDuration > Duration.zero
                      ? streamDuration
                      : _totalDuration;
                  final maxMs = effectiveDuration.inMilliseconds.toDouble();
                  final hasDuration = maxMs > 0;
                  final displayPosition = _dragPosition ?? position;
                  final curMs = hasDuration
                      ? displayPosition.inMilliseconds.toDouble().clamp(0.0, maxMs)
                      : 0.0;

                  return Column(
                    children: [
                      SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          thumbColor: hasDuration ? Colors.blueAccent : Colors.grey,
                          activeTrackColor: Colors.blueAccent,
                          inactiveTrackColor: Colors.white24,
                          trackHeight: 4,
                          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                        ),
                        child: Slider(
                          value: curMs,
                          min: 0.0,
                          max: hasDuration ? maxMs : 1.0,
                          onChangeStart: hasDuration
                              ? (val) {
                                  _cancelAutoResume();
                                  _hideControlsTimer?.cancel();
                                  setState(() {
                                    _dragPosition = Duration(milliseconds: val.toInt());
                                  });
                                }
                              : null,
                          onChanged: hasDuration
                              ? (val) {
                                  setState(() {
                                    _dragPosition = Duration(milliseconds: val.toInt());
                                  });
                                }
                              : null,
                          onChangeEnd: hasDuration
                              ? (val) {
                                  final target = Duration(milliseconds: val.toInt());
                                  setState(() {
                                    _dragPosition = null;
                                  });
                                  _safeSeek(target);
                                  _startHideTimer();
                                }
                              : null,
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              _formatDuration(displayPosition),
                              style: const TextStyle(color: Colors.white70, fontSize: 12),
                            ),
                            Text(
                              hasDuration ? _formatDuration(effectiveDuration) : '--:--',
                              style: const TextStyle(color: Colors.white70, fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              );
            },
          ),

          // 프로그레스 바 아래: 10초 뒤로 / 재생·일시정지 / 10초 앞으로 / 배속
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(width: 48), // 배속 버튼과의 대칭을 위한 여백
              IconButton(
                iconSize: 36,
                icon: const Icon(Icons.replay_10, color: Colors.white),
                tooltip: '10초 뒤로',
                onPressed: () {
                  final target = _player.state.position - const Duration(seconds: 10);
                  _safeSeek(target < Duration.zero ? Duration.zero : target);
                  _startHideTimer();
                },
              ),
              const SizedBox(width: 16),
              _buildCenterPlayPause(size: 56),
              const SizedBox(width: 16),
              IconButton(
                iconSize: 36,
                icon: const Icon(Icons.forward_10, color: Colors.white),
                tooltip: '10초 앞으로',
                onPressed: () {
                  final target = _player.state.position + const Duration(seconds: 10);
                  _safeSeek(target);
                  _startHideTimer();
                },
              ),
              const SizedBox(width: 8),
              // 배속 변경 버튼
              PopupMenuButton<double>(
                tooltip: '재생 배속',
                initialValue: _playbackSpeed,
                onSelected: (speed) {
                  setState(() => _playbackSpeed = speed);
                  _player.setRate(speed);
                  _startHideTimer();
                },
                itemBuilder: (context) => [
                  for (final s in [0.75, 1.0, 1.25, 1.5, 1.75, 2.0])
                    PopupMenuItem(
                      value: s,
                      child: Text('${s}x',
                          style: TextStyle(
                              fontWeight: _playbackSpeed == s ? FontWeight.bold : FontWeight.normal)),
                    ),
                ],
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.white38),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    '${_playbackSpeed}x',
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
