import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import '../../models/media_item.dart';
import '../../models/subtitle_settings.dart';
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
    _findCloudSubtitles();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
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
        width: 520,
        constraints: const BoxConstraints(maxHeight: 640),
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
              currentSub.id == 'no' ? Icons.check_circle : Icons.radio_button_unchecked,
              color: currentSub.id == 'no' ? Colors.blueAccent : Colors.grey,
            ),
            title: const Text('자막 끄기', style: TextStyle(color: Colors.white)),
            onTap: () {
              widget.player.setSubtitleTrack(SubtitleTrack.no());
              widget.onSubtitleChanged?.call('none', 'no', '자막 끄기', null);
              Navigator.pop(context);
            },
          ),

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
