import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import '../../models/ai_subtitle/ai_subtitle_config.dart';
import '../../models/media_item.dart';
import '../../models/subtitle_settings.dart';
import '../../services/ai_subtitle/ai_subtitle_service.dart';
import '../../services/ai_subtitle/stt/whisper_isolate_worker.dart';
import '../../services/ai_subtitle/translators/subtitle_translator.dart';
import '../../services/cloud_service_interface.dart';
import '../../services/subtitle_settings_service.dart';
import '../../utils/subtitle_utils.dart';

class SubtitleDialog extends StatefulWidget {
  final Player player;
  final MediaItem item;
  final CloudService service;
  final void Function(String type, String? id, String? name, String? language)? onSubtitleChanged;
  final int initialTabIndex;

  const SubtitleDialog({
    super.key,
    required this.player,
    required this.item,
    required this.service,
    this.onSubtitleChanged,
    this.initialTabIndex = 0,
  });

  @override
  State<SubtitleDialog> createState() => _SubtitleDialogState();
}

class _SubtitleDialogState extends State<SubtitleDialog> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  bool _isLoadingCloudSubs = false;
  List<MediaItem> _cloudSubtitles = [];

  final TextEditingController _apiKeyController = TextEditingController();
  bool _obscureApiKey = true;
  bool _isSavingApiKey = false;
  bool _isExportingSrt = false;
  String? _aiInlineFeedback;
  bool _aiInlineFeedbackIsWarning = false;
  final Map<AiWhisperModelTier, bool> _downloadedWhisperModels = {};
  bool _isDownloadingWhisperModel = false;
  double _whisperDownloadProgress = 0.0;
  String? _whisperDownloadStatus;

  // Foreground 추천 색상 목록
  final List<Color> _textColors = const [
    Colors.white,
    Color(0xFFFFEB3B), // 노란색
    Color(0xFF69F0AE), // 연두색
    Color(0xFF80D8FF), // 하늘색
    Color(0xFFFFAB40), // 주황색
  ];

  // Background 추천 색상 목록
  final List<Color> _bgColors = const [
    Colors.black,
    Color(0xFF212121), // 진회색
    Color(0xFF0D1B2A), // 딥네이비
    Color(0xFF1A0B2E), // 딥퍼플
  ];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 2,
      vsync: this,
      initialIndex: widget.initialTabIndex.clamp(0, 1),
    );
    SubtitleSettingsService.instance.init();
    AiSubtitleService.instance.loadGeminiApiKey();
    _refreshWhisperModelStates();
    _findCloudSubtitles();
  }

  Future<void> _refreshWhisperModelStates() async {
    final results = <AiWhisperModelTier, bool>{};
    for (final tier in AiWhisperModelTier.values) {
      results[tier] = await WhisperIsolateWorker.isModelDownloaded(tier);
    }
    if (!mounted) return;
    setState(() {
      _downloadedWhisperModels
        ..clear()
        ..addAll(results);
    });
  }

  Future<void> _downloadWhisperModel(AiWhisperModelTier tier) async {
    if (_isDownloadingWhisperModel) return;
    setState(() {
      _isDownloadingWhisperModel = true;
      _whisperDownloadProgress = 0.0;
      _whisperDownloadStatus = 'Whisper ${tier.shortName} 모델 다운로드 준비 중...';
    });
    try {
      await WhisperIsolateWorker.ensureModelDownloaded(
        tier: tier,
        onProgress: (progress, status) {
          if (!mounted) return;
          setState(() {
            _whisperDownloadProgress = progress;
            _whisperDownloadStatus = status;
          });
        },
      );
      await _refreshWhisperModelStates();
      _setAiFeedback('Whisper ${tier.shortName} 모델 다운로드가 완료되었습니다.');
    } catch (e) {
      _setAiFeedback('Whisper 모델 다운로드 실패: $e', isWarning: true);
    } finally {
      if (mounted) {
        setState(() {
          _isDownloadingWhisperModel = false;
          _whisperDownloadStatus = null;
        });
      }
    }
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    _tabController.dispose();
    super.dispose();
  }

  void _setAiFeedback(String message, {bool isWarning = false}) {
    if (!mounted) return;
    setState(() {
      _aiInlineFeedback = message;
      _aiInlineFeedbackIsWarning = isWarning;
    });
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isWarning ? Colors.orange.shade800 : Colors.teal.shade700,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  Future<void> _saveGeminiApiKey() async {
    final input = _apiKeyController.text.trim();
    if (input.isEmpty) {
      _setAiFeedback('Gemini API 키를 입력해 주세요.', isWarning: true);
      return;
    }
    setState(() => _isSavingApiKey = true);
    try {
      await AiSubtitleService.instance.saveGeminiApiKey(input);
      _apiKeyController.clear();
      _setAiFeedback('Gemini API 키가 보안 저장소에 안전하게 저장되었습니다.');
    } catch (e) {
      _setAiFeedback('API 키 저장 중 오류가 발생했습니다: $e', isWarning: true);
    } finally {
      if (mounted) setState(() => _isSavingApiKey = false);
    }
  }

  Future<void> _deleteGeminiApiKey() async {
    setState(() => _isSavingApiKey = true);
    try {
      await AiSubtitleService.instance.deleteGeminiApiKey();
      _apiKeyController.clear();
      _setAiFeedback('저장된 Gemini API 키를 삭제했습니다.');
    } finally {
      if (mounted) setState(() => _isSavingApiKey = false);
    }
  }

  Future<void> _exportAiSubtitlesAsSrt(AiSubtitleDisplayMode displayMode) async {
    final ai = AiSubtitleService.instance;
    final srtContent = ai.exportCachedSubtitlesAsSrt(displayMode: displayMode);
    if (srtContent.trim().isEmpty) {
      _setAiFeedback('내보낼 수 있는 생성된 AI 자막이 아직 없습니다.', isWarning: true);
      return;
    }

    setState(() => _isExportingSrt = true);
    try {
      final baseName = SubtitleUtils.getBaseName(widget.item.name);
      final suggestedName = '${baseName}_ai.srt';
      final bytes = Uint8List.fromList(utf8.encode(srtContent));
      final savedUri = await FilePicker.saveFile(
        dialogTitle: 'AI 자막 파일 내보내기 (.srt)',
        fileName: suggestedName,
        type: FileType.custom,
        allowedExtensions: const ['srt'],
        bytes: bytes,
      );
      if (savedUri != null) {
        final displayPath =
            savedUri.scheme == 'file' ? savedUri.toFilePath() : savedUri.toString();
        _setAiFeedback('SRT 자막 저장 완료: $displayPath');
      }
    } catch (e) {
      _setAiFeedback('SRT 자막 내보내기에 실패했습니다: $e', isWarning: true);
    } finally {
      if (mounted) setState(() => _isExportingSrt = false);
    }
  }

  Future<void> _findCloudSubtitles() async {
    if (widget.item.parentId == null) return;
    setState(() => _isLoadingCloudSubs = true);
    try {
      final items = await widget.service.listItems(folderId: widget.item.parentId);
      if (mounted) {
        final subs = items.where((it) => it.isSubtitle).toList();
        // 비디오와 이름이 일치하는 자막 우선 정렬 + 한국어 우선 정렬
        subs.sort((a, b) {
          final aMatch = SubtitleUtils.isSubtitleForVideo(a.name, widget.item.name) ? 1 : 0;
          final bMatch = SubtitleUtils.isSubtitleForVideo(b.name, widget.item.name) ? 1 : 0;
          if (aMatch != bMatch) return bMatch.compareTo(aMatch);
          return SubtitleUtils.koreanScore(b.name).compareTo(SubtitleUtils.koreanScore(a.name));
        });
        setState(() {
          _cloudSubtitles = subs;
          _isLoadingCloudSubs = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isLoadingCloudSubs = false);
    }
  }

  Future<void> _pickLocalSubtitle() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['smi', 'srt', 'vtt', 'ass', 'ssa', 'sub'],
      dialogTitle: '자막 파일 선택 (SMI / SRT / VTT / ASS)',
    );

    if (files.isNotEmpty && files.first.path != null) {
      final filePath = files.first.path!;
      final fileName = files.first.name;

      // 사용자 탭 즉시 창을 닫아 지연감 해소
      if (mounted) {
        Navigator.pop(context);
      }
      widget.onSubtitleChanged?.call('local', filePath, fileName, 'ko');
    }
  }

  Future<void> _applyCloudSubtitle(MediaItem subItem) async {
    // 사용자 탭 즉시 창을 닫아 지연감 해소
    if (mounted) {
      Navigator.pop(context);
    }
    // 자막 다운로드 및 mpv 적용은 상위 PlayerScreen에서 비동기로 안전하게 인계
    widget.onSubtitleChanged?.call('cloud', subItem.id, subItem.name, 'ko');
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF1B202B),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: 540,
        constraints: const BoxConstraints(maxHeight: 680),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 다이얼로그 헤더
            Row(
              children: [
                const Icon(Icons.subtitles, color: Colors.blueAccent),
                const SizedBox(width: 10),
                const Text(
                  '자막 설정',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close, size: 20, color: Colors.white70),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // 탭 바 (자막 선택 / 자막 스타일)
            TabBar(
              controller: _tabController,
              indicatorColor: Colors.blueAccent,
              labelColor: Colors.blueAccent,
              unselectedLabelColor: Colors.white60,
              tabs: const [
                Tab(icon: Icon(Icons.list, size: 20), text: '자막 목록 / 트랙'),
                Tab(icon: Icon(Icons.tune, size: 20), text: '자막 스타일 설정'),
              ],
            ),
            const SizedBox(height: 12),

            // 탭 내용
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  _buildTrackListTab(),
                  _buildStyleSettingsTab(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 1. 자막 트랙 및 파일 선택 탭
  Widget _buildTrackListTab() {
    final currentSub = widget.player.state.track.subtitle;
    final availableSubs = widget.player.state.tracks.subtitle;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 1. 자막 끄기
          ListTile(
            dense: true,
            leading: Icon(
              currentSub.id == 'no' && !AiSubtitleService.instance.isEnabled
                  ? Icons.check_circle
                  : Icons.radio_button_unchecked,
              color: currentSub.id == 'no' && !AiSubtitleService.instance.isEnabled
                  ? Colors.blueAccent
                  : Colors.grey,
            ),
            title: const Text('자막 끄기', style: TextStyle(color: Colors.white)),
            onTap: () {
              if (AiSubtitleService.instance.isEnabled) {
                AiSubtitleService.instance.setEnabled(false);
              }
              widget.player.setSubtitleTrack(SubtitleTrack.no());
              widget.onSubtitleChanged?.call('none', 'no', '자막 끄기', null);
              Navigator.pop(context);
            },
          ),

          // [실험실] AI 실시간 자막 생성 (기본값: OFF)
          _buildAiSubtitleLabCard(),

          // 2. 영상 내장 자막 / 다국어 트랙 목록
          if (availableSubs.where((t) => t.id != 'no' && t.id != 'auto').isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                '영상 내장 자막 / 언어 트랙',
                style: TextStyle(color: Colors.blueAccent, fontSize: 13, fontWeight: FontWeight.bold),
              ),
            ),
            for (final track in availableSubs.where((t) => t.id != 'no' && t.id != 'auto')) ...[
              ListTile(
                dense: true,
                leading: Icon(
                  currentSub.id == track.id ? Icons.check_circle : Icons.radio_button_unchecked,
                  color: currentSub.id == track.id ? Colors.blueAccent : Colors.grey,
                ),
                title: Text(
                  track.title?.isNotEmpty == true
                      ? track.title!
                      : (track.language?.isNotEmpty == true ? '언어: ${track.language}' : '트랙 ${track.id}'),
                  style: const TextStyle(color: Colors.white),
                ),
                subtitle: track.language?.isNotEmpty == true && track.title?.isNotEmpty == true
                    ? Text('언어: ${track.language}', style: const TextStyle(fontSize: 11, color: Colors.grey))
                    : null,
                onTap: () {
                  widget.player.setSubtitleTrack(track);
                  widget.onSubtitleChanged?.call('track', track.id, track.title, track.language);
                  Navigator.pop(context);
                },
              ),
            ],
          ],

          // 3. 같은 클라우드 폴더 내의 자막 파일 (.smi, .srt 등)
          if (_cloudSubtitles.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                '클라우드 폴더 내 자막 파일',
                style: TextStyle(color: Colors.amber, fontSize: 13, fontWeight: FontWeight.bold),
              ),
            ),
            for (final sub in _cloudSubtitles) ...[
              Builder(
                builder: (context) {
                  final isSelected = currentSub.title == sub.name || currentSub.id.contains(sub.id);
                  final isMatch = SubtitleUtils.isSubtitleForVideo(sub.name, widget.item.name);
                  final isKorean = SubtitleUtils.koreanScore(sub.name) >= 50;

                  return ListTile(
                    dense: true,
                    leading: Icon(
                      isSelected ? Icons.check_circle : (isMatch ? Icons.cloud_download : Icons.cloud_outlined),
                      color: isSelected ? Colors.blueAccent : (isMatch ? Colors.amber : Colors.grey),
                      size: 20,
                    ),
                    title: Row(
                      children: [
                        Expanded(
                          child: Text(
                            sub.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: isSelected ? Colors.blueAccent : Colors.white,
                              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                            ),
                          ),
                        ),
                        if (isKorean)
                          Container(
                            margin: const EdgeInsets.only(left: 6),
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.blueAccent.withAlpha(40),
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(color: Colors.blueAccent.withAlpha(120)),
                            ),
                            child: const Text('한국어', style: TextStyle(fontSize: 10, color: Colors.blueAccent)),
                          ),
                      ],
                    ),
                    onTap: () => _applyCloudSubtitle(sub),
                  );
                },
              ),
            ],
          ] else if (_isLoadingCloudSubs) ...[
            const Padding(
              padding: EdgeInsets.all(16),
              child: Row(
                children: [
                  SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                  SizedBox(width: 12),
                  Text('클라우드 폴더 내 자막 검색 중...', style: TextStyle(color: Colors.grey, fontSize: 12)),
                ],
              ),
            ),
          ],

          const SizedBox(height: 12),

          // 4. 내 PC 로컬 파일에서 불러오기 버튼
          Center(
            child: OutlinedButton.icon(
              icon: const Icon(Icons.file_open, size: 18),
              label: const Text('내 PC에서 자막 파일 불러오기 (.smi / .srt)'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: const BorderSide(color: Colors.blueAccent),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              ),
              onPressed: _pickLocalSubtitle,
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  // [실험실] AI 실시간 자막 생성 카드 (기본값: OFF)
  Widget _buildAiSubtitleLabCard() {
    return ListenableBuilder(
      listenable: Listenable.merge([
        AiSubtitleService.instance,
        SubtitleSettingsService.instance,
      ]),
      builder: (context, _) {
        final ai = AiSubtitleService.instance;
        final settings = SubtitleSettingsService.instance.settings;
        final isOn = ai.isEnabled;
        final selectedEngine = settings.aiEngineType;
        final selectedTier = settings.aiWhisperModelTier;
        final isCloud = selectedEngine == AiSubtitleEngineType.cloudApi;
        final isOnDevice = selectedEngine == AiSubtitleEngineType.onDevice;
        final usesLocalWhisper = !isCloud;
        final isLocalTranslatorSupported =
            SubtitleTranslator.create().isTranslationSupported;
        final cachedCount = ai.cache.totalSegmentCount;

        final engineSubtitle = switch (selectedEngine) {
          AiSubtitleEngineType.cloudApi =>
            'Gemini 멀티모달 고품질 전사 + 한국어 의역 (${ai.config.cloudModelName})',
          AiSubtitleEngineType.freeHybrid =>
            '로컬 Whisper(${selectedTier.shortName}) + 무료 구글 번역 (무제한)',
          AiSubtitleEngineType.onDevice => isLocalTranslatorSupported
              ? '로컬 오프라인 Whisper(${selectedTier.shortName}) + ML Kit 번역'
              : '로컬 오프라인 원어 자막 STT (${selectedTier.shortName})',
        };

        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: isOn
                ? Colors.cyanAccent.withValues(alpha: 0.08)
                : Colors.white.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isOn ? Colors.cyanAccent.withValues(alpha: 0.45) : Colors.white12,
              width: 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                secondary: Icon(
                  Icons.auto_awesome,
                  color: isOn ? Colors.cyanAccent : Colors.white54,
                  size: 22,
                ),
                title: const Text(
                  '[실험실] AI 실시간 자막 생성',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                subtitle: Text(
                  engineSubtitle,
                  style: const TextStyle(color: Colors.white60, fontSize: 11),
                ),
                activeThumbColor: Colors.cyanAccent,
                value: isOn,
                onChanged: (val) async {
                  if (val) {
                    await ai.loadGeminiApiKey();
                    if (isCloud && !ai.hasGeminiApiKey) {
                      _setAiFeedback(
                        '클라우드 AI 사용을 위해 아래에 Gemini API 키를 먼저 입력·저장해 주세요.',
                        isWarning: true,
                      );
                      return;
                    }
                    await ai.updateConfig(
                      ai.config.copyWith(
                        engineType: settings.aiEngineType,
                        modelTier: settings.aiWhisperModelTier,
                        sourceLanguage: settings.aiSourceLanguage,
                        displayMode: settings.aiDisplayMode,
                      ),
                    );
                  }
                  await ai.setEnabled(val);
                },
              ),
              if (ai.statusMessage != null) ...[
                const SizedBox(height: 4),
                Text(
                  ai.statusMessage!,
                  style: const TextStyle(color: Colors.cyanAccent, fontSize: 11),
                ),
                if (ai.initProgress != null) ...[
                  const SizedBox(height: 4),
                  LinearProgressIndicator(
                    value: ai.initProgress,
                    color: Colors.cyanAccent,
                    backgroundColor: Colors.white12,
                    minHeight: 3,
                  ),
                ],
              ],
              if (_aiInlineFeedback != null ||
                  (!isOn && ai.lastErrorMessage != null)) ...[
                const SizedBox(height: 6),
                Builder(
                  builder: (context) {
                    final isWarning =
                        _aiInlineFeedback == null || _aiInlineFeedbackIsWarning;
                    final accent =
                        isWarning ? Colors.orangeAccent : Colors.cyanAccent;
                    return Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: accent.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: accent.withValues(alpha: 0.45),
                        ),
                      ),
                      child: Text(
                        _aiInlineFeedback ?? ai.lastErrorMessage!,
                        style: TextStyle(
                          color: accent,
                          fontSize: 11,
                        ),
                      ),
                    );
                  },
                ),
              ],
              const Divider(color: Colors.white12, height: 16),

              // 1. 엔진 선택 (3가지)
              const Text(
                'AI 자막 엔진 선택',
                style: TextStyle(color: Colors.white70, fontSize: 11.5, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              Column(
                children: [
                  for (final engineType in AiSubtitleEngineType.values)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: () async {
                          if (selectedEngine == engineType) return;
                          await SubtitleSettingsService.instance.updateSettings(
                            settings.copyWith(aiEngineType: engineType),
                          );
                          await ai.updateConfig(
                            ai.config.copyWith(engineType: engineType),
                          );
                        },
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: selectedEngine == engineType
                                ? Colors.cyanAccent.withValues(alpha: 0.14)
                                : const Color(0xFF252C3B),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: selectedEngine == engineType
                                  ? Colors.cyanAccent
                                  : Colors.white12,
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                selectedEngine == engineType
                                    ? Icons.radio_button_checked
                                    : Icons.radio_button_unchecked,
                                size: 16,
                                color: selectedEngine == engineType
                                    ? Colors.cyanAccent
                                    : Colors.white54,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  engineType.label,
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    color: selectedEngine == engineType
                                        ? Colors.white
                                        : Colors.white70,
                                    fontWeight: selectedEngine == engineType
                                        ? FontWeight.w600
                                        : FontWeight.normal,
                                  ),
                                ),
                              ),
                              if (engineType == AiSubtitleEngineType.freeHybrid)
                                Container(
                                  margin: const EdgeInsets.only(left: 6),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.tealAccent.withValues(alpha: 0.18),
                                    borderRadius: BorderRadius.circular(4),
                                    border: Border.all(
                                      color: Colors.tealAccent.withValues(alpha: 0.6),
                                    ),
                                  ),
                                  child: const Text(
                                    '추천',
                                    style: TextStyle(
                                      fontSize: 9.5,
                                      color: Colors.tealAccent,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),

              // 2. 로컬 Whisper 모델 크기 선택 & 다운로드 (온라인 무료 / 로컬 오프라인 공용)
              if (usesLocalWhisper) ...[
                const SizedBox(height: 6),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.22),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.memory, size: 14, color: Colors.cyanAccent),
                          const SizedBox(width: 6),
                          const Text(
                            'Whisper 음성 인식 모델 크기',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const Spacer(),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: (_downloadedWhisperModels[selectedTier] == true
                                      ? Colors.greenAccent
                                      : Colors.amberAccent)
                                  .withValues(alpha: 0.16),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              _downloadedWhisperModels[selectedTier] == true
                                  ? '설치됨'
                                  : '미설치 (${selectedTier.approxSize})',
                              style: TextStyle(
                                fontSize: 10,
                                color: _downloadedWhisperModels[selectedTier] == true
                                    ? Colors.greenAccent
                                    : Colors.amberAccent,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final tier in AiWhisperModelTier.values)
                            ChoiceChip(
                              label: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    tier.shortName,
                                    style: TextStyle(
                                      fontSize: 10.5,
                                      color: selectedTier == tier
                                          ? Colors.black
                                          : Colors.white70,
                                      fontWeight: selectedTier == tier
                                          ? FontWeight.w600
                                          : FontWeight.normal,
                                    ),
                                  ),
                                  if (_downloadedWhisperModels[tier] == true) ...[
                                    const SizedBox(width: 4),
                                    Icon(
                                      Icons.check_circle,
                                      size: 12,
                                      color: selectedTier == tier
                                          ? Colors.black87
                                          : Colors.greenAccent,
                                    ),
                                  ],
                                ],
                              ),
                              selected: selectedTier == tier,
                              selectedColor: Colors.cyanAccent,
                              backgroundColor: const Color(0xFF252C3B),
                              side: BorderSide(
                                color: selectedTier == tier
                                    ? Colors.cyanAccent
                                    : Colors.white12,
                              ),
                              visualDensity: VisualDensity.compact,
                              onSelected: _isDownloadingWhisperModel
                                  ? null
                                  : (selected) async {
                                      if (!selected || selectedTier == tier) return;
                                      await SubtitleSettingsService.instance.updateSettings(
                                        settings.copyWith(aiWhisperModelTier: tier),
                                      );
                                      await ai.updateConfig(
                                        ai.config.copyWith(modelTier: tier),
                                      );
                                    },
                            ),
                        ],
                      ),
                      if (_isDownloadingWhisperModel) ...[
                        const SizedBox(height: 8),
                        Text(
                          _whisperDownloadStatus ?? '다운로드 중...',
                          style: const TextStyle(color: Colors.cyanAccent, fontSize: 10.5),
                        ),
                        const SizedBox(height: 4),
                        LinearProgressIndicator(
                          value: _whisperDownloadProgress > 0
                              ? _whisperDownloadProgress
                              : null,
                          color: Colors.cyanAccent,
                          backgroundColor: Colors.white12,
                          minHeight: 3,
                        ),
                      ] else if (_downloadedWhisperModels[selectedTier] != true) ...[
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${selectedTier.label} (자동 또는 사전 다운로드 가능)',
                                style: const TextStyle(color: Colors.white54, fontSize: 10.5),
                              ),
                            ),
                            const SizedBox(width: 8),
                            OutlinedButton.icon(
                              icon: const Icon(Icons.download, size: 14),
                              label: const Text('모델 다운로드', style: TextStyle(fontSize: 11)),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.cyanAccent,
                                side: const BorderSide(color: Colors.cyanAccent),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 5,
                                ),
                                minimumSize: Size.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              onPressed: () => _downloadWhisperModel(selectedTier),
                            ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 6),
                      const Text(
                        '실시간 기본 추천: Small / Small Q5_1 (속도·정확도 균형 · Windows Vulkan GPU 가속 지원)',
                        style: TextStyle(color: Colors.tealAccent, fontSize: 10.5),
                      ),
                      if (defaultTargetPlatform == TargetPlatform.windows &&
                          selectedTier == AiWhisperModelTier.largeV3TurboQ5) ...[
                        const SizedBox(height: 8),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 9,
                            vertical: 7,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.amber.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: Colors.amber.withValues(alpha: 0.45),
                            ),
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.speed,
                                size: 15,
                                color: Colors.amber,
                              ),
                              const SizedBox(width: 7),
                              const Expanded(
                                child: Text(
                                  'Large v3 Turbo Q5 모델은 무거워 고성능 GPU가 아니면 실시간 자막이 지연될 수 있습니다. 실시간 추천 모델(Small / Small Q5_1) 사용을 권장합니다.',
                                  style: TextStyle(
                                    color: Colors.amberAccent,
                                    fontSize: 10.5,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              TextButton(
                                style: TextButton.styleFrom(
                                  foregroundColor: Colors.cyanAccent,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                  minimumSize: Size.zero,
                                  tapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                ),
                                onPressed: () async {
                                  final recommended =
                                      _downloadedWhisperModels[
                                                  AiWhisperModelTier.smallQ5_1] ==
                                              true &&
                                          _downloadedWhisperModels[
                                                  AiWhisperModelTier.small] !=
                                              true
                                          ? AiWhisperModelTier.smallQ5_1
                                          : AiWhisperModelTier.small;
                                  await SubtitleSettingsService.instance
                                      .updateSettings(
                                    settings.copyWith(
                                      aiWhisperModelTier: recommended,
                                    ),
                                  );
                                  await ai.updateConfig(
                                    ai.config.copyWith(modelTier: recommended),
                                  );
                                },
                                child: Text(
                                  _downloadedWhisperModels[
                                              AiWhisperModelTier.smallQ5_1] ==
                                          true &&
                                      _downloadedWhisperModels[
                                              AiWhisperModelTier.small] !=
                                          true
                                      ? 'Small Q5_1 전환'
                                      : 'Small 전환',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],

              // 3. Windows 로컬 오프라인 번역 미지원 안내 또는 클라우드 AI API Key 설정 UI
              if (isOnDevice && !isLocalTranslatorSupported) ...[
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.amber.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.amber.withValues(alpha: 0.45)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.info_outline, size: 16, color: Colors.amber),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          'Windows 로컬 오프라인 모드는 ML Kit 미지원으로 원어 자막만 생성됩니다. 무료 한국어 번역은 [온라인 무료]를 선택하세요.',
                          style: TextStyle(color: Colors.amberAccent, fontSize: 11),
                        ),
                      ),
                      const SizedBox(width: 6),
                      TextButton(
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.cyanAccent,
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        onPressed: () async {
                          await SubtitleSettingsService.instance.updateSettings(
                            settings.copyWith(aiEngineType: AiSubtitleEngineType.freeHybrid),
                          );
                          await ai.updateConfig(
                            ai.config.copyWith(engineType: AiSubtitleEngineType.freeHybrid),
                          );
                        },
                        child: const Text('온라인 무료 전환', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ),
                ),
              ],
              if (isCloud) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.25),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.vpn_key, size: 15, color: Colors.cyanAccent),
                          const SizedBox(width: 6),
                          const Text(
                            'Gemini API Key (로컬 보안 저장)',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const Spacer(),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: (ai.hasGeminiApiKey
                                      ? Colors.greenAccent
                                      : Colors.orangeAccent)
                                  .withValues(alpha: 0.16),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              ai.hasGeminiApiKey
                                  ? '저장됨 (${ai.maskedGeminiApiKey ?? ''})'
                                  : '미입력',
                              style: TextStyle(
                                fontSize: 10,
                                color: ai.hasGeminiApiKey
                                    ? Colors.greenAccent
                                    : Colors.orangeAccent,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _apiKeyController,
                              obscureText: _obscureApiKey,
                              style: const TextStyle(color: Colors.white, fontSize: 12),
                              decoration: InputDecoration(
                                isDense: true,
                                hintText: ai.hasGeminiApiKey
                                    ? '새 Gemini API Key 입력 시 덮어쓰기'
                                    : 'AIza... 형태의 Gemini API Key 입력',
                                hintStyle: const TextStyle(color: Colors.white38, fontSize: 11),
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 8,
                                ),
                                filled: true,
                                fillColor: const Color(0xFF141821),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(6),
                                  borderSide: const BorderSide(color: Colors.white12),
                                ),
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(6),
                                  borderSide: const BorderSide(color: Colors.white12),
                                ),
                                suffixIcon: IconButton(
                                  icon: Icon(
                                    _obscureApiKey
                                        ? Icons.visibility_off
                                        : Icons.visibility,
                                    size: 16,
                                    color: Colors.white54,
                                  ),
                                  onPressed: () {
                                    setState(() => _obscureApiKey = !_obscureApiKey);
                                  },
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          ElevatedButton(
                            onPressed: _isSavingApiKey ? null : _saveGeminiApiKey,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.cyanAccent,
                              foregroundColor: Colors.black,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 9,
                              ),
                              minimumSize: Size.zero,
                            ),
                            child: const Text(
                              '저장',
                              style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold),
                            ),
                          ),
                          if (ai.hasGeminiApiKey) ...[
                            const SizedBox(width: 4),
                            IconButton(
                              tooltip: '저장된 API Key 삭제',
                              icon: const Icon(
                                Icons.delete_outline,
                                size: 18,
                                color: Colors.redAccent,
                              ),
                              onPressed: _isSavingApiKey ? null : _deleteGeminiApiKey,
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ],

              const SizedBox(height: 10),

              // 3. 표시 모드 선택
              const Text(
                '표시 모드',
                style: TextStyle(color: Colors.white70, fontSize: 11.5, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final mode in AiSubtitleDisplayMode.values)
                    ChoiceChip(
                      label: Text(
                        mode.label,
                        style: TextStyle(
                          fontSize: 11,
                          color: settings.aiDisplayMode == mode
                              ? Colors.black
                              : Colors.white70,
                          fontWeight: settings.aiDisplayMode == mode
                              ? FontWeight.w600
                              : FontWeight.normal,
                        ),
                      ),
                      selected: settings.aiDisplayMode == mode,
                      selectedColor: Colors.cyanAccent,
                      backgroundColor: const Color(0xFF252C3B),
                      side: BorderSide(
                        color: settings.aiDisplayMode == mode
                            ? Colors.cyanAccent
                            : Colors.white12,
                      ),
                      visualDensity: VisualDensity.compact,
                      onSelected: (selected) {
                        if (!selected) return;
                        SubtitleSettingsService.instance.updateSettings(
                          settings.copyWith(aiDisplayMode: mode),
                        );
                        ai.updateConfig(ai.config.copyWith(displayMode: mode));
                        if (isOnDevice &&
                            !isLocalTranslatorSupported &&
                            mode != AiSubtitleDisplayMode.originalOnly) {
                          _setAiFeedback(
                            'Windows 로컬 오프라인은 원어 자막만 지원합니다. 한국어 번역을 원하시면 [온라인 무료] 또는 [클라우드 AI]를 선택해 주세요.',
                            isWarning: true,
                          );
                        }
                      },
                    ),
                ],
              ),

              const SizedBox(height: 8),

              // 4. 원본 음성 언어 힌트
              Row(
                children: [
                  const Text(
                    '영상 속 음성 언어 (힌트)',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  const Spacer(),
                  DropdownButton<String>(
                    value: AiSourceLanguageOption.presets
                            .any((p) => p.code == settings.aiSourceLanguage)
                        ? settings.aiSourceLanguage
                        : 'auto',
                    dropdownColor: const Color(0xFF1B202B),
                    underline: const SizedBox.shrink(),
                    style: const TextStyle(color: Colors.cyanAccent, fontSize: 12),
                    items: [
                      for (final opt in AiSourceLanguageOption.presets)
                        DropdownMenuItem(
                          value: opt.code,
                          child: Text(opt.label),
                        ),
                    ],
                    onChanged: (lang) {
                      if (lang == null) return;
                      SubtitleSettingsService.instance.updateSettings(
                        settings.copyWith(aiSourceLanguage: lang),
                      );
                      ai.updateConfig(ai.config.copyWith(sourceLanguage: lang));
                    },
                  ),
                ],
              ),

              const SizedBox(height: 6),

              // 5. 생성·캐싱된 AI 자막 .srt 내보내기 버튼
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  icon: _isExportingSrt
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.download_rounded, size: 16),
                  label: Text(
                    cachedCount > 0
                        ? '자막 내보내기 (.srt · $cachedCount개 구간)'
                        : '자막 내보내기 (.srt)',
                    style: const TextStyle(fontSize: 12),
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor:
                        cachedCount > 0 ? Colors.cyanAccent : Colors.white54,
                    side: BorderSide(
                      color: cachedCount > 0
                          ? Colors.cyanAccent.withValues(alpha: 0.6)
                          : Colors.white24,
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                  ),
                  onPressed: _isExportingSrt
                      ? null
                      : () => _exportAiSubtitlesAsSrt(settings.aiDisplayMode),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // 2. 자막 스타일 설정 탭 (크기, 위치, 글자색, 배경색 & 투명도)
  Widget _buildStyleSettingsTab() {
    return ListenableBuilder(
      listenable: SubtitleSettingsService.instance,
      builder: (context, _) {
        final settings = SubtitleSettingsService.instance.settings;

        return SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 1. 실시간 자막 미리보기 박스
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF0F172A), Color(0xFF1E293B)],
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                  ),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.white24, width: 0.8),
                ),
                child: Column(
                  children: [
                    const Text(
                      '실시간 자막 미리보기',
                      style: TextStyle(color: Colors.white54, fontSize: 11),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                      decoration: BoxDecoration(
                        color: settings.backgroundOpacity > 0.0
                            ? settings.backgroundColor.withValues(
                                alpha: settings.backgroundOpacity.clamp(0.0, 1.0),
                              )
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '자막 미리보기 텍스트 예시\nSubtitle Preview Example',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: settings.fontSize.clamp(14.0, 32.0),
                          color: settings.textColor,
                          fontWeight: FontWeight.w600,
                          height: 1.35,
                          shadows: [
                            Shadow(
                              offset: const Offset(1.2, 1.2),
                              blurRadius: 2.5,
                              color: Colors.black.withValues(alpha: 0.95),
                            ),
                            Shadow(
                              offset: const Offset(-1.2, -1.2),
                              blurRadius: 2.5,
                              color: Colors.black.withValues(alpha: 0.95),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // 2. 자막 크기 조절
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('자막 크기', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  Text(
                    '${settings.fontSize.round()} pt',
                    style: const TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              Slider(
                value: settings.fontSize,
                min: 16.0,
                max: 44.0,
                divisions: 28,
                activeColor: Colors.blueAccent,
                label: '${settings.fontSize.round()} pt',
                onChanged: (val) {
                  SubtitleSettingsService.instance.updateSettings(
                    settings.copyWith(fontSize: val),
                  );
                },
              ),
              const SizedBox(height: 8),

              // 3. 자막 위치 (상단 / 중앙 / 하단 정렬)
              const Text('자막 위치', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Row(
                children: [
                  for (final pos in SubtitlePosition.values)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(pos.label),
                        selected: settings.position == pos,
                        selectedColor: Colors.blueAccent,
                        labelStyle: TextStyle(
                          color: settings.position == pos ? Colors.white : Colors.white70,
                          fontWeight: settings.position == pos ? FontWeight.bold : FontWeight.normal,
                        ),
                        backgroundColor: const Color(0xFF272F3E),
                        onSelected: (selected) {
                          if (selected) {
                            SubtitleSettingsService.instance.updateSettings(
                              settings.copyWith(position: pos),
                            );
                          }
                        },
                      ),
                    ),
                ],
              ),
              if (settings.position != SubtitlePosition.center) ...[
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      settings.position == SubtitlePosition.bottom ? '하단 여백 높이' : '상단 여백 높이',
                      style: const TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                    Text(
                      '${settings.bottomOffset.round()} px',
                      style: const TextStyle(color: Colors.blueAccent, fontSize: 13, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                Slider(
                  value: settings.bottomOffset,
                  min: 10.0,
                  max: 120.0,
                  divisions: 22,
                  activeColor: Colors.blueAccent,
                  label: '${settings.bottomOffset.round()} px',
                  onChanged: (val) {
                    SubtitleSettingsService.instance.updateSettings(
                      settings.copyWith(bottomOffset: val),
                    );
                  },
                ),
              ],
              const SizedBox(height: 12),

              // 4. 자막 글자색 (Foreground)
              const Text('글자색 (Foreground)', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 12,
                children: [
                  for (final col in _textColors)
                    GestureDetector(
                      onTap: () {
                        SubtitleSettingsService.instance.updateSettings(
                          settings.copyWith(textColor: col),
                        );
                      },
                      child: Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: col,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: settings.textColor.toARGB32() == col.toARGB32()
                                ? Colors.blueAccent
                                : Colors.white30,
                            width: settings.textColor.toARGB32() == col.toARGB32() ? 3 : 1,
                          ),
                          boxShadow: settings.textColor.toARGB32() == col.toARGB32()
                              ? [
                                  BoxShadow(
                                    color: Colors.blueAccent.withAlpha(150),
                                    blurRadius: 6,
                                    spreadRadius: 1,
                                  )
                                ]
                              : null,
                        ),
                        child: settings.textColor.toARGB32() == col.toARGB32()
                            ? Icon(
                                Icons.check,
                                size: 18,
                                color: col.computeLuminance() > 0.5 ? Colors.black : Colors.white,
                              )
                            : null,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),

              // 5. 자막 배경색 (Background)
              const Text('배경색 (Background)', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 12,
                children: [
                  for (final col in _bgColors)
                    GestureDetector(
                      onTap: () {
                        SubtitleSettingsService.instance.updateSettings(
                          settings.copyWith(backgroundColor: col),
                        );
                      },
                      child: Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: col,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: settings.backgroundColor.toARGB32() == col.toARGB32()
                                ? Colors.blueAccent
                                : Colors.white38,
                            width: settings.backgroundColor.toARGB32() == col.toARGB32() ? 3 : 1,
                          ),
                          boxShadow: settings.backgroundColor.toARGB32() == col.toARGB32()
                              ? [
                                  BoxShadow(
                                    color: Colors.blueAccent.withAlpha(150),
                                    blurRadius: 6,
                                    spreadRadius: 1,
                                  )
                                ]
                              : null,
                        ),
                        child: settings.backgroundColor.toARGB32() == col.toARGB32()
                            ? const Icon(Icons.check, size: 18, color: Colors.blueAccent)
                            : null,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),

              // 6. 배경 투명도 (0%: 완전 투명 ~ 100%: 불투명)
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('배경 불투명도', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  Text(
                    settings.backgroundOpacity == 0.0
                        ? '0% (완전 투명/배경 없음)'
                        : '${(settings.backgroundOpacity * 100).round()}%',
                    style: const TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              Slider(
                value: settings.backgroundOpacity,
                min: 0.0,
                max: 1.0,
                divisions: 20,
                activeColor: Colors.blueAccent,
                label: '${(settings.backgroundOpacity * 100).round()}%',
                onChanged: (val) {
                  SubtitleSettingsService.instance.updateSettings(
                    settings.copyWith(backgroundOpacity: val),
                  );
                },
              ),
              const SizedBox(height: 12),

              // 7. 기본값으로 복원 버튼
              Center(
                child: TextButton.icon(
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('기본 자막 스타일로 초기화'),
                  style: TextButton.styleFrom(foregroundColor: Colors.white60),
                  onPressed: () {
                    SubtitleSettingsService.instance.resetToDefaults();
                  },
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }
}
