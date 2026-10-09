import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../models/cloud_account.dart';
import '../../models/folder_shortcut.dart';
import '../../models/media_item.dart';
import '../../services/cloud_service_interface.dart';
import '../../services/folder_shortcut_manager.dart';
import '../../services/local_disk_service.dart';
import '../../services/playback_history_service.dart';
import '../../utils/permission_utils.dart';
import 'player_screen.dart';

enum BrowserViewMode {
  largeIcons('큰 아이콘', Icons.grid_view_rounded),
  smallIcons('작은 아이콘', Icons.view_comfy_alt_outlined),
  list('목록', Icons.format_list_bulleted_rounded),
  details('자세히', Icons.table_rows_outlined);

  final String label;
  final IconData icon;

  const BrowserViewMode(this.label, this.icon);
}

class BrowserScreen extends StatefulWidget {
  final CloudAccount account;
  final CloudService service;
  final String? initialFolderId;
  final String? initialFolderName;
  final String? initialFolderPath;

  const BrowserScreen({
    super.key,
    required this.account,
    required this.service,
    this.initialFolderId,
    this.initialFolderName,
    this.initialFolderPath,
  });

  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen> {
  bool _isLoading = true;
  String? _errorMessage;
  List<MediaItem> _allItems = [];
  List<MediaItem> _filteredItems = [];
  
  // Navigation stack (folderId, folderName)
  late final List<MapEntry<String?, String>> _folderStack;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _breadcrumbScrollController = ScrollController();

  String get _currentFolderPath => _folderStack.map((e) => e.value).join(' > ');

  static const String _prefViewModeKey = 'browser_explorer_view_mode';
  BrowserViewMode _viewMode = BrowserViewMode.details;

  @override
  void initState() {
    super.initState();
    _loadViewMode();
    _folderStack = [
      MapEntry(null, widget.account.type == CloudType.local ? '내 PC' : '홈'),
      if (widget.initialFolderId != null)
        MapEntry(widget.initialFolderId, widget.initialFolderName ?? '폴더'),
    ];
    _loadFolder();
  }

  Future<void> _loadViewMode() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_prefViewModeKey);
    if (saved != null) {
      final mode = BrowserViewMode.values.firstWhere(
        (m) => m.name == saved,
        orElse: () => BrowserViewMode.details,
      );
      if (mounted) {
        setState(() => _viewMode = mode);
      }
    }
  }

  Future<void> _changeViewMode(BrowserViewMode mode) async {
    setState(() => _viewMode = mode);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefViewModeKey, mode.name);
  }

  @override
  void dispose() {
    _breadcrumbScrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _scrollToCurrentFolder() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_breadcrumbScrollController.hasClients) {
        _breadcrumbScrollController.animateTo(
          _breadcrumbScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _loadFolder() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final currentFolderId = _folderStack.last.key;
      final items = await widget.service.listItems(folderId: currentFolderId);
      if (mounted) {
        setState(() {
          _allItems = items;
          _applyFilter();
          _isLoading = false;
        });
        _scrollToCurrentFolder();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = e.toString();
        });
      }
    }
  }

  void _applyFilter() {
    if (_searchQuery.trim().isEmpty) {
      _filteredItems = List.from(_allItems);
    } else {
      final q = _searchQuery.toLowerCase();
      _filteredItems = _allItems.where((item) => item.name.toLowerCase().contains(q)).toList();
    }
  }

  void _navigateToFolder(MediaItem folder) {
    if (folder.id == '__ACTION_ADD_STORAGE__') {
      _pickAndAddCustomStorage();
      return;
    }
    _folderStack.add(MapEntry(folder.id, folder.name));
    _searchController.clear();
    _searchQuery = '';
    _loadFolder();
  }

  Future<void> _pickAndAddCustomStorage() async {
    if (Platform.isAndroid) {
      final hasPerm = await PermissionUtils.hasManageStoragePermission();
      if (!hasPerm && mounted) {
        final goSettings = await PermissionUtils.showPermissionGuideDialog(
          context,
          customMessage: 'SD 카드 또는 사용자 지정 폴더에 원활하게 접근하려면 \'모든 파일에 대한 관리\' 권한이 필요합니다.\n\n설정 화면으로 이동하여 권한을 허용하시겠습니까?',
        );
        if (goSettings) return;
      }
    }

    try {
      final selectedPath = await FilePicker.getDirectoryPath(
        dialogTitle: '추가할 SD 카드 또는 로컬 폴더 선택',
      );
      if (selectedPath != null && selectedPath.isNotEmpty && mounted) {
        await LocalDiskService.addCustomStoragePath(selectedPath);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('새 저장소(\'$selectedPath\')가 등록되었습니다.'),
              duration: const Duration(seconds: 2),
            ),
          );
          _loadFolder();
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('폴더 선택 중 오류 발생: $e')),
        );
      }
    }
  }

  bool _navigateBack() {
    if (_folderStack.length > 1) {
      _folderStack.removeLast();
      _searchController.clear();
      _searchQuery = '';
      _loadFolder();
      return true;
    }
    return false;
  }

  void _navigateToIndex(int index) {
    if (index >= 0 && index < _folderStack.length - 1) {
      setState(() {
        _folderStack.removeRange(index + 1, _folderStack.length);
        _searchController.clear();
        _searchQuery = '';
      });
      _loadFolder();
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentFolderName = _folderStack.last.value;

    return PopScope(
      canPop: _folderStack.length <= 1,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          _navigateBack();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Row(
            children: [
              _buildCloudIcon(widget.account.type),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  widget.account.name,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (_folderStack.length > 1) ...[
                const SizedBox(width: 8),
                Text(
                  '• $currentFolderName',
                  style: const TextStyle(fontSize: 13, color: Colors.amber, fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
          leading: IconButton(
            icon: Icon(_folderStack.length > 1 ? Icons.arrow_back : Icons.home),
            tooltip: _folderStack.length > 1 ? '상위 폴더로 이동' : '첫 화면으로 이동',
            onPressed: () {
              if (_folderStack.length > 1) {
                _navigateBack();
              } else {
                Navigator.pop(context);
              }
            },
          ),
          actions: [
            // 윈도우 탐색기 스타일 보기 옵션 드롭다운 메뉴
            PopupMenuButton<BrowserViewMode>(
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
              itemBuilder: (context) => BrowserViewMode.values.map((mode) {
                final isSelected = mode == _viewMode;
                return PopupMenuItem<BrowserViewMode>(
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
            // 첫 화면(홈) 바로가기 버튼
            IconButton(
              icon: const Icon(Icons.home_outlined),
              tooltip: '첫 화면(홈)으로 이동',
              onPressed: () => Navigator.pop(context),
            ),
            // 클라우드 최상위(홈) 바로가기 버튼
            if (_folderStack.length > 1)
              IconButton(
                icon: const Icon(Icons.drive_folder_upload_outlined),
                tooltip: '클라우드 홈(최상위)으로 이동',
                onPressed: () => _navigateToIndex(0),
              ),
            if (_folderStack.length > 1)
              Consumer<FolderShortcutManager>(
                builder: (context, shortcutMgr, _) {
                  final currentFolderId = _folderStack.last.key;
                  final isBookmarked = currentFolderId != null &&
                      shortcutMgr.isFolderShortcut(widget.account.id, currentFolderId);

                  return IconButton(
                    icon: Icon(
                      isBookmarked ? Icons.bookmark : Icons.bookmark_add_outlined,
                      color: isBookmarked ? Colors.amber : Colors.white70,
                    ),
                    tooltip: isBookmarked ? '첫 화면 바로가기 해제' : '첫 화면 바로가기에 추가',
                    onPressed: () async {
                      if (currentFolderId == null) return;
                      if (isBookmarked) {
                        await shortcutMgr.removeShortcutByFolder(widget.account.id, currentFolderId);
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('\'$currentFolderName\' 바로가기가 해제되었습니다.')),
                          );
                        }
                      } else {
                        final shortcut = FolderShortcut(
                          id: '${widget.account.id}_$currentFolderId',
                          accountId: widget.account.id,
                          accountName: widget.account.name,
                          cloudType: widget.account.type,
                          folderId: currentFolderId,
                          folderName: currentFolderName,
                          folderPath: _currentFolderPath,
                          createdAt: DateTime.now(),
                        );
                        await shortcutMgr.addShortcut(shortcut);
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('\'$currentFolderName\' 폴더가 첫 화면 바로가기에 추가되었습니다.')),
                          );
                        }
                      }
                    },
                  );
                },
              ),
            if (widget.account.type == CloudType.local)
              IconButton(
                icon: const Icon(Icons.create_new_folder_outlined),
                tooltip: '저장소 / SD 카드 직접 추가',
                onPressed: _pickAndAddCustomStorage,
              ),
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: '새로고침 / 저장소 다시 감지',
              onPressed: _loadFolder,
            ),
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(96),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 1. 전체 경로 브레드크럼 주소창 (각 상위 폴더 및 홈 바로 이동)
                _buildBreadcrumbBar(),
                // 2. 검색창
                _buildSearchBar(),
              ],
            ),
          ),
        ),
        body: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_errorMessage != null) {
      final isPermission = _errorMessage!.contains('권한') || _errorMessage!.toLowerCase().contains('permission');
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isPermission ? Icons.security_outlined : Icons.error_outline,
                color: isPermission ? Colors.amber : Colors.redAccent,
                size: 56,
              ),
              const SizedBox(height: 16),
              Text(
                _errorMessage!,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 14, height: 1.5),
              ),
              const SizedBox(height: 20),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  if (isPermission && Platform.isAndroid)
                    ElevatedButton.icon(
                      onPressed: () async {
                        await openAppSettings();
                      },
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.blueAccent),
                      icon: const Icon(Icons.settings, color: Colors.white, size: 18),
                      label: const Text('설정에서 권한 허용', style: TextStyle(color: Colors.white)),
                    ),
                  OutlinedButton.icon(
                    onPressed: _loadFolder,
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('다시 시도'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    if (_filteredItems.isEmpty) {
      final isLocal = widget.account.type == CloudType.local;
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.folder_open, size: 64, color: Colors.grey.withAlpha(128)),
              const SizedBox(height: 16),
              const Text('비디오 파일이나 폴더가 없습니다.', style: TextStyle(color: Colors.grey, fontSize: 15)),
              if (isLocal && Platform.isAndroid) ...[
                const SizedBox(height: 12),
                const Text(
                  '💡 실제 동영상이 있는데도 비어있다고 나온다면\nAndroid 미디어/저장소 접근 권한을 확인해 보세요.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white54, fontSize: 12, height: 1.4),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 10,
                  alignment: WrapAlignment.center,
                  children: [
                    ElevatedButton.icon(
                      onPressed: () async {
                        final granted = await PermissionUtils.ensureStoragePermission();
                        if (!granted && mounted) {
                          await openAppSettings();
                        }
                        if (mounted) _loadFolder();
                      },
                      icon: const Icon(Icons.security, size: 16),
                      label: const Text('저장소 권한 허용/확인'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blueAccent,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: _pickAndAddCustomStorage,
                      icon: const Icon(Icons.create_new_folder_outlined, size: 16),
                      label: const Text('SD카드/폴더 직접 지정'),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadFolder,
      child: LayoutBuilder(
        builder: (context, constraints) {
          switch (_viewMode) {
            case BrowserViewMode.largeIcons:
              return _buildLargeIconsView(context, constraints.maxWidth);
            case BrowserViewMode.smallIcons:
              return _buildSmallIconsView(context, constraints.maxWidth);
            case BrowserViewMode.list:
              return _buildListView(context);
            case BrowserViewMode.details:
              return _buildDetailsView(context, constraints.maxWidth);
          }
        },
      ),
    );
  }

  Future<void> _playItem(MediaItem item) async {
    if (item.isVideo) {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => PlayerScreen(
            item: item,
            service: widget.service,
          ),
        ),
      );
      if (mounted) setState(() {});
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('동영상 파일만 재생할 수 있습니다.')),
      );
    }
  }

  Future<void> _toggleFolderShortcut(
    MediaItem item,
    FolderShortcutManager shortcutMgr,
    bool isBookmarked,
  ) async {
    if (isBookmarked) {
      await shortcutMgr.removeShortcutByFolder(widget.account.id, item.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('\'${item.name}\' 바로가기가 해제되었습니다.')),
        );
      }
    } else {
      final path = '$_currentFolderPath > ${item.name}';
      final shortcut = FolderShortcut(
        id: '${widget.account.id}_${item.id}',
        accountId: widget.account.id,
        accountName: widget.account.name,
        cloudType: widget.account.type,
        folderId: item.id,
        folderName: item.name,
        folderPath: path,
        createdAt: DateTime.now(),
      );
      await shortcutMgr.addShortcut(shortcut);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('\'${item.name}\' 폴더가 첫 화면 바로가기에 추가되었습니다.')),
        );
      }
    }
  }

  Widget _buildItemThumbnail(MediaItem item, PlaybackRecord? record, {double? width, double? height}) {
    if (record?.localThumbnailPath != null && File(record!.localThumbnailPath!).existsSync()) {
      return Image.file(
        File(record.localThumbnailPath!),
        width: width,
        height: height,
        fit: BoxFit.cover,
        errorBuilder: (ctx, err, stack) => _buildDefaultVideoThumbnail(width: width, height: height),
      );
    }

    final thumbUrl = item.thumbnailUrl ?? record?.thumbnailUrl;
    if (thumbUrl != null && thumbUrl.isNotEmpty) {
      return Image.network(
        thumbUrl,
        width: width,
        height: height,
        fit: BoxFit.cover,
        errorBuilder: (ctx, err, stack) => _buildDefaultVideoThumbnail(width: width, height: height),
      );
    }

    return _buildDefaultVideoThumbnail(width: width, height: height);
  }

  Widget _buildDefaultVideoThumbnail({double? width, double? height}) {
    return Container(
      width: width,
      height: height,
      color: const Color(0xFF141822),
      child: const Center(
        child: Icon(Icons.movie_creation_outlined, size: 36, color: Colors.white24),
      ),
    );
  }

  // 1. 큰 아이콘 보기
  Widget _buildLargeIconsView(BuildContext context, double maxWidth) {
    final count = (maxWidth / 220).floor().clamp(1, 6);
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: count,
        mainAxisExtent: 185,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
      ),
      itemCount: _filteredItems.length,
      itemBuilder: (context, index) {
        final item = _filteredItems[index];
        if (item.isFolder) {
          return _buildLargeFolderCard(context, item);
        } else {
          return _buildLargeFileCard(context, item);
        }
      },
    );
  }

  Widget _buildLargeFolderCard(BuildContext context, MediaItem item) {
    return Consumer<FolderShortcutManager>(
      builder: (context, shortcutMgr, _) {
        final isBookmarked = shortcutMgr.isFolderShortcut(widget.account.id, item.id);
        return Card(
          elevation: 2,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: Colors.amber.withAlpha(50), width: 0.8),
          ),
          color: const Color(0xFF1B202B),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => _navigateToFolder(item),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Container(
                        color: Colors.amber.withAlpha(20),
                        child: const Center(
                          child: Icon(Icons.folder, size: 56, color: Colors.amber),
                        ),
                      ),
                      Positioned(
                        top: 6,
                        left: 6,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.black.withAlpha(160),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text('폴더', style: TextStyle(fontSize: 10, color: Colors.amber, fontWeight: FontWeight.bold)),
                        ),
                      ),
                      Positioned(
                        top: 4,
                        right: 4,
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.black.withAlpha(140),
                            shape: BoxShape.circle,
                          ),
                          child: IconButton(
                            icon: Icon(
                              isBookmarked ? Icons.bookmark : Icons.bookmark_add_outlined,
                              size: 16,
                              color: isBookmarked ? Colors.amber : Colors.white70,
                            ),
                            tooltip: isBookmarked ? '바로가기 해제' : '첫 화면 바로가기 추가',
                            padding: const EdgeInsets.all(4),
                            constraints: const BoxConstraints(),
                            onPressed: () => _toggleFolderShortcut(item, shortcutMgr, isBookmarked),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Tooltip(
                        message: item.name,
                        child: Text(
                          item.name,
                          style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        isBookmarked ? '★ 바로가기 등록됨' : '폴더',
                        style: TextStyle(fontSize: 10.5, color: isBookmarked ? Colors.amber : Colors.white54),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildLargeFileCard(BuildContext context, MediaItem item) {
    final isVid = item.isVideo;

    return FutureBuilder<PlaybackRecord?>(
      future: isVid
          ? PlaybackHistoryService.instance.getRecord(accountId: widget.account.id, item: item)
          : Future.value(null),
      builder: (context, snap) {
        final record = snap.data;
        final hasResume = record != null && record.positionMillis > 5000;
        final isFinished = record != null && (record.progress >= 0.95 || (record.durationMillis > 0 && record.positionMillis == 0));

        return Card(
          elevation: 2,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(
              color: isVid ? Colors.blueAccent.withAlpha(50) : Colors.white10,
              width: 0.8,
            ),
          ),
          color: const Color(0xFF1B202B),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => _playItem(item),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (isVid)
                        _buildItemThumbnail(item, record)
                      else
                        Container(
                          color: const Color(0xFF141822),
                          child: Center(
                            child: Icon(
                              item.isSubtitle ? Icons.subtitles : Icons.insert_drive_file,
                              size: 48,
                              color: item.isSubtitle ? Colors.tealAccent : Colors.white38,
                            ),
                          ),
                        ),
                      Positioned.fill(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Colors.black.withAlpha(50),
                                Colors.transparent,
                                Colors.black.withAlpha(120),
                              ],
                              stops: const [0.0, 0.45, 1.0],
                            ),
                          ),
                        ),
                      ),
                      if (isVid)
                        Center(
                          child: Container(
                            width: 38,
                            height: 38,
                            decoration: BoxDecoration(
                              color: Colors.black.withAlpha(140),
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white.withAlpha(70), width: 1.5),
                            ),
                            child: Icon(
                              isFinished ? Icons.check_circle_outline : Icons.play_arrow_rounded,
                              size: 24,
                              color: isFinished ? Colors.greenAccent : Colors.white,
                            ),
                          ),
                        ),
                      if (item.formattedDuration.isNotEmpty)
                        Positioned(
                          bottom: 6,
                          right: 6,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.black.withAlpha(180),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              item.formattedDuration,
                              style: const TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.bold),
                            ),
                          ),
                        ),
                      if (hasResume && !isFinished)
                        Positioned(
                          bottom: 0,
                          left: 0,
                          right: 0,
                          child: LinearProgressIndicator(
                            value: record.progress,
                            minHeight: 3,
                            backgroundColor: Colors.white24,
                            valueColor: const AlwaysStoppedAnimation<Color>(Colors.blueAccent),
                          ),
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Tooltip(
                        message: item.name,
                        child: Text(
                          item.name,
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          if (item.formattedSize.isNotEmpty) ...[
                            Text(
                              item.formattedSize,
                              style: const TextStyle(fontSize: 10.5, color: Colors.white60),
                            ),
                            const SizedBox(width: 4),
                          ],
                          if (hasResume && !isFinished) ...[
                            const Text('•', style: TextStyle(fontSize: 9, color: Colors.white30)),
                            const SizedBox(width: 4),
                            Text(
                              '${(record.progress * 100).toInt()}% 시청',
                              style: const TextStyle(fontSize: 10.5, color: Colors.blueAccent, fontWeight: FontWeight.bold),
                            ),
                          ] else if (isFinished) ...[
                            const Text('•', style: TextStyle(fontSize: 9, color: Colors.white30)),
                            const SizedBox(width: 4),
                            Text(
                              '시청 완료',
                              style: TextStyle(fontSize: 10.5, color: Colors.greenAccent.shade200, fontWeight: FontWeight.bold),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // 2. 작은 아이콘 보기
  Widget _buildSmallIconsView(BuildContext context, double maxWidth) {
    final count = (maxWidth / 260).floor().clamp(1, 4);
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: count,
        mainAxisExtent: 68,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: _filteredItems.length,
      itemBuilder: (context, index) {
        final item = _filteredItems[index];
        if (item.isFolder) {
          return _buildSmallFolderCard(context, item);
        } else {
          return _buildSmallFileCard(context, item);
        }
      },
    );
  }

  Widget _buildSmallFolderCard(BuildContext context, MediaItem item) {
    return Consumer<FolderShortcutManager>(
      builder: (context, shortcutMgr, _) {
        final isBookmarked = shortcutMgr.isFolderShortcut(widget.account.id, item.id);
        return Card(
          elevation: 1,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(color: Colors.amber.withAlpha(40), width: 0.8),
          ),
          color: const Color(0xFF1E2430),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => _navigateToFolder(item),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                children: [
                  Container(
                    width: 44,
                    height: 40,
                    decoration: BoxDecoration(
                      color: Colors.amber.withAlpha(30),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Icon(Icons.folder, color: Colors.amber, size: 24),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.name,
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          isBookmarked ? '폴더 • 바로가기 등록됨' : '폴더',
                          style: TextStyle(fontSize: 10.5, color: isBookmarked ? Colors.amber : Colors.white54),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: Icon(
                      isBookmarked ? Icons.bookmark : Icons.bookmark_add_outlined,
                      size: 18,
                      color: isBookmarked ? Colors.amber : Colors.white38,
                    ),
                    tooltip: isBookmarked ? '바로가기 해제' : '첫 화면 바로가기 추가',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    onPressed: () => _toggleFolderShortcut(item, shortcutMgr, isBookmarked),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildSmallFileCard(BuildContext context, MediaItem item) {
    final isVid = item.isVideo;

    return FutureBuilder<PlaybackRecord?>(
      future: isVid
          ? PlaybackHistoryService.instance.getRecord(accountId: widget.account.id, item: item)
          : Future.value(null),
      builder: (context, snap) {
        final record = snap.data;
        final hasResume = record != null && record.positionMillis > 5000;
        final isFinished = record != null && (record.progress >= 0.95 || (record.durationMillis > 0 && record.positionMillis == 0));

        return Card(
          elevation: 1,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(
              color: isVid ? Colors.blueAccent.withAlpha(40) : Colors.white10,
              width: 0.8,
            ),
          ),
          color: const Color(0xFF1E2430),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => _playItem(item),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: SizedBox(
                      width: 44,
                      height: 40,
                      child: isVid
                          ? _buildItemThumbnail(item, record, width: 44, height: 40)
                          : Container(
                              color: Colors.white10,
                              child: Icon(
                                item.isSubtitle ? Icons.subtitles : Icons.insert_drive_file,
                                color: item.isSubtitle ? Colors.tealAccent : Colors.white54,
                                size: 22,
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.name,
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            if (item.formattedSize.isNotEmpty) ...[
                              Text(item.formattedSize, style: const TextStyle(fontSize: 10, color: Colors.white54)),
                              const SizedBox(width: 6),
                            ],
                            if (hasResume && !isFinished)
                              Text(
                                '${(record.progress * 100).toInt()}% 시청',
                                style: const TextStyle(fontSize: 10, color: Colors.blueAccent, fontWeight: FontWeight.bold),
                              )
                            else if (isFinished)
                              Text(
                                '시청 완료',
                                style: TextStyle(fontSize: 10, color: Colors.greenAccent.shade200, fontWeight: FontWeight.bold),
                              )
                            else if (item.formattedDuration.isNotEmpty)
                              Text(item.formattedDuration, style: const TextStyle(fontSize: 10, color: Colors.white54)),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (isVid)
                    const Icon(Icons.play_circle_outline, color: Colors.blueAccent, size: 20),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // 3. 목록 보기
  Widget _buildListView(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemCount: _filteredItems.length,
      separatorBuilder: (context, index) => const Divider(height: 1, color: Colors.white10),
      itemBuilder: (context, index) {
        final item = _filteredItems[index];
        if (item.isFolder) {
          return Consumer<FolderShortcutManager>(
            builder: (context, shortcutMgr, _) {
              final isBookmarked = shortcutMgr.isFolderShortcut(widget.account.id, item.id);
              return ListTile(
                dense: true,
                leading: const CircleAvatar(
                  radius: 16,
                  backgroundColor: Colors.amber,
                  foregroundColor: Colors.black87,
                  child: Icon(Icons.folder, size: 18),
                ),
                title: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                subtitle: Text(
                  isBookmarked ? '폴더 • 바로가기 등록됨' : '폴더',
                  style: TextStyle(fontSize: 11, color: isBookmarked ? Colors.amber : Colors.grey),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: Icon(
                        isBookmarked ? Icons.bookmark : Icons.bookmark_add_outlined,
                        color: isBookmarked ? Colors.amber : Colors.white60,
                        size: 18,
                      ),
                      tooltip: isBookmarked ? '바로가기 해제' : '첫 화면 바로가기 추가',
                      onPressed: () => _toggleFolderShortcut(item, shortcutMgr, isBookmarked),
                    ),
                    const Icon(Icons.chevron_right, color: Colors.grey, size: 20),
                  ],
                ),
                onTap: () => _navigateToFolder(item),
              );
            },
          );
        }

        final isVid = item.isVideo;
        return FutureBuilder<PlaybackRecord?>(
          future: isVid
              ? PlaybackHistoryService.instance.getRecord(accountId: widget.account.id, item: item)
              : Future.value(null),
          builder: (context, snap) {
            final rec = snap.data;
            final hasResume = rec != null && rec.positionMillis > 5000;
            final isFinished = rec != null && (rec.progress >= 0.95 || (rec.durationMillis > 0 && rec.positionMillis == 0));

            return ListTile(
              dense: true,
              leading: CircleAvatar(
                radius: 16,
                backgroundColor: isVid ? Colors.blueAccent : (item.isSubtitle ? Colors.teal : Colors.grey.shade800),
                foregroundColor: Colors.white,
                child: Icon(isVid ? Icons.play_arrow : (item.isSubtitle ? Icons.subtitles : Icons.insert_drive_file), size: 18),
              ),
              title: Text(
                item.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: isVid ? FontWeight.w600 : FontWeight.normal,
                  color: isVid ? Colors.white : Colors.grey,
                ),
              ),
              subtitle: Row(
                children: [
                  if (item.formattedSize.isNotEmpty) ...[
                    Text(item.formattedSize, style: const TextStyle(fontSize: 11, color: Colors.grey)),
                    const SizedBox(width: 8),
                  ],
                  if (item.formattedDuration.isNotEmpty) ...[
                    Text(item.formattedDuration, style: const TextStyle(fontSize: 11, color: Colors.blueAccent)),
                    const SizedBox(width: 8),
                  ],
                  if (isVid) ...[
                    if (hasResume && !isFinished) ...[
                      Text('• ${(rec.progress * 100).toInt()}% 시청',
                          style: const TextStyle(fontSize: 11, color: Colors.blueAccent, fontWeight: FontWeight.bold)),
                    ] else if (isFinished) ...[
                      Text('• 시청 완료',
                          style: TextStyle(fontSize: 11, color: Colors.greenAccent.shade200, fontWeight: FontWeight.bold)),
                    ],
                  ],
                ],
              ),
              trailing: isVid
                  ? IconButton(
                      icon: const Icon(Icons.play_circle_fill, color: Colors.blueAccent, size: 22),
                      tooltip: '재생',
                      onPressed: () => _playItem(item),
                    )
                  : null,
              onTap: () => _playItem(item),
            );
          },
        );
      },
    );
  }

  // 4. 자세히 보기
  Widget _buildDetailsView(BuildContext context, double maxWidth) {
    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(12),
      child: Container(
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
                  Expanded(flex: 6, child: Text('이름', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white70))),
                  Expanded(flex: 2, child: Text('유형', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white70))),
                  Expanded(flex: 2, child: Text('크기', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white70))),
                  Expanded(flex: 3, child: Text('길이 / 시청 정보', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white70))),
                  SizedBox(width: 60, child: Text('액션', textAlign: TextAlign.center, style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white70))),
                ],
              ),
            ),
            const Divider(height: 1, color: Colors.white12),
            // 테이블 행 목록
            ..._filteredItems.map((item) {
              if (item.isFolder) {
                return _buildDetailsFolderRow(context, item);
              } else {
                return _buildDetailsFileRow(context, item);
              }
            }),
          ],
        ),
      ),
    );
  }

  Widget _buildDetailsFolderRow(BuildContext context, MediaItem item) {
    return Consumer<FolderShortcutManager>(
      builder: (context, shortcutMgr, _) {
        final isBookmarked = shortcutMgr.isFolderShortcut(widget.account.id, item.id);
        return InkWell(
          onTap: () => _navigateToFolder(item),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: Colors.white10, width: 0.5)),
            ),
            child: Row(
              children: [
                Expanded(
                  flex: 6,
                  child: Row(
                    children: [
                      const Icon(Icons.folder, color: Colors.amber, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          item.name,
                          style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
                const Expanded(
                  flex: 2,
                  child: Text('폴더', style: TextStyle(fontSize: 11, color: Colors.white60)),
                ),
                const Expanded(
                  flex: 2,
                  child: Text('--', style: TextStyle(fontSize: 11, color: Colors.white38)),
                ),
                Expanded(
                  flex: 3,
                  child: Text(
                    isBookmarked ? '★ 바로가기 등록됨' : '--',
                    style: TextStyle(fontSize: 11, color: isBookmarked ? Colors.amber : Colors.white38),
                  ),
                ),
                SizedBox(
                  width: 60,
                  child: IconButton(
                    icon: Icon(
                      isBookmarked ? Icons.bookmark : Icons.bookmark_add_outlined,
                      size: 18,
                      color: isBookmarked ? Colors.amber : Colors.white38,
                    ),
                    tooltip: isBookmarked ? '바로가기 해제' : '첫 화면 바로가기 추가',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    onPressed: () => _toggleFolderShortcut(item, shortcutMgr, isBookmarked),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildDetailsFileRow(BuildContext context, MediaItem item) {
    final isVid = item.isVideo;

    return FutureBuilder<PlaybackRecord?>(
      future: isVid
          ? PlaybackHistoryService.instance.getRecord(accountId: widget.account.id, item: item)
          : Future.value(null),
      builder: (context, snap) {
        final record = snap.data;
        final hasResume = record != null && record.positionMillis > 5000;
        final isFinished = record != null && (record.progress >= 0.95 || (record.durationMillis > 0 && record.positionMillis == 0));

        String fileType;
        if (isVid) {
          final ext = item.name.contains('.') ? item.name.split('.').last.toUpperCase() : 'VIDEO';
          fileType = '동영상 ($ext)';
        } else if (item.isSubtitle) {
          final ext = item.name.contains('.') ? item.name.split('.').last.toUpperCase() : '자막';
          fileType = '자막 ($ext)';
        } else {
          fileType = '파일';
        }

        return InkWell(
          onTap: () => _playItem(item),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: Colors.white10, width: 0.5)),
            ),
            child: Row(
              children: [
                Expanded(
                  flex: 6,
                  child: Row(
                    children: [
                      Icon(
                        isVid
                            ? Icons.movie_outlined
                            : (item.isSubtitle ? Icons.subtitles_outlined : Icons.insert_drive_file_outlined),
                        color: isVid ? Colors.blueAccent : (item.isSubtitle ? Colors.tealAccent : Colors.white54),
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          item.name,
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: isVid ? FontWeight.w600 : FontWeight.normal,
                            color: isVid ? Colors.white : Colors.white70,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Text(fileType, style: const TextStyle(fontSize: 11, color: Colors.white60)),
                ),
                Expanded(
                  flex: 2,
                  child: Text(item.formattedSize.isNotEmpty ? item.formattedSize : '--',
                      style: const TextStyle(fontSize: 11, color: Colors.white60)),
                ),
                Expanded(
                  flex: 3,
                  child: Row(
                    children: [
                      if (item.formattedDuration.isNotEmpty)
                        Text(item.formattedDuration, style: const TextStyle(fontSize: 11, color: Colors.white70)),
                      if (hasResume && !isFinished) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                          decoration: BoxDecoration(
                            color: Colors.blueAccent.withAlpha(40),
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: Text('${(record.progress * 100).toInt()}% 시청',
                              style: const TextStyle(fontSize: 9.5, color: Colors.blueAccent, fontWeight: FontWeight.bold)),
                        ),
                      ] else if (isFinished) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                          decoration: BoxDecoration(
                            color: Colors.greenAccent.withAlpha(40),
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: Text('완료',
                              style: TextStyle(fontSize: 9.5, color: Colors.greenAccent.shade200, fontWeight: FontWeight.bold)),
                        ),
                      ],
                    ],
                  ),
                ),
                SizedBox(
                  width: 60,
                  child: isVid
                      ? IconButton(
                          icon: const Icon(Icons.play_arrow, color: Colors.blueAccent, size: 20),
                          tooltip: '재생',
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          onPressed: () => _playItem(item),
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildBreadcrumbBar() {
    return Container(
      height: 38,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFF161A24),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        children: [
          // 상위 폴더(위로) 이동 버튼
          IconButton(
            icon: const Icon(Icons.arrow_upward, size: 16),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            tooltip: _folderStack.length > 1 ? '상위 폴더로 이동' : '최상위 폴더입니다',
            color: _folderStack.length > 1 ? Colors.white : Colors.white24,
            onPressed: _folderStack.length > 1 ? _navigateBack : null,
          ),
          const SizedBox(width: 4),
          Container(width: 1, height: 16, color: Colors.white12),
          const SizedBox(width: 4),
          // 가로 스크롤 가능한 경로 브레드크럼 리스트
          Expanded(
            child: SingleChildScrollView(
              controller: _breadcrumbScrollController,
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  // 앱 첫 화면(홈) 버튼
                  InkWell(
                    borderRadius: BorderRadius.circular(6),
                    onTap: () => Navigator.pop(context),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: const [
                          Icon(Icons.home, size: 15, color: Colors.blueAccent),
                          SizedBox(width: 4),
                          Text(
                            '첫 화면',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.blueAccent,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const Icon(Icons.chevron_right, size: 16, color: Colors.white30),

                  // 클라우드 계정 루트 및 각 상위 폴더/현재 폴더
                  for (int i = 0; i < _folderStack.length; i++) ...[
                    if (i > 0)
                      const Icon(Icons.chevron_right, size: 16, color: Colors.white30),
                    _buildBreadcrumbItem(i),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBreadcrumbItem(int index) {
    final isLast = index == _folderStack.length - 1;
    final entry = _folderStack[index];
    final isRoot = index == 0;
    final displayName = isRoot ? '${widget.account.name} (홈)' : entry.value;

    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: isLast ? null : () => _navigateToIndex(index),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        decoration: BoxDecoration(
          color: isLast ? Colors.amber.withAlpha(25) : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: isLast ? Border.all(color: Colors.amber.withAlpha(70), width: 0.8) : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isRoot ? Icons.cloud : Icons.folder,
              size: 15,
              color: isLast
                  ? Colors.amber
                  : (isRoot ? Colors.lightBlueAccent : Colors.amber.withAlpha(180)),
            ),
            const SizedBox(width: 4),
            Text(
              displayName,
              style: TextStyle(
                fontSize: 12,
                fontWeight: isLast ? FontWeight.bold : FontWeight.w500,
                color: isLast ? Colors.amber.shade200 : Colors.white70,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
      child: SizedBox(
        height: 38,
        child: TextField(
          controller: _searchController,
          style: const TextStyle(fontSize: 13),
          decoration: InputDecoration(
            hintText: '비디오 및 폴더 검색...',
            hintStyle: const TextStyle(fontSize: 13, color: Colors.white38),
            prefixIcon: const Icon(Icons.search, size: 18),
            suffixIcon: _searchQuery.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.clear, size: 18),
                    onPressed: () {
                      _searchController.clear();
                      setState(() {
                        _searchQuery = '';
                        _applyFilter();
                      });
                    },
                  )
                : null,
            filled: true,
            fillColor: const Color(0xFF161A24),
            contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 12),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: Colors.white12),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: Colors.white12),
            ),
          ),
          onChanged: (val) {
            setState(() {
              _searchQuery = val;
              _applyFilter();
            });
          },
        ),
      ),
    );
  }

  Widget _buildCloudIcon(CloudType type) {
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
    return Icon(icon, color: color, size: 20);
  }
}
