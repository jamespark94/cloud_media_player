import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';
import '../../models/media_item.dart';
import '../../services/cloud_service_interface.dart';
import '../../services/local_stream_proxy.dart';
import '../../services/playback_history_service.dart';
import '../../utils/subtitle_utils.dart';
import '../widgets/subtitle_dialog.dart';

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

class _PlayerScreenState extends State<PlayerScreen> {
  late final Player _player;
  late final VideoController _controller;
  bool _isLoading = true;
  String? _errorMessage;
  bool _showControls = true;
  Timer? _hideControlsTimer;
  double _playbackSpeed = 1.0;
  Duration _totalDuration = Duration.zero;
  Duration? _dragPosition;
  bool _isFullScreen = false;

  StreamSubscription? _autoPlaySub;
  StreamSubscription? _tracksSub;
  StreamSubscription? _completedSub;
  StreamSubscription? _positionSub;
  Timer? _positionSaveTimer;
  bool _hasAutoSelectedSubtitle = false;
  bool _hasResumed = false;

  // 이전 시청 시 사용한 자막 파일 및 언어 설정 기억 변수
  String? _currentSubtitleType;
  String? _currentSubtitleId;
  String? _currentSubtitleName;
  String? _currentSubtitleLanguage;

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
    _totalDuration = widget.item.duration ?? Duration.zero;
    _player = Player();
    _controller = VideoController(_player);
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

      // 2. 외부 자막(클라우드/로컬) 로딩 중 비디오 내장 영어 자막 노출 방지
      if ((_currentSubtitleType == 'cloud' || _currentSubtitleType == 'local') && !_hasAutoSelectedSubtitle) {
        final activeTrack = _player.state.track.subtitle;
        if (activeTrack.id != 'no' && !_isKoreanTrack(activeTrack)) {
          _player.setSubtitleTrack(SubtitleTrack.no());
        }
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
      if (!_hasAutoSelectedSubtitle) {
        if (_currentSubtitleType == 'track') {
          _restoreTrackSubtitle(tracks.subtitle);
        } else if (_currentSubtitleType == null) {
          _selectKoreanTrack(tracks.subtitle);
        }
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

      // libmpv 자막 우선순위 (한국어) 및 인코딩(CP949/EUC-KR) 자동 감지 설정
      try {
        await (_player.platform as dynamic)?.setProperty('slang', 'ko,kor,korean,kr');
        await (_player.platform as dynamic)?.setProperty('sub-codepage', 'auto:cp949');
      } catch (_) {}

      // 2. 직접 스트림 URL 및 인증 헤더 획득 (libmpv 직접 고속 스트리밍)
      await widget.service.refreshTokensIfNeeded();
      final directUrl = await widget.service.getStreamUrl(widget.item);
      final headers = await widget.service.getStreamHeaders();

      await _player.open(
        Media(
          directUrl,
          httpHeaders: headers,
        ),
        play: true,
      );

      _ensureAutoPlay();

      if (resumePos != null && resumePos > const Duration(seconds: 5)) {
        _resumeToPosition(resumePos);
      }

      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
      _startHideTimer();
      _restoreOrAutoLoadSubtitle();
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
        await _player.open(Media(streamUrl), play: true);
        _ensureAutoPlay();

        if (resumePos != null && resumePos > const Duration(seconds: 5)) {
          _resumeToPosition(resumePos);
        }

        if (mounted) {
          setState(() {
            _isLoading = false;
          });
        }
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

    // 백그라운드 감시 루프: 로딩 완료 시점 즉시 100% 자동 재생 보장
    Future.microtask(() async {
      for (int i = 0; i < 15; i++) {
        await Future.delayed(const Duration(milliseconds: 200));
        if (!mounted) return;
        if (_player.state.playing) {
          _autoPlaySub?.cancel();
          break;
        }
        await _player.play();
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

  Future<void> _toggleFullScreen() async {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      final isFull = await windowManager.isFullScreen();
      await windowManager.setFullScreen(!isFull);
      if (mounted) {
        setState(() {
          _isFullScreen = !isFull;
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
    }
  }

  void _openSubtitleDialog() {
    _hideControlsTimer?.cancel();
    showDialog(
      context: context,
      builder: (_) => SubtitleDialog(
        player: _player,
        item: widget.item,
        service: widget.service,
        onSubtitleChanged: (type, id, name, language) {
          _currentSubtitleType = type;
          _currentSubtitleId = id;
          _currentSubtitleName = name;
          _currentSubtitleLanguage = language;
          _saveCurrentPosition();
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
      final subItem = items.firstWhere(
        (it) => it.isSubtitle && (it.id == cloudId || (cloudName != null && it.name == cloudName)),
        orElse: () => items.firstWhere(
          (it) => it.isSubtitle && SubtitleUtils.isSubtitleForVideo(it.name, widget.item.name),
          orElse: () => MediaItem(id: '', name: '', isFolder: false),
        ),
      );

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
    if (_player.state.playing) {
      _captureThumbnailIfNeeded(force: true);
    }
    _player.playOrPause();
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
    }
  }

  void _resumeToPosition(Duration target) {
    if (_hasResumed) return;

    // 즉시 목표 위치로 탐색 요청
    _player.seek(target);

    // 스트림이 완전히 로딩되어 재생이 개시될 때 확실하게 위치를 복구
    Timer.periodic(const Duration(milliseconds: 250), (timer) {
      if (!mounted || _hasResumed) {
        timer.cancel();
        return;
      }
      final currentPos = _player.state.position;
      if (currentPos >= target - const Duration(seconds: 2)) {
        _hasResumed = true;
        timer.cancel();
        _showResumeNotice(target);
      } else if (_player.state.playing && currentPos > Duration.zero) {
        _player.seek(target);
        _hasResumed = true;
        timer.cancel();
        _showResumeNotice(target);
      } else if (timer.tick > 20) {
        _hasResumed = true;
        timer.cancel();
      }
    });
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

  @override
  void dispose() {
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
        canPop: true,
        onPopInvokedWithResult: (didPop, result) async {
          if (!_hasCapturedThumbnail && _player.state.position >= const Duration(seconds: 2)) {
            await _captureThumbnailIfNeeded(force: true);
          }
          _saveCurrentPosition();
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
            _player.seek(target);
          },
          const SingleActivator(LogicalKeyboardKey.arrowLeft): () {
            final target = _player.state.position - const Duration(seconds: 10);
            _player.seek(target < Duration.zero ? Duration.zero : target);
          },
        },
        child: Focus(
          autofocus: true,
          child: MouseRegion(
            onHover: (event) {
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
              // 마우스 포인터가 화면 밖으로 벗어난 경우 즉시 UI 숨김
              if (_showControls && _dragPosition == null && _player.state.playing) {
                _hideControlsTimer?.cancel();
                setState(() => _showControls = false);
              }
            },
            child: GestureDetector(
              onTap: _toggleControls,
              onDoubleTap: _toggleFullScreen,
              behavior: HitTestBehavior.opaque,
              child: Stack(
                children: [
                  // 1. 비디오 화면 렌더링
                  Center(
                    child: Video(
                      controller: _controller,
                      controls: NoVideoControls,
                    ),
                  ),

                  // 2. 로딩 인디케이터
                  if (_isLoading)
                    const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(color: Colors.blueAccent),
                          SizedBox(height: 16),
                          Text('클라우드에서 스트림 연결 중...',
                              style: TextStyle(color: Colors.white70)),
                        ],
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
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                // 상단 헤더 바
                                _buildTopBar(),

                                // 중앙 재생/일시정지 버튼
                                _buildCenterPlayPause(),

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
                ],
              ),
            ),
          ),
        ),
      ),
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
                Text(
                  widget.item.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
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

  Widget _buildCenterPlayPause() {
    return StreamBuilder<bool>(
      stream: _player.stream.playing,
      builder: (context, snapshot) {
        final isPlaying = snapshot.data ?? false;
        return StreamBuilder<bool>(
          stream: _player.stream.buffering,
          builder: (context, bufSnap) {
            final isBuffering = bufSnap.data ?? false;
            if (isBuffering && isPlaying) {
              return const SizedBox(
                width: 72,
                height: 72,
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: CircularProgressIndicator(color: Colors.white, strokeWidth: 3),
                ),
              );
            }
            return IconButton(
              iconSize: 72,
              icon: Icon(
                isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled,
                color: Colors.white.withAlpha(220),
              ),
              onPressed: () {
                _player.playOrPause();
                _startHideTimer();
              },
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
                                  _player.seek(target);
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
          const SizedBox(height: 4),

          // 컨트롤 하단 버튼 그룹 (10초 건너뛰기, 배속, 자막, 전체화면 등)
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  StreamBuilder<bool>(
                    stream: _player.stream.playing,
                    builder: (context, snapshot) {
                      final isPlaying = snapshot.data ?? false;
                      return IconButton(
                        icon: Icon(
                          isPlaying ? Icons.pause : Icons.play_arrow,
                          color: Colors.white,
                        ),
                        tooltip: isPlaying ? '일시 정지 (Space)' : '재생 (Space)',
                        onPressed: () {
                          _togglePlayPause();
                          _startHideTimer();
                        },
                      );
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.replay_10, color: Colors.white),
                    tooltip: '10초 뒤로',
                    onPressed: () {
                      final target = _player.state.position - const Duration(seconds: 10);
                      _player.seek(target < Duration.zero ? Duration.zero : target);
                      _startHideTimer();
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.forward_10, color: Colors.white),
                    tooltip: '10초 앞으로',
                    onPressed: () {
                      final target = _player.state.position + const Duration(seconds: 10);
                      _player.seek(target);
                      _startHideTimer();
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.subtitles, color: Colors.white70, size: 22),
                    tooltip: '자막 설정 (SMI/SRT)',
                    onPressed: _openSubtitleDialog,
                  ),
                ],
              ),
              Row(
                children: [
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
                  const SizedBox(width: 8),
                  IconButton(
                    icon: Icon(
                      _isFullScreen ? Icons.fullscreen_exit : Icons.fullscreen,
                      color: Colors.white,
                    ),
                    tooltip: _isFullScreen ? '전체화면 종료 (ESC)' : '전체화면',
                    onPressed: _toggleFullScreen,
                  ),
                ],
              )
            ],
          ),
        ],
      ),
    );
  }
}
