import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_picker/file_picker.dart';
import '../../models/cloud_account.dart';
import '../../models/folder_shortcut.dart';
import '../../models/media_item.dart';
import '../../services/account_manager.dart';
import '../../services/folder_shortcut_manager.dart';
import '../../services/playback_history_service.dart';
import '../../utils/permission_utils.dart';
import 'add_account_dialog.dart';
import 'add_folder_shortcut_dialog.dart';
import 'browser_screen.dart';
import 'player_screen.dart';

enum HomeViewMode {
  largeIcons('큰 아이콘', Icons.grid_view_rounded),
  smallIcons('작은 아이콘', Icons.view_comfy_alt_outlined),
  list('목록', Icons.format_list_bulleted_rounded),
  details('자세히', Icons.table_rows_outlined);

  final String label;
  final IconData icon;

  const HomeViewMode(this.label, this.icon);
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const String _prefViewModeKey = 'home_explorer_view_mode';
  HomeViewMode _viewMode = HomeViewMode.details;
  bool _showAllHistory = false;
  final Set<String> _prefetchedThumbnailKeys = {};

  @override
  void initState() {
    super.initState();
    _loadViewMode();
  }

  Future<void> _loadViewMode() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_prefViewModeKey);
    if (saved != null) {
      final mode = HomeViewMode.values.firstWhere(
        (m) => m.name == saved,
        orElse: () => HomeViewMode.details,
      );
      if (mounted) {
        setState(() => _viewMode = mode);
      }
    }
  }

  Future<void> _changeViewMode(HomeViewMode mode) async {
    setState(() => _viewMode = mode);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefViewModeKey, mode.name);
  }

  @override
  Widget build(BuildContext context) {
    final accountManager = context.watch<AccountManager>();
    final shortcutManager = context.watch<FolderShortcutManager>();
    final historyService = context.watch<PlaybackHistoryService>();
    final accounts = accountManager.accounts;

    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.play_circle_filled, color: Colors.blueAccent),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                '클라우드 미디어 플레이어',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        actions: [
          // 윈도우 탐색기 스타일 보기 옵션 드롭다운 메뉴
          PopupMenuButton<HomeViewMode>(
            tooltip: '보기 옵션 (${_viewMode.label})',
            onSelected: _changeViewMode,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              margin: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white.withAlpha(15),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white12),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(_viewMode.icon, size: 18, color: Colors.blueAccent),
                  const SizedBox(width: 6),
                  Text(
                    _viewMode.label,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(width: 2),
                  const Icon(Icons.arrow_drop_down, size: 18, color: Colors.white70),
                ],
              ),
            ),
            itemBuilder: (context) => HomeViewMode.values.map((mode) {
              final isSelected = mode == _viewMode;
              return PopupMenuItem<HomeViewMode>(
                value: mode,
                child: Row(
                  children: [
                    Icon(
                      mode.icon,
                      size: 20,
                      color: isSelected ? Colors.blueAccent : Colors.white70,
                    ),
                    const SizedBox(width: 12),
                    Text(
                      mode.label,
                      style: TextStyle(
                        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                        color: isSelected ? Colors.blueAccent : Colors.white,
                      ),
                    ),
                    const Spacer(),
                    if (isSelected)
                      const Icon(Icons.check, size: 18, color: Colors.blueAccent),
                  ],
                ),
              );
            }).toList(),
          ),
          const SizedBox(width: 4),
          IconButton(
            icon: const Icon(Icons.file_open_outlined),
            tooltip: '로컬 파일 직접 열기',
            onPressed: () => _pickAndPlayLocalFile(context, accountManager),
          ),
          IconButton(
            icon: const Icon(Icons.bookmark_add_outlined),
            tooltip: '폴더 바로가기 추가',
            onPressed: () => _openAddFolderShortcutDialog(context),
          ),
          IconButton(
            icon: const Icon(Icons.cloud_upload_outlined),
            tooltip: '클라우드 드라이브 연결',
            onPressed: () => _openAddAccountDialog(context),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _buildHomeContent(context, accounts, accountManager, shortcutManager, historyService),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showQuickActionSheet(context, accountManager),
        icon: const Icon(Icons.add_circle_outline),
        label: const Text('열기 / 소스 추가'),
      ),
    );
  }



  void _prefetchMissingThumbnails(List<PlaybackRecord> records, AccountManager accountManager) {
    for (final record in records) {
      if (record.accountId == 'local') continue;

      // 1. 이미 로컬 캡처 또는 캐시된 썸네일 이미지가 디스크에 정상 존재하는 경우 건너뜀
      if (record.localThumbnailPath != null && File(record.localThumbnailPath!).existsSync()) {
        continue;
      }

      // 이미 프리페치 시도한 항목은 중복 요청 방지
      final key = '${record.accountId}_${record.itemId}';
      if (_prefetchedThumbnailKeys.contains(key)) continue;
      _prefetchedThumbnailKeys.add(key);

      final account = accountManager.getAccountById(record.accountId);
      if (account == null) continue;

      final service = accountManager.getService(account);
      () async {
        try {
          final url = await service.getThumbnailUrl(record.toMediaItem());
          if (url != null && url.isNotEmpty) {
            // 클라우드 썸네일(구글 드라이브 등) 이미지를 즉시 로컬로 다운로드하여 캐시 보존 (URL 만료 및 403 Forbidden 방지)
            final res = await http.get(Uri.parse(url));
            if (res.statusCode == 200 && res.bodyBytes.length > 1000) {
              final cacheDir = await PlaybackHistoryService.instance.getThumbnailDir();
              final safeItemId = record.itemId.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
              final filePath = '$cacheDir\\${record.accountId}_$safeItemId.jpg';
              final file = File(filePath);
              await file.writeAsBytes(res.bodyBytes);
              await PlaybackHistoryService.instance.updateLocalThumbnail(
                accountId: record.accountId,
                itemId: record.itemId,
                path: filePath,
              );
            } else {
              await PlaybackHistoryService.instance.updateThumbnailUrl(
                accountId: record.accountId,
                itemId: record.itemId,
                url: url,
              );
            }
          }
        } catch (_) {}
      }();
    }
  }

  Widget _buildHomeContent(
    BuildContext context,
    List<CloudAccount> accounts,
    AccountManager accountManager,
    FolderShortcutManager shortcutManager,
    PlaybackHistoryService historyService,
  ) {
    return FutureBuilder<List<PlaybackRecord>>(
      future: historyService.getHistoryList(),
      builder: (context, snapshot) {
        final historyList = snapshot.data ?? [];
        if (historyList.isNotEmpty) {
          _prefetchMissingThumbnails(historyList, accountManager);
        }

        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 80),
          children: [
            // 1. 플레이 히스토리 (최근 시청 목록)
            if (historyList.isNotEmpty) ...[
              _buildHistorySection(context, historyList, accountManager),
              const SizedBox(height: 24),
            ],

            // 2. 폴더 바로가기 (즐겨찾기)
            _buildShortcutSection(context, shortcutManager, accountManager),
            const SizedBox(height: 24),

            // 3. 연결된 클라우드 드라이브
            _buildAccountSection(context, accounts, accountManager),
          ],
        );
      },
    );
  }

  // ==========================================
  // 1. 최근 시청 목록 (플레이 히스토리) 섹션
  // ==========================================
  Widget _buildHistorySection(
    BuildContext context,
    List<PlaybackRecord> historyList,
    AccountManager accountManager,
  ) {
    final displayedList = _showAllHistory ? historyList : historyList.take(6).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                const Icon(Icons.history_toggle_off_rounded, size: 20, color: Colors.blueAccent),
                const SizedBox(width: 8),
                Text(
                  '최근 시청 목록 (${historyList.length})',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            Row(
              children: [
                if (historyList.length > 6)
                  TextButton(
                    onPressed: () => setState(() => _showAllHistory = !_showAllHistory),
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.blueAccent,
                      visualDensity: VisualDensity.compact,
                    ),
                    child: Text(_showAllHistory ? '접기' : '더보기 (${historyList.length})'),
                  ),
                IconButton(
                  icon: const Icon(Icons.delete_sweep_outlined, size: 18, color: Colors.white54),
                  tooltip: '시청 기록 전체 삭제',
                  onPressed: () => _confirmClearAllHistory(context),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 8),

        LayoutBuilder(
          builder: (context, constraints) {
            switch (_viewMode) {
              case HomeViewMode.largeIcons:
                final count = (constraints.maxWidth / 220).floor().clamp(1, 6);
                return GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: count,
                    mainAxisExtent: 180,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 10,
                  ),
                  itemCount: displayedList.length,
                  itemBuilder: (context, i) => _buildHistoryLargeCard(context, displayedList[i], accountManager),
                );

              case HomeViewMode.smallIcons:
                final count = (constraints.maxWidth / 260).floor().clamp(1, 4);
                return GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: count,
                    mainAxisExtent: 64,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                  ),
                  itemCount: displayedList.length,
                  itemBuilder: (context, i) => _buildHistorySmallCard(context, displayedList[i], accountManager),
                );

              case HomeViewMode.list:
                return Column(
                  children: displayedList
                      .map((r) => _buildHistoryListRow(context, r, accountManager))
                      .toList(),
                );

              case HomeViewMode.details:
                return _buildHistoryDetailsTable(context, displayedList, accountManager, constraints.maxWidth);
            }
          },
        ),
      ],
    );
  }

  // 플레이 히스토리 - 큰 아이콘
  Widget _buildHistoryLargeCard(BuildContext context, PlaybackRecord record, AccountManager accountManager) {
    final account = accountManager.getAccountById(record.accountId);
    final accountName = account?.name ?? (record.accountId == 'local' ? '내 PC' : '클라우드');
    final cloudType = account?.type ?? (record.accountId == 'local' ? CloudType.local : CloudType.googleDrive);
    final isFinished = record.progress >= 0.95 || (record.durationMillis > 0 && record.positionMillis == 0);

    return Card(
      elevation: 3,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: isFinished ? Colors.white12 : Colors.blueAccent.withAlpha(60), width: 0.8),
      ),
      color: const Color(0xFF1B202B),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _playHistoryItem(context, record, accountManager),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 비디오 썸네일/미리보기 영역
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // 1. 썸네일 이미지 또는 폴백
                  _buildHistoryThumbnail(record, account, isFinished),

                  // 2. 상하 그라데이션 오버레이 (뱃지 및 텍스트 시인성 향상)
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.black.withAlpha(50),
                            Colors.transparent,
                            Colors.black.withAlpha(110),
                          ],
                          stops: const [0.0, 0.45, 1.0],
                        ),
                      ),
                    ),
                  ),

                  // 3. 중앙 재생 / 완료 아이콘 (글래스모피즘 원형 버튼)
                  Center(
                    child: Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: Colors.black.withAlpha(140),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white.withAlpha(70), width: 1.5),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withAlpha(90),
                            blurRadius: 6,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Icon(
                        isFinished ? Icons.check_circle_outline : Icons.play_arrow_rounded,
                        size: 26,
                        color: isFinished ? Colors.greenAccent : Colors.white,
                      ),
                    ),
                  ),

                  // 4. 클라우드 타입 뱃지 (좌상단)
                  Positioned(
                    top: 6,
                    left: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2.5),
                      decoration: BoxDecoration(
                        color: Colors.black.withAlpha(170),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: Colors.white10),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _buildSmallCloudIcon(cloudType),
                          const SizedBox(width: 4),
                          Text(accountName, style: const TextStyle(fontSize: 10, color: Colors.white70, fontWeight: FontWeight.w500)),
                        ],
                      ),
                    ),
                  ),

                  // 5. 삭제 버튼 (우상단)
                  Positioned(
                    top: 4,
                    right: 4,
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.black.withAlpha(140),
                        shape: BoxShape.circle,
                      ),
                      child: IconButton(
                        icon: const Icon(Icons.close, size: 14, color: Colors.white70),
                        tooltip: '기록 삭제',
                        padding: const EdgeInsets.all(4),
                        constraints: const BoxConstraints(),
                        onPressed: () => _removeHistoryRecord(record),
                      ),
                    ),
                  ),

                  // 6. 전체 영상 길이 뱃지 (우하단)
                  if (record.durationMillis > 0)
                    Positioned(
                      right: 6,
                      bottom: (record.progress > 0 && !isFinished) ? 7 : 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                        decoration: BoxDecoration(
                          color: Colors.black.withAlpha(200),
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Text(
                          record.formattedDuration,
                          style: const TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                            letterSpacing: 0.3,
                          ),
                        ),
                      ),
                    ),

                  // 7. 진행률 바 (최하단)
                  if (record.progress > 0 && !isFinished)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: LinearProgressIndicator(
                        value: record.progress,
                        minHeight: 3.5,
                        backgroundColor: Colors.white12,
                        valueColor: const AlwaysStoppedAnimation<Color>(Colors.blueAccent),
                      ),
                    ),
                ],
              ),
            ),
            // 정보 영역 (하단)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 7, 10, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Tooltip(
                    message: record.fileName,
                    child: Text(
                      record.fileName,
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      if (!isFinished && record.progress > 0) ...[
                        Text(
                          '${(record.progress * 100).toInt()}% 시청',
                          style: const TextStyle(
                            fontSize: 10.5,
                            color: Colors.blueAccent,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(width: 4),
                        const Text('•', style: TextStyle(fontSize: 9, color: Colors.white30)),
                        const SizedBox(width: 4),
                      ],
                      Expanded(
                        child: Text(
                          isFinished
                              ? '시청 완료 (${record.formattedDuration})'
                              : '${record.formattedPosition} / ${record.formattedDuration}',
                          style: TextStyle(
                            fontSize: 10.5,
                            color: isFinished ? Colors.greenAccent.shade200 : Colors.white60,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 플레이 히스토리 - 작은 아이콘
  Widget _buildHistorySmallCard(BuildContext context, PlaybackRecord record, AccountManager accountManager) {
    final account = accountManager.getAccountById(record.accountId);
    final accountName = account?.name ?? (record.accountId == 'local' ? '내 PC' : '클라우드');
    final cloudType = account?.type ?? (record.accountId == 'local' ? CloudType.local : CloudType.googleDrive);
    final isFinished = record.progress >= 0.95 || (record.durationMillis > 0 && record.positionMillis == 0);

    return Card(
      elevation: 1,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: isFinished ? Colors.white10 : Colors.blueAccent.withAlpha(40), width: 0.8),
      ),
      color: const Color(0xFF1E2430),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => _playHistoryItem(context, record, accountManager),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: SizedBox(
                  width: 44,
                  height: 36,
                  child: _buildSmallHistoryThumbnail(record, account, isFinished),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      record.fileName,
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        _buildSmallCloudIcon(cloudType),
                        const SizedBox(width: 3),
                        Text(accountName, style: const TextStyle(fontSize: 10, color: Colors.white54)),
                        const SizedBox(width: 6),
                        Text(
                          isFinished ? '시청 완료' : record.formattedPosition,
                          style: TextStyle(
                            fontSize: 10,
                            color: isFinished ? Colors.greenAccent.shade200 : Colors.blueAccent,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 14, color: Colors.white38),
                tooltip: '삭제',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: () => _removeHistoryRecord(record),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // 썸네일 렌더링 헬퍼 메서드들
  Widget _buildHistoryThumbnail(PlaybackRecord record, CloudAccount? account, bool isFinished) {
    // 1. 로컬에 저장된 실제 재생 화면 캡처 썸네일이 있는 경우 최우선 사용
    if (record.localThumbnailPath != null && File(record.localThumbnailPath!).existsSync()) {
      return Image.file(
        File(record.localThumbnailPath!),
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        errorBuilder: (context, error, stackTrace) => _buildThumbnailPlaceholder(isFinished),
      );
    }

    // 2. 클라우드에서 제공된 썸네일 URL이 있는 경우 사용
    if (record.thumbnailUrl != null && record.thumbnailUrl!.isNotEmpty) {
      Map<String, String>? headers;
      if (!record.thumbnailUrl!.contains('googleusercontent.com') &&
          account != null &&
          account.type == CloudType.googleDrive &&
          account.accessToken.isNotEmpty) {
        headers = {'Authorization': 'Bearer ${account.accessToken}'};
      }
      return _buildThumbnailNetworkImage(record.thumbnailUrl!, headers, isFinished);
    }

    // 3. 썸네일이 없는 경우 기본 플레이스홀더 표시
    return _buildThumbnailPlaceholder(isFinished);
  }

  Widget _buildThumbnailNetworkImage(
    String rawUrl,
    Map<String, String>? headers,
    bool isFinished,
  ) {
    // Google Drive 썸네일 해상도 향상 (=s220 -> =s400)
    var url = rawUrl;
    if (url.contains('googleusercontent.com') && url.contains('=s')) {
      url = url.replaceAll(RegExp(r'=s\d+'), '=s400');
    }

    return Image.network(
      url,
      headers: headers,
      fit: BoxFit.cover,
      width: double.infinity,
      height: double.infinity,
      errorBuilder: (context, error, stackTrace) {
        // 인증 헤더 포함 실패 시 헤더 없이 1회 재시도 (공개 링크 대응)
        if (headers != null) {
          return Image.network(
            url,
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
            errorBuilder: (ctx, err, stack) => _buildThumbnailPlaceholder(isFinished),
          );
        }
        return _buildThumbnailPlaceholder(isFinished);
      },
      loadingBuilder: (context, child, loadingProgress) {
        if (loadingProgress == null) return child;
        return Container(
          color: const Color(0xFF141822),
          child: const Center(
            child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.blueAccent),
            ),
          ),
        );
      },
    );
  }

  Widget _buildThumbnailPlaceholder(bool isFinished) {
    return Container(
      color: const Color(0xFF141822),
      child: Center(
        child: Icon(
          isFinished ? Icons.check_circle_outline : Icons.movie_creation_outlined,
          size: 38,
          color: isFinished ? Colors.white54 : Colors.white24,
        ),
      ),
    );
  }

  Widget _buildSmallHistoryThumbnail(PlaybackRecord record, CloudAccount? account, bool isFinished) {
    if (record.localThumbnailPath != null && File(record.localThumbnailPath!).existsSync()) {
      return Image.file(
        File(record.localThumbnailPath!),
        fit: BoxFit.cover,
        width: 44,
        height: 36,
        errorBuilder: (context, error, stackTrace) => _buildSmallThumbnailFallback(isFinished),
      );
    }
    if (record.thumbnailUrl != null && record.thumbnailUrl!.isNotEmpty) {
      Map<String, String>? headers;
      if (!record.thumbnailUrl!.contains('googleusercontent.com') &&
          account != null &&
          account.type == CloudType.googleDrive &&
          account.accessToken.isNotEmpty) {
        headers = {'Authorization': 'Bearer ${account.accessToken}'};
      }
      return Image.network(
        record.thumbnailUrl!,
        headers: headers,
        fit: BoxFit.cover,
        width: 44,
        height: 36,
        errorBuilder: (context, error, stackTrace) => _buildSmallThumbnailFallback(isFinished),
      );
    }
    return _buildSmallThumbnailFallback(isFinished);
  }

  Widget _buildSmallThumbnailFallback(bool isFinished) {
    return Container(
      color: isFinished ? Colors.white10 : Colors.blueAccent.withAlpha(30),
      child: Center(
        child: Icon(
          isFinished ? Icons.check : Icons.play_arrow,
          color: isFinished ? Colors.white70 : Colors.blueAccent,
          size: 20,
        ),
      ),
    );
  }

  // 플레이 히스토리 - 목록
  Widget _buildHistoryListRow(BuildContext context, PlaybackRecord record, AccountManager accountManager) {
    final account = accountManager.getAccountById(record.accountId);
    final accountName = account?.name ?? (record.accountId == 'local' ? '내 PC' : '클라우드');
    final cloudType = account?.type ?? (record.accountId == 'local' ? CloudType.local : CloudType.googleDrive);
    final isFinished = record.progress >= 0.95 || (record.durationMillis > 0 && record.positionMillis == 0);

    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1F2B),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white10),
      ),
      child: ListTile(
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
        leading: Icon(
          isFinished ? Icons.check_circle_outline : Icons.play_circle_outline,
          color: isFinished ? Colors.white70 : Colors.blueAccent,
          size: 22,
        ),
        title: Text(
          record.fileName,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Row(
          children: [
            _buildSmallCloudIcon(cloudType),
            const SizedBox(width: 4),
            Text('$accountName • ', style: const TextStyle(fontSize: 11, color: Colors.white54)),
            Text(
              isFinished ? '시청 완료 (${record.formattedDuration})' : '${record.formattedPosition} / ${record.formattedDuration}',
              style: TextStyle(fontSize: 11, color: isFinished ? Colors.greenAccent.shade200 : Colors.white70),
            ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.play_arrow, color: Colors.blueAccent, size: 20),
              tooltip: '바로 재생',
              onPressed: () => _playHistoryItem(context, record, accountManager),
            ),
            IconButton(
              icon: const Icon(Icons.close, color: Colors.white38, size: 16),
              tooltip: '삭제',
              onPressed: () => _removeHistoryRecord(record),
            ),
          ],
        ),
        onTap: () => _playHistoryItem(context, record, accountManager),
      ),
    );
  }

  // 플레이 히스토리 - 자세히 (Table)
  Widget _buildHistoryDetailsTable(
    BuildContext context,
    List<PlaybackRecord> records,
    AccountManager accountManager,
    double maxWidth,
  ) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF161A24),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        children: [
          // 테이블 헤더
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: const BoxDecoration(
              color: Color(0xFF1D2331),
              borderRadius: BorderRadius.vertical(top: Radius.circular(10)),
            ),
            child: Row(
              children: const [
                Expanded(flex: 5, child: Text('파일명', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white70))),
                Expanded(flex: 2, child: Text('클라우드', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white70))),
                Expanded(flex: 3, child: Text('시청 시간', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white70))),
                Expanded(flex: 2, child: Text('진행도', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white70))),
                SizedBox(width: 50, child: Text('액션', textAlign: TextAlign.center, style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white70))),
              ],
            ),
          ),
          const Divider(height: 1, color: Colors.white12),
          // 테이블 데이터 행들
          ...records.map((record) {
            final account = accountManager.getAccountById(record.accountId);
            final accountName = account?.name ?? (record.accountId == 'local' ? '내 PC' : '클라우드');
            final cloudType = account?.type ?? (record.accountId == 'local' ? CloudType.local : CloudType.googleDrive);
            final isFinished = record.progress >= 0.95 || (record.durationMillis > 0 && record.positionMillis == 0);
            final percent = (record.progress * 100).toInt();

            return InkWell(
              onTap: () => _playHistoryItem(context, record, accountManager),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: Colors.white10)),
                ),
                child: Row(
                  children: [
                    // 파일명
                    Expanded(
                      flex: 5,
                      child: Row(
                        children: [
                          Icon(
                            isFinished ? Icons.check_circle_outline : Icons.play_circle_fill,
                            size: 16,
                            color: isFinished ? Colors.greenAccent : Colors.blueAccent,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              record.fileName,
                              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // 클라우드
                    Expanded(
                      flex: 2,
                      child: Row(
                        children: [
                          _buildSmallCloudIcon(cloudType),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              accountName,
                              style: const TextStyle(fontSize: 11, color: Colors.white60),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // 시청 시간
                    Expanded(
                      flex: 3,
                      child: Text(
                        isFinished ? '시청 완료 (${record.formattedDuration})' : '${record.formattedPosition} / ${record.formattedDuration}',
                        style: TextStyle(
                          fontSize: 11,
                          color: isFinished ? Colors.greenAccent.shade200 : Colors.white70,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    // 진행도
                    Expanded(
                      flex: 2,
                      child: Row(
                        children: [
                          Expanded(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(2),
                              child: LinearProgressIndicator(
                                value: record.progress,
                                minHeight: 4,
                                backgroundColor: Colors.white12,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  isFinished ? Colors.greenAccent : Colors.blueAccent,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text('$percent%', style: const TextStyle(fontSize: 10, color: Colors.white54)),
                        ],
                      ),
                    ),
                    // 액션 버튼
                    SizedBox(
                      width: 50,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.close, size: 14, color: Colors.white38),
                            tooltip: '삭제',
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            onPressed: () => _removeHistoryRecord(record),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  // ==========================================
  // 2. 폴더 바로가기 섹션
  // ==========================================
  Widget _buildShortcutSection(
    BuildContext context,
    FolderShortcutManager shortcutManager,
    AccountManager accountManager,
  ) {
    final shortcuts = shortcutManager.shortcuts;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                const Icon(Icons.bookmarks, size: 20, color: Colors.amber),
                const SizedBox(width: 8),
                Text(
                  '폴더 바로가기 (${shortcuts.length})',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            TextButton.icon(
              onPressed: () => _openAddFolderShortcutDialog(context),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('바로가기 추가'),
              style: TextButton.styleFrom(
                foregroundColor: Colors.amber,
                visualDensity: VisualDensity.compact,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (shortcuts.isEmpty)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: const Color(0xFF1B202B),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.white10),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.amber.withAlpha(20),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.bookmark_border, color: Colors.amber, size: 22),
                ),
                const SizedBox(width: 14),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '자주 찾는 클라우드 폴더를 등록해보세요',
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                      ),
                      SizedBox(height: 2),
                      Text(
                        '특정 동영상 폴더로 한 번에 즉시 이동할 수 있습니다.',
                        style: TextStyle(fontSize: 12, color: Colors.white54),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.amber,
                    side: const BorderSide(color: Colors.amber),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () => _openAddFolderShortcutDialog(context),
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('추가'),
                ),
              ],
            ),
          )
        else
          LayoutBuilder(
            builder: (context, constraints) {
              switch (_viewMode) {
                case HomeViewMode.largeIcons:
                  final count = (constraints.maxWidth / 170).floor().clamp(1, 8);
                  return GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: count,
                      mainAxisExtent: 130,
                      crossAxisSpacing: 10,
                      mainAxisSpacing: 10,
                    ),
                    itemCount: shortcuts.length,
                    itemBuilder: (context, i) => _buildShortcutLargeCard(context, shortcuts[i], accountManager, shortcutManager),
                  );

                case HomeViewMode.smallIcons:
                  final count = (constraints.maxWidth / 240).floor().clamp(1, 4);
                  return GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: count,
                      mainAxisExtent: 56,
                      crossAxisSpacing: 8,
                      mainAxisSpacing: 8,
                    ),
                    itemCount: shortcuts.length,
                    itemBuilder: (context, i) => _buildShortcutSmallCard(context, shortcuts[i], accountManager, shortcutManager),
                  );

                case HomeViewMode.list:
                  return Column(
                    children: shortcuts
                        .map((s) => _buildShortcutListRow(context, s, accountManager, shortcutManager))
                        .toList(),
                  );

                case HomeViewMode.details:
                  return _buildShortcutDetailsTable(context, shortcuts, accountManager, shortcutManager);
              }
            },
          ),
      ],
    );
  }

  // 폴더 바로가기 - 큰 아이콘
  Widget _buildShortcutLargeCard(
    BuildContext context,
    FolderShortcut shortcut,
    AccountManager accountManager,
    FolderShortcutManager shortcutManager,
  ) {
    return Card(
      elevation: 2,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.amber.withAlpha(40), width: 0.8),
      ),
      color: const Color(0xFF1E2430),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _openShortcut(context, shortcut, accountManager, shortcutManager),
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.folder, size: 48, color: Colors.amber),
                  const SizedBox(height: 6),
                  Text(
                    shortcut.folderName,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 2),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _buildSmallCloudIcon(shortcut.cloudType),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          shortcut.accountName,
                          style: const TextStyle(fontSize: 10, color: Colors.white54),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Positioned(
              top: 2,
              right: 2,
              child: IconButton(
                icon: const Icon(Icons.close, size: 14, color: Colors.white38),
                tooltip: '삭제',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: () => _removeShortcut(shortcut, shortcutManager),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 폴더 바로가기 - 작은 아이콘
  Widget _buildShortcutSmallCard(
    BuildContext context,
    FolderShortcut shortcut,
    AccountManager accountManager,
    FolderShortcutManager shortcutManager,
  ) {
    return Card(
      elevation: 1,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: Colors.amber.withAlpha(40), width: 0.8),
      ),
      color: const Color(0xFF1E2430),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => _openShortcut(context, shortcut, accountManager, shortcutManager),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            children: [
              const Icon(Icons.folder, size: 24, color: Colors.amber),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      shortcut.folderName,
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      shortcut.accountName,
                      style: const TextStyle(fontSize: 10, color: Colors.white54),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 14, color: Colors.white38),
                tooltip: '삭제',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: () => _removeShortcut(shortcut, shortcutManager),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // 폴더 바로가기 - 목록
  Widget _buildShortcutListRow(
    BuildContext context,
    FolderShortcut shortcut,
    AccountManager accountManager,
    FolderShortcutManager shortcutManager,
  ) {
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1F2B),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white10),
      ),
      child: ListTile(
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
        leading: const Icon(Icons.folder, color: Colors.amber, size: 22),
        title: Text(
          shortcut.folderName,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Row(
          children: [
            _buildSmallCloudIcon(shortcut.cloudType),
            const SizedBox(width: 4),
            Text('${shortcut.accountName} • ${shortcut.folderPath ?? shortcut.folderName}', style: const TextStyle(fontSize: 11, color: Colors.white54)),
          ],
        ),
        trailing: IconButton(
          icon: const Icon(Icons.close, color: Colors.white38, size: 16),
          tooltip: '삭제',
          onPressed: () => _removeShortcut(shortcut, shortcutManager),
        ),
        onTap: () => _openShortcut(context, shortcut, accountManager, shortcutManager),
      ),
    );
  }

  // 폴더 바로가기 - 자세히 (Table)
  Widget _buildShortcutDetailsTable(
    BuildContext context,
    List<FolderShortcut> shortcuts,
    AccountManager accountManager,
    FolderShortcutManager shortcutManager,
  ) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF161A24),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        children: [
          // 헤더
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: const BoxDecoration(
              color: Color(0xFF1D2331),
              borderRadius: BorderRadius.vertical(top: Radius.circular(10)),
            ),
            child: Row(
              children: const [
                Expanded(flex: 4, child: Text('폴더명', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white70))),
                Expanded(flex: 3, child: Text('클라우드', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white70))),
                Expanded(flex: 5, child: Text('전체 경로', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white70))),
                SizedBox(width: 50, child: Text('액션', textAlign: TextAlign.center, style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white70))),
              ],
            ),
          ),
          const Divider(height: 1, color: Colors.white12),
          // 행 데이터
          ...shortcuts.map((shortcut) {
            return InkWell(
              onTap: () => _openShortcut(context, shortcut, accountManager, shortcutManager),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: Colors.white10)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      flex: 4,
                      child: Row(
                        children: [
                          const Icon(Icons.folder, size: 18, color: Colors.amber),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              shortcut.folderName,
                              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      flex: 3,
                      child: Row(
                        children: [
                          _buildSmallCloudIcon(shortcut.cloudType),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              shortcut.accountName,
                              style: const TextStyle(fontSize: 11, color: Colors.white60),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      flex: 5,
                      child: Text(
                        shortcut.folderPath ?? shortcut.folderName,
                        style: const TextStyle(fontSize: 11, color: Colors.white54),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    SizedBox(
                      width: 50,
                      child: Center(
                        child: IconButton(
                          icon: const Icon(Icons.close, size: 14, color: Colors.white38),
                          tooltip: '삭제',
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          onPressed: () => _removeShortcut(shortcut, shortcutManager),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  // ==========================================
  // 3. 연결된 클라우드 드라이브 섹션
  // ==========================================
  Widget _buildAccountSection(
    BuildContext context,
    List<CloudAccount> accounts,
    AccountManager accountManager,
  ) {
    // 로컬 저장소를 최상단 기본 소스로 포함하여 통합 제공
    final allStorages = [AccountManager.localAccount, ...accounts];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                const Icon(Icons.storage_rounded, size: 20, color: Colors.blueAccent),
                const SizedBox(width: 8),
                Text(
                  '저장소 및 드라이브 (${allStorages.length})',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            TextButton.icon(
              onPressed: () => _openAddAccountDialog(context),
              icon: const Icon(Icons.cloud_upload_outlined, size: 16),
              label: const Text('클라우드 연결'),
              style: TextButton.styleFrom(
                foregroundColor: Colors.blueAccent,
                visualDensity: VisualDensity.compact,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),

        LayoutBuilder(
          builder: (context, constraints) {
            switch (_viewMode) {
              case HomeViewMode.largeIcons:
                final count = (constraints.maxWidth / 190).floor().clamp(1, 6);
                return GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: count,
                    mainAxisExtent: 130,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 10,
                  ),
                  itemCount: allStorages.length,
                  itemBuilder: (context, i) => _buildAccountLargeCard(context, allStorages[i], accountManager),
                );

              case HomeViewMode.smallIcons:
                final count = (constraints.maxWidth / 240).floor().clamp(1, 4);
                return GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: count,
                    mainAxisExtent: 56,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                  ),
                  itemCount: allStorages.length,
                  itemBuilder: (context, i) => _buildAccountSmallCard(context, allStorages[i], accountManager),
                );

              case HomeViewMode.list:
                return Column(
                  children: allStorages
                      .map((acc) => _buildAccountListRow(context, acc, accountManager))
                      .toList(),
                );

              case HomeViewMode.details:
                return _buildAccountDetailsTable(context, allStorages, accountManager);
            }
          },
        ),

        // 등록된 클라우드 계정이 없을 때 안내 배너
        if (accounts.isEmpty) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.blueAccent.withAlpha(15),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.blueAccent.withAlpha(40)),
            ),
            child: Row(
              children: [
                const Icon(Icons.cloud_upload_outlined, color: Colors.blueAccent, size: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: const [
                      Text(
                        '클라우드 드라이브도 함께 연결해 보세요',
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.white),
                      ),
                      SizedBox(height: 2),
                      Text(
                        'Google Drive, OneDrive, WebDAV 등을 등록하면 어디서든 영상을 스트리밍할 수 있습니다.',
                        style: TextStyle(fontSize: 11, color: Colors.white60),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed: () => _openAddAccountDialog(context),
                  icon: const Icon(Icons.add, size: 14),
                  label: const Text('클라우드 추가'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blueAccent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  // 저장소 / 드라이브 - 큰 아이콘
  Widget _buildAccountLargeCard(BuildContext context, CloudAccount account, AccountManager accountManager) {
    final service = accountManager.getService(account);
    final isLocal = account.type == CloudType.local;

    return Card(
      elevation: 2,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: isLocal
            ? BorderSide(color: Colors.tealAccent.withAlpha(80), width: 1.2)
            : BorderSide.none,
      ),
      color: const Color(0xFF1E2430),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _openBrowser(context, account, service),
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _buildLargeTypeIcon(account.type),
                  const SizedBox(height: 8),
                  Text(
                    account.name,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    isLocal ? '로컬 드라이브 및 내 폴더' : _getTypeDisplayName(account.type),
                    style: TextStyle(
                      fontSize: 11,
                      color: isLocal ? Colors.tealAccent.shade100 : Colors.grey,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Positioned(
              top: 2,
              right: 2,
              child: isLocal
                  ? IconButton(
                      icon: const Icon(Icons.file_open_outlined, size: 16, color: Colors.tealAccent),
                      tooltip: '로컬 파일 직접 열기',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      onPressed: () => _pickAndPlayLocalFile(context, accountManager),
                    )
                  : IconButton(
                      icon: const Icon(Icons.delete_outline, size: 16, color: Colors.redAccent),
                      tooltip: '계정 삭제',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      onPressed: () => _confirmDelete(context, account, accountManager),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  // 저장소 / 드라이브 - 작은 아이콘
  Widget _buildAccountSmallCard(BuildContext context, CloudAccount account, AccountManager accountManager) {
    final service = accountManager.getService(account);
    final isLocal = account.type == CloudType.local;

    return Card(
      elevation: 1,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: isLocal
            ? BorderSide(color: Colors.tealAccent.withAlpha(70), width: 1)
            : BorderSide.none,
      ),
      color: const Color(0xFF1E2430),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => _openBrowser(context, account, service),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            children: [
              _buildSmallCloudIcon(account.type),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      account.name,
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      isLocal ? '로컬 드라이브 및 내 폴더' : _getTypeDisplayName(account.type),
                      style: TextStyle(
                        fontSize: 10,
                        color: isLocal ? Colors.tealAccent.shade100 : Colors.white54,
                      ),
                    ),
                  ],
                ),
              ),
              if (isLocal)
                IconButton(
                  icon: const Icon(Icons.file_open_outlined, size: 15, color: Colors.tealAccent),
                  tooltip: '로컬 파일 열기',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: () => _pickAndPlayLocalFile(context, accountManager),
                )
              else
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 14, color: Colors.redAccent),
                  tooltip: '삭제',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: () => _confirmDelete(context, account, accountManager),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // 저장소 / 드라이브 - 목록
  Widget _buildAccountListRow(BuildContext context, CloudAccount account, AccountManager accountManager) {
    final service = accountManager.getService(account);
    final isLocal = account.type == CloudType.local;

    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1F2B),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isLocal ? Colors.tealAccent.withAlpha(50) : Colors.white10,
        ),
      ),
      child: ListTile(
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
        leading: _buildTypeIcon(account.type),
        title: Text(
          account.name,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
        ),
        subtitle: Text(
          isLocal ? '로컬 디스크 및 사용자 폴더' : _getTypeDisplayName(account.type),
          style: TextStyle(
            fontSize: 11,
            color: isLocal ? Colors.tealAccent.shade100 : Colors.grey,
          ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isLocal)
              IconButton(
                icon: const Icon(Icons.file_open_outlined, color: Colors.tealAccent, size: 18),
                tooltip: '로컬 파일 열기',
                onPressed: () => _pickAndPlayLocalFile(context, accountManager),
              )
            else
              IconButton(
                icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 18),
                tooltip: '계정 삭제',
                onPressed: () => _confirmDelete(context, account, accountManager),
              ),
            const Icon(Icons.chevron_right, color: Colors.grey, size: 18),
          ],
        ),
        onTap: () => _openBrowser(context, account, service),
      ),
    );
  }

  // 저장소 / 드라이브 - 자세히 (Table)
  Widget _buildAccountDetailsTable(BuildContext context, List<CloudAccount> accounts, AccountManager accountManager) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF161A24),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        children: [
          // 헤더
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: const BoxDecoration(
              color: Color(0xFF1D2331),
              borderRadius: BorderRadius.vertical(top: Radius.circular(10)),
            ),
            child: Row(
              children: const [
                Expanded(flex: 4, child: Text('저장소명', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white70))),
                Expanded(flex: 3, child: Text('종류', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white70))),
                Expanded(flex: 3, child: Text('상태', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white70))),
                SizedBox(width: 50, child: Text('관리', textAlign: TextAlign.center, style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white70))),
              ],
            ),
          ),
          const Divider(height: 1, color: Colors.white12),
          // 행 데이터
          ...accounts.map((account) {
            final service = accountManager.getService(account);
            final isLocal = account.type == CloudType.local;

            return InkWell(
              onTap: () => _openBrowser(context, account, service),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: Colors.white10)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      flex: 4,
                      child: Row(
                        children: [
                          _buildSmallCloudIcon(account.type),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              account.name,
                              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      flex: 3,
                      child: Text(
                        _getTypeDisplayName(account.type),
                        style: TextStyle(
                          fontSize: 11,
                          color: isLocal ? Colors.tealAccent.shade100 : Colors.white60,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Expanded(
                      flex: 3,
                      child: Row(
                        children: [
                          Icon(
                            Icons.check_circle,
                            size: 12,
                            color: isLocal ? Colors.tealAccent : Colors.greenAccent,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            isLocal ? '로컬 저장소' : '연결됨',
                            style: TextStyle(
                              fontSize: 11,
                              color: isLocal ? Colors.tealAccent : Colors.greenAccent,
                            ),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(
                      width: 50,
                      child: Center(
                        child: isLocal
                            ? IconButton(
                                icon: const Icon(Icons.file_open_outlined, size: 16, color: Colors.tealAccent),
                                tooltip: '파일 열기',
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(),
                                onPressed: () => _pickAndPlayLocalFile(context, accountManager),
                              )
                            : IconButton(
                                icon: const Icon(Icons.delete_outline, size: 16, color: Colors.redAccent),
                                tooltip: '계정 삭제',
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(),
                                onPressed: () => _confirmDelete(context, account, accountManager),
                              ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  // ==========================================
  // 헬퍼 메서드들
  // ==========================================
  Widget _buildSmallCloudIcon(CloudType type) {
    IconData icon;
    Color color;
    switch (type) {
      case CloudType.local:
        icon = Icons.laptop_chromebook;
        color = Colors.tealAccent;
        break;
      case CloudType.googleDrive:
        icon = Icons.add_to_drive;
        color = Colors.amber;
        break;
      case CloudType.oneDrive:
        icon = Icons.cloud;
        color = Colors.blue;
        break;
      case CloudType.box:
        icon = Icons.inventory_2_outlined;
        color = Colors.blue.shade600;
        break;
      case CloudType.dropbox:
        icon = Icons.folder_shared_outlined;
        color = Colors.indigoAccent;
        break;
      case CloudType.webDav:
        icon = Icons.dns;
        color = Colors.teal;
        break;
    }
    return Icon(icon, size: 13, color: color);
  }

  Widget _buildLargeTypeIcon(CloudType type) {
    IconData icon;
    Color color;
    switch (type) {
      case CloudType.local:
        icon = Icons.computer_rounded;
        color = Colors.tealAccent;
        break;
      case CloudType.googleDrive:
        icon = Icons.add_to_drive;
        color = Colors.amber.shade700;
        break;
      case CloudType.oneDrive:
        icon = Icons.cloud;
        color = Colors.blue;
        break;
      case CloudType.box:
        icon = Icons.inventory_2_outlined;
        color = Colors.blue.shade600;
        break;
      case CloudType.dropbox:
        icon = Icons.folder_shared_outlined;
        color = Colors.indigoAccent;
        break;
      case CloudType.webDav:
        icon = Icons.dns;
        color = Colors.teal;
        break;
    }
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withAlpha(25),
        shape: BoxShape.circle,
      ),
      child: Icon(icon, color: color, size: 36),
    );
  }

  Widget _buildTypeIcon(CloudType type) {
    IconData icon;
    Color color;

    switch (type) {
      case CloudType.local:
        icon = Icons.computer_rounded;
        color = Colors.tealAccent;
        break;
      case CloudType.googleDrive:
        icon = Icons.add_to_drive;
        color = Colors.amber.shade700;
        break;
      case CloudType.oneDrive:
        icon = Icons.cloud;
        color = Colors.blue;
        break;
      case CloudType.box:
        icon = Icons.inventory_2_outlined;
        color = Colors.blue.shade600;
        break;
      case CloudType.dropbox:
        icon = Icons.folder_shared_outlined;
        color = Colors.indigoAccent;
        break;
      case CloudType.webDav:
        icon = Icons.dns;
        color = Colors.teal;
        break;
    }

    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: color.withAlpha(30),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(icon, color: color, size: 20),
    );
  }

  String _getTypeDisplayName(CloudType type) {
    switch (type) {
      case CloudType.local:
        return '로컬 디스크 / 내 기기';
      case CloudType.googleDrive:
        return 'Google Drive';
      case CloudType.oneDrive:
        return 'Microsoft OneDrive';
      case CloudType.box:
        return 'Box';
      case CloudType.dropbox:
        return 'Dropbox';
      case CloudType.webDav:
        return 'WebDAV / NAS';
    }
  }

  void _playHistoryItem(BuildContext context, PlaybackRecord record, AccountManager accountManager) {
    final account = accountManager.getAccountById(record.accountId);

    if (account != null) {
      final service = accountManager.getService(account);
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => PlayerScreen(
            item: record.toMediaItem(),
            service: service,
          ),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('\'${record.fileName}\'의 연결된 계정을 찾을 수 없습니다.'),
          action: SnackBarAction(
            label: '기록 삭제',
            onPressed: () {
              PlaybackHistoryService.instance.removeRecord(
                accountId: record.accountId,
                itemId: record.itemId,
              );
            },
          ),
        ),
      );
    }
  }

  void _removeHistoryRecord(PlaybackRecord record) {
    PlaybackHistoryService.instance.removeRecord(
      accountId: record.accountId,
      itemId: record.itemId,
    );
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('\'${record.fileName}\' 기록이 삭제되었습니다.'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _confirmClearAllHistory(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('시청 기록 전체 삭제'),
        content: const Text('최근 시청 기록을 모두 삭제하시겠습니까?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () {
              PlaybackHistoryService.instance.clearAllHistory();
              Navigator.pop(context);
            },
            child: const Text('삭제', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _openShortcut(
    BuildContext context,
    FolderShortcut shortcut,
    AccountManager accountManager,
    FolderShortcutManager shortcutManager,
  ) {
    final account = accountManager.getAccountById(shortcut.accountId);

    if (account != null) {
      final service = accountManager.getService(account);
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => BrowserScreen(
            account: account,
            service: service,
            initialFolderId: shortcut.folderId,
            initialFolderName: shortcut.folderName,
            initialFolderPath: shortcut.folderPath,
          ),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('연결된 계정(\'${shortcut.accountName}\')을 찾을 수 없습니다.'),
          action: SnackBarAction(
            label: '바로가기 삭제',
            onPressed: () => shortcutManager.removeShortcut(shortcut.id),
          ),
        ),
      );
    }
  }

  void _removeShortcut(FolderShortcut shortcut, FolderShortcutManager shortcutManager) {
    shortcutManager.removeShortcut(shortcut.id);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('\'${shortcut.folderName}\' 바로가기가 삭제되었습니다.'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _openBrowser(BuildContext context, CloudAccount account, dynamic service) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => BrowserScreen(
          account: account,
          service: service,
        ),
      ),
    );
  }

  void _openAddAccountDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => const AddAccountDialog(),
    );
  }

  void _openAddFolderShortcutDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => const AddFolderShortcutDialog(),
    );
  }

  void _confirmDelete(
    BuildContext context,
    CloudAccount account,
    AccountManager accountManager,
  ) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('드라이브 연결 해제'),
        content: Text('\'${account.name}\' 연결을 목록에서 삭제하시겠습니까?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () {
              accountManager.removeAccount(account.id);
              Navigator.pop(context);
            },
            child: const Text('삭제', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Future<void> _pickAndPlayLocalFile(BuildContext context, AccountManager accountManager) async {
    try {
      if (Platform.isAndroid) {
        await PermissionUtils.ensureStoragePermission();
      }

      final files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: [
          'mp4', 'mkv', 'avi', 'mov', 'wmv', 'flv', 'webm', 'ts', '3gp', 'm4v', 'asf'
        ],
        dialogTitle: '재생할 동영상 파일 선택',
      );

      if (!mounted) return;

      if (files.isNotEmpty && files.first.path != null) {
        final path = files.first.path!;
        final file = File(path);
        final fileName = files.first.name;
        int? size;
        try {
          size = file.lengthSync();
        } catch (_) {}
        final parentDir = file.parent.path;

        final localItem = MediaItem(
          id: path,
          name: fileName,
          isFolder: false,
          size: size,
          parentId: parentDir,
          directStreamUrl: path,
        );

        final service = accountManager.getService(AccountManager.localAccount);
        Navigator.push(
          this.context,
          MaterialPageRoute(
            builder: (_) => PlayerScreen(
              item: localItem,
              service: service,
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(this.context).showSnackBar(
          SnackBar(content: Text('파일 선택 중 오류 발생: $e')),
        );
      }
    }
  }

  void _showQuickActionSheet(BuildContext context, AccountManager accountManager) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E2430),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Text(
                  '미디어 열기 및 소스 추가',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: Colors.white),
                ),
              ),
              const SizedBox(height: 12),
              ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.tealAccent.withAlpha(25),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.file_open_outlined, color: Colors.tealAccent),
                ),
                title: const Text('로컬 파일 직접 열기', style: TextStyle(fontWeight: FontWeight.bold)),
                subtitle: const Text('내 PC/기기의 동영상 파일을 바로 선택하여 재생합니다.'),
                onTap: () {
                  Navigator.pop(ctx);
                  _pickAndPlayLocalFile(context, accountManager);
                },
              ),
              ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.teal.withAlpha(25),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.computer_rounded, color: Colors.tealAccent),
                ),
                title: const Text('내 PC 폴더 탐색', style: TextStyle(fontWeight: FontWeight.bold)),
                subtitle: const Text('로컬 디스크(C:, D:) 및 다운로드/동영상 폴더를 탐색합니다.'),
                onTap: () {
                  Navigator.pop(ctx);
                  final service = accountManager.getService(AccountManager.localAccount);
                  _openBrowser(context, AccountManager.localAccount, service);
                },
              ),
              ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.blueAccent.withAlpha(25),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.cloud_upload_outlined, color: Colors.blueAccent),
                ),
                title: const Text('클라우드 드라이브 연결', style: TextStyle(fontWeight: FontWeight.bold)),
                subtitle: const Text('Google Drive, OneDrive, Box, Dropbox, WebDAV 계정을 추가합니다.'),
                onTap: () {
                  Navigator.pop(ctx);
                  _openAddAccountDialog(context);
                },
              ),
              ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.amber.withAlpha(25),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.bookmark_add_outlined, color: Colors.amber),
                ),
                title: const Text('폴더 바로가기 추가', style: TextStyle(fontWeight: FontWeight.bold)),
                subtitle: const Text('자주 보는 폴더를 홈 화면에 바로가기로 고정합니다.'),
                onTap: () {
                  Navigator.pop(ctx);
                  _openAddFolderShortcutDialog(context);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
