import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart';
import '../../models/media_item.dart';
import '../../services/cloud_service_interface.dart';
import '../../utils/subtitle_utils.dart';

class SubtitleDialog extends StatefulWidget {
  final Player player;
  final MediaItem item;
  final CloudService service;
  final void Function(String type, String? id, String? name, String? language)? onSubtitleChanged;

  const SubtitleDialog({
    super.key,
    required this.player,
    required this.item,
    required this.service,
    this.onSubtitleChanged,
  });

  @override
  State<SubtitleDialog> createState() => _SubtitleDialogState();
}

class _SubtitleDialogState extends State<SubtitleDialog> {
  bool _isLoadingCloudSubs = false;
  List<MediaItem> _cloudSubtitles = [];

  @override
  void initState() {
    super.initState();
    _findCloudSubtitles();
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
      
      // libmpv에 로컬 자막 파일 추가
      await widget.player.setSubtitleTrack(
        SubtitleTrack.uri(filePath, title: fileName, language: 'ko'),
      );
      widget.onSubtitleChanged?.call('local', filePath, fileName, 'ko');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('자막을 적용했습니다: $fileName'),
            duration: const Duration(seconds: 2),
          ),
        );
        Navigator.pop(context);
      }
    }
  }

  Future<void> _applyCloudSubtitle(MediaItem subItem) async {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('클라우드 자막 로딩 중: ${subItem.name}'),
        duration: const Duration(seconds: 2),
      ),
    );

    try {
      final url = await widget.service.getStreamUrl(subItem);
      final headers = await widget.service.getStreamHeaders();

      // 클라우드 자막 파일을 로컬 캐시 폴더에 다운로드하여 인코딩(CP949/UTF-8)을 보존하며 mpv에 로드
      final res = await http.get(Uri.parse(url), headers: headers);
      if (res.statusCode == 200) {
        final tempDir = Directory.systemTemp;
        final localSubFile = File('${tempDir.path}/${subItem.id}_${subItem.name}');
        await localSubFile.writeAsBytes(res.bodyBytes);

        await widget.player.setSubtitleTrack(
          SubtitleTrack.uri(localSubFile.path, title: subItem.name, language: 'ko'),
        );
        widget.onSubtitleChanged?.call('cloud', subItem.id, subItem.name, 'ko');

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('자막이 적용되었습니다: ${subItem.name}'),
              duration: const Duration(seconds: 2),
            ),
          );
          Navigator.pop(context);
        }
      } else {
        throw Exception('자막 다운로드 실패 (${res.statusCode})');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('자막 로드 오류: $e'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentSub = widget.player.state.track.subtitle;
    final availableSubs = widget.player.state.tracks.subtitle;

    return Dialog(
      backgroundColor: const Color(0xFF1B202B),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: 500,
        constraints: const BoxConstraints(maxHeight: 600),
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.subtitles, color: Colors.blueAccent),
                const SizedBox(width: 10),
                const Text(
                  '자막 및 언어 트랙 설정',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () => Navigator.pop(context),
                )
              ],
            ),
            const Divider(height: 24),

            // 자막 선택 영역
            Expanded(
              child: SingleChildScrollView(
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
                      title: const Text('자막 끄기'),
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
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
