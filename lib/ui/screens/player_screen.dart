import 'dart:async';
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
import '../../models/media_item.dart';
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
  late final Player _player;
  late final VideoController _controller;
  bool _isLoading = true;
  String? _errorMessage;
  bool _showControls = true;
  Timer? _hideControlsTimer;
  double _playbackSpeed = 1.0;
  Duration _totalDuration = Duration.zero;
  Duration? _dragPosition;
  bool _isFullScreen = !Platform.isWindows && !Platform.isLinux && !Platform.isMacOS;

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

  // 비디오 위젯 상태 보존용 키 (필터 래퍼 토글 시 재생성 방지)
  final GlobalKey _videoKey = GlobalKey();

  // 오디오 포커스 세션 관리 (유튜브 등 타 앱 오디오 제어)
  AudioSession? _audioSession;
  StreamSubscription? _interruptionSub;
  StreamSubscription? _becomingNoisySub;
  StreamSubscription? _playingSub;

  // 하드웨어 가속 상태 관리
  bool _isHwDec = true;

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
  bool _isApplyingSubtitle = false;
  Duration? _pendingSeekAfterSubtitle;

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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _totalDuration = widget.item.duration ?? Duration.zero;
    _player = Player(
      configuration: const PlayerConfiguration(
        bufferSize: 64 * 1024 * 1024,
      ),
    );
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
    _controller = VideoController(_player, configuration: videoConfig);
    _player.stream.duration.listen((d) {
      if (d > Duration.zero && mounted) {
        setState(() {
          _totalDuration = d;
        });
      }
    });

    _tracksSub = _player.stream.tracks.listen((tracks) {
      if (!mounted) return;

      // 1. 자막 끄기 설정이면 'no' 유지
      if (_currentSubtitleType == 'none') {
        if (_player.state.track.subtitle.id != 'no') {
          _player.setSubtitleTrack(SubtitleTrack.no());
        }
        return;
      }

      // 이미 자막 트랙이 선택되었거나 로드된 경우 중복 호출 차단 (디먹서 재시작 방지)
      if (_hasAutoSelectedSubtitle) return;

      // 2. 외부 자막(클라우드/로컬) 로딩 중 비디오 내장 영어 자막 노출 방지
      if (_currentSubtitleType == 'cloud' || _currentSubtitleType == 'local') {
        final activeTrack = _player.state.track.subtitle;
        if (activeTrack.id != 'no' && !_isKoreanTrack(activeTrack)) {
          _player.setSubtitleTrack(SubtitleTrack.no());
        }
        return;
      }

      // 3. SAMI의 KRCC 트랙이 감지되면 즉시 한국어 트랙으로 전환
      for (final track in tracks.subtitle) {
        final title = (track.title ?? '').toLowerCase();
        if (title.contains('krcc')) {
          final active = _player.state.track.subtitle;
          if (active.id != track.id) {
            _player.setSubtitleTrack(track);
            _hasAutoSelectedSubtitle = true;
          }
          return;
        }
      }

      // 4. 내장 자막 복원 또는 한국어 트랙 자동 선택
      if (_currentSubtitleType == 'track') {
        _restoreTrackSubtitle(tracks.subtitle);
      } else if (_currentSubtitleType == null) {
        _selectKoreanTrack(tracks.subtitle);
      }
    });

    // 영상 시청 완료 시 이어보기 기록 삭제 (자막 설정은 보존)
    _completedSub = _player.stream.completed.listen((completed) {
      if (completed) {
        PlaybackHistoryService.instance.clearPosition(
          accountId: widget.service.account.id,
          item: widget.item,
        );
      }
    });

    // 재생 중 5초 이상 구간 진입 시 즉시 썸네일 자동 캡처
    _positionSub = _player.stream.position.listen((pos) {
      if (!_hasCapturedThumbnail && pos >= const Duration(seconds: 5) && _player.state.playing) {
        _captureThumbnailIfNeeded();
      }
    });

    // 5초마다 시청 위치 주기적 자동 저장
    _positionSaveTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _saveCurrentPosition();
    });

    _optimisticClearSub = _player.stream.playing.listen((_) {
      if (mounted && _optimisticPlaying != null) {
        setState(() => _optimisticPlaying = null);
      }
    });

    // 재생 상태 감지: 재생 시 Audio Focus 획득 (유튜브 등 타 앱 자동 일시정지), 일시정지 시 포커스 해제
    _playingSub = _player.stream.playing.listen((playing) async {
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

    _initAudioSession();
    _initContrast();
    _initVolume();
    SubtitleSettingsService.instance.init();
    if (_isFullScreen) {
      _applyMobileFullScreen(true);
    }
    _initAndPlay();
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

      // libmpv 자막 우선순위 및 고성능 네트워크 스트리밍 버퍼 캐시 설정
      try {
        final platform = (_player.platform as dynamic);
        await platform?.setProperty('slang', 'ko,kor,korean,kr');
        await platform?.setProperty('sub-codepage', 'auto:cp949');
        await platform?.setProperty('demuxer-max-bytes', '67108864'); // 64MB 대용량 버퍼
        await platform?.setProperty('demuxer-max-back-bytes', '33554432'); // 32MB 역방향 캐시
        await platform?.setProperty('demuxer-readahead-secs', '30'); // 30초 선행 버퍼링
        await platform?.setProperty('cache', 'yes');
        await platform?.setProperty('cache-secs', '30');
        await platform?.setProperty('network-timeout', '15');
        await platform?.setProperty('force-seekable', 'yes');
        await platform?.setProperty('hr-seek', 'default');
      } catch (_) {}

      // 2. 외부 자막 사전 탐색 및 다운로드 (재생 도중 네트워크 대역폭 잠식 및 디먹서 3회 재시작 방지)
      File? initialSubtitleFile;
      String? initialSubtitleName;

      final tempDir = Directory.systemTemp;
      if (_currentSubtitleType == 'cloud' && _currentSubtitleId != null) {
        final cached = File('${tempDir.path}/${_currentSubtitleId}_${_currentSubtitleName ?? ""}');
        if (cached.existsSync() && cached.lengthSync() > 0) {
          initialSubtitleFile = cached;
          initialSubtitleName = _currentSubtitleName;
        } else {
          // 타 기기에서 동기화되어 로컬 캐시가 없는 경우: 재생 시작 전 즉시 온디맨드 다운로드
          try {
            MediaItem? subToDownload;
            final parentId = widget.item.parentId ?? record?.parentId;
            if (parentId != null && parentId.isNotEmpty) {
              final items = await widget.service.listItems(folderId: parentId);
              subToDownload = items.cast<MediaItem?>().firstWhere(
                (it) => it != null && it.isSubtitle && (it.id == _currentSubtitleId || (_currentSubtitleName != null && it.name == _currentSubtitleName)),
                orElse: () => null,
              );
            }
            subToDownload ??= MediaItem(
              id: _currentSubtitleId!,
              name: _currentSubtitleName ?? 'subtitle',
              parentId: parentId,
              isFolder: false,
            );

            final url = await widget.service.getStreamUrl(subToDownload);
            final headers = await widget.service.getStreamHeaders();
            final res = await http.get(Uri.parse(url), headers: headers);
            if (res.statusCode == 200) {
              await cached.writeAsBytes(res.bodyBytes);
              initialSubtitleFile = cached;
              initialSubtitleName = _currentSubtitleName ?? subToDownload.name;
              _currentSubtitleId = subToDownload.id;
            }
          } catch (e) {
            debugPrint('클라우드 자막 온디맨드 다운로드 실패: $e');
          }
        }
      } else if (_currentSubtitleType == 'local' && _currentSubtitleId != null) {
        final local = File(_currentSubtitleId!);
        if (local.existsSync() && local.lengthSync() > 0) {
          initialSubtitleFile = local;
          initialSubtitleName = _currentSubtitleName;
        }
      } else if (_currentSubtitleType == null && widget.item.parentId != null) {
        try {
          final items = await widget.service.listItems(folderId: widget.item.parentId!);
          final videoName = widget.item.name;
          final matchingSubs = items.where((it) => it.isSubtitle && SubtitleUtils.isSubtitleForVideo(it.name, videoName)).toList();
          if (matchingSubs.isNotEmpty) {
            matchingSubs.sort((a, b) => SubtitleUtils.koreanScore(b.name).compareTo(SubtitleUtils.koreanScore(a.name)));
            final selectedSub = matchingSubs.first;
            final file = File('${tempDir.path}/${selectedSub.id}_${selectedSub.name}');
            if (file.existsSync() && file.lengthSync() > 0) {
              initialSubtitleFile = file;
            } else {
              final url = await widget.service.getStreamUrl(selectedSub);
              final headers = await widget.service.getStreamHeaders();
              final res = await http.get(Uri.parse(url), headers: headers);
              if (res.statusCode == 200) {
                await file.writeAsBytes(res.bodyBytes);
                initialSubtitleFile = file;
              }
            }
            if (initialSubtitleFile != null) {
              initialSubtitleName = selectedSub.name;
              _currentSubtitleType = 'cloud';
              _currentSubtitleId = selectedSub.id;
              _currentSubtitleName = selectedSub.name;
              _currentSubtitleLanguage = 'ko';
            }
          }
        } catch (_) {}
      }

      // 3. 직접 스트림 URL 및 인증 헤더 획득 (libmpv 직접 고속 스트리밍)
      await widget.service.refreshTokensIfNeeded();
      final directUrl = await widget.service.getStreamUrl(widget.item);
      final headers = await widget.service.getStreamHeaders();

      // 4. Media에 start: resumePos를 전달하여 첫 프레임부터 이전 위치에서 디코딩 개시!
      await _player.open(
        Media(
          directUrl,
          httpHeaders: headers,
          start: resumePos,
        ),
        play: true,
      );

      _ensureAutoPlay();

      // 5. 다운로드 완료된 외부 자막이 있으면 즉시 단 1회만 연결
      if (initialSubtitleFile != null && initialSubtitleFile.existsSync()) {
        await _player.setSubtitleTrack(
          SubtitleTrack.uri(initialSubtitleFile.path, title: initialSubtitleName, language: _currentSubtitleLanguage ?? 'ko'),
        );
        _hasAutoSelectedSubtitle = true;
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
      } else {
        _restoreOrAutoLoadSubtitle();
      }

      // 6. 첫 스트림 재생 준비 감지 (최대 3초) 후 로딩 스피너 종료
      try {
        final d = await _player.stream.duration.firstWhere((val) => val > Duration.zero).timeout(
          const Duration(seconds: 3),
          onTimeout: () => _totalDuration,
        );
        if (d > Duration.zero && mounted) {
          setState(() => _totalDuration = d);
          // 안전망: 만약 Media(start: resumePos)가 적용되지 않고 0초에서 시작되었다면 1회 보정
          if (resumePos != null && !_hasResumed && _player.state.position < const Duration(seconds: 3)) {
            _hasResumed = true;
            await _player.seek(resumePos);
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

        final streamUrl = LocalStreamProxy.instance.registerStream(widget.service, widget.item);
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
            if (resumePos != null && !_hasResumed && _player.state.position < const Duration(seconds: 3)) {
              _hasResumed = true;
              await _player.seek(resumePos);
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
      // 1. Flutter SystemChrome 가로모드 및 ImmersiveSticky 모드 적용
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      // 2. Android 플랫폼 네이티브 WindowInsetsController로 시스템 상태바(시간/날짜/배터리) 완전 숨김
      if (Platform.isAndroid) {
        try {
          const channel = MethodChannel('com.example.cloud_media_player/window');
          await channel.invokeMethod('setFullScreen', {'enable': true});
        } catch (_) {}
      }
    } else {
      // 1. Flutter SystemChrome 복원
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
      // 2. Android 네이티브 상태바 복원
      if (Platform.isAndroid) {
        try {
          const channel = MethodChannel('com.example.cloud_media_player/window');
          await channel.invokeMethod('setFullScreen', {'enable': false});
        } catch (_) {}
      }
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
          await _player.setSubtitleTrack(
            SubtitleTrack.uri(localFile.path, title: name ?? 'local', language: language ?? 'ko'),
          );
        }
      } else if (type == 'cloud' && id != null) {
        final tempDir = Directory.systemTemp;
        final cached = File('${tempDir.path}/${id}_${name ?? ""}');
        if (!cached.existsSync() || cached.lengthSync() == 0) {
          final subItem = MediaItem(id: id, name: name ?? 'subtitle', isFolder: false);
          final url = await widget.service.getStreamUrl(subItem);
          final headers = await widget.service.getStreamHeaders();
          final res = await http.get(Uri.parse(url), headers: headers);
          if (res.statusCode == 200) {
            await cached.writeAsBytes(res.bodyBytes);
          }
        }
        if (cached.existsSync() && cached.lengthSync() > 0) {
          await _player.setSubtitleTrack(
            SubtitleTrack.uri(cached.path, title: name, language: language ?? 'ko'),
          );
        }
      } else if (type == 'track' && id != null) {
        _restoreTrackSubtitle(_player.state.tracks.subtitle);
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
          final url = await widget.service.getStreamUrl(candidate);
          final headers = await widget.service.getStreamHeaders();
          final res = await http.get(Uri.parse(url), headers: headers);

          if (res.statusCode == 200) {
            final tempDir = Directory.systemTemp;
            final file = File('${tempDir.path}/${candidate.id}_${candidate.name}');
            await file.writeAsBytes(res.bodyBytes);

            final score = SubtitleUtils.koreanScore(candidate.name);
            final hasKorean = SubtitleUtils.hasKoreanContent(res.bodyBytes);

            // 파일명에 한국어 표기가 있거나 내용에 한글/KRCC가 포함된 경우 채택
            if (score >= 50 || hasKorean || selectedSub == null) {
              selectedSub = candidate;
              localSubFile = file;
              break;
            }
          }
        } catch (_) {}
      }

      if (selectedSub != null && localSubFile != null && mounted) {
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
        final url = await widget.service.getStreamUrl(subItem);
        final headers = await widget.service.getStreamHeaders();
        final res = await http.get(Uri.parse(url), headers: headers);

        if (res.statusCode == 200) {
          final tempDir = Directory.systemTemp;
          final localSubFile = File('${tempDir.path}/${subItem.id}_${subItem.name}');
          await localSubFile.writeAsBytes(res.bodyBytes);

          if (!mounted) return;
          await _player.setSubtitleTrack(
            SubtitleTrack.uri(localSubFile.path, title: subItem.name, language: lang ?? 'ko'),
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

  bool _restoreTrackSubtitle(List<SubtitleTrack> tracks) {
    for (final track in tracks) {
      if (track.id == 'no' || track.id == 'auto') continue;
      if (track.id == _currentSubtitleId) {
        _player.setSubtitleTrack(track);
        _hasAutoSelectedSubtitle = true;
        return true;
      }
    }
    for (final track in tracks) {
      if (track.id == 'no' || track.id == 'auto') continue;
      if (_currentSubtitleName != null &&
          (track.title ?? '').toLowerCase() == _currentSubtitleName!.toLowerCase()) {
        _player.setSubtitleTrack(track);
        _hasAutoSelectedSubtitle = true;
        return true;
      }
    }
    for (final track in tracks) {
      if (track.id == 'no' || track.id == 'auto') continue;
      if (_currentSubtitleLanguage != null && _isKoreanTrack(track)) {
        _player.setSubtitleTrack(track);
        _hasAutoSelectedSubtitle = true;
        return true;
      }
    }
    return false;
  }

  void _selectTrackByLanguage(String lang, String? title) {
    final tracks = _player.state.tracks.subtitle;
    for (final track in tracks) {
      if (track.id == 'no' || track.id == 'auto') continue;
      final tLang = (track.language ?? '').toLowerCase();
      final tTitle = (track.title ?? '').toLowerCase();
      if (tLang == lang.toLowerCase() || (title != null && tTitle == title.toLowerCase())) {
        _player.setSubtitleTrack(track);
        break;
      }
    }
  }

  bool _selectKoreanTrack(List<SubtitleTrack> tracks) {
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
      _player.setSubtitleTrack(targetTrack);
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
    _tracksSub?.cancel();
    _hideControlsTimer?.cancel();
    _exitFullScreen();
    _player.dispose();
    super.dispose();
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
                              key: _videoKey,
                              controller: _controller,
                              controls: NoVideoControls,
                              subtitleViewConfiguration: const SubtitleViewConfiguration(visible: false),
                            ),
                          )
                        : Video(
                            key: _videoKey,
                            controller: _controller,
                            controls: NoVideoControls,
                            subtitleViewConfiguration: const SubtitleViewConfiguration(visible: false),
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
