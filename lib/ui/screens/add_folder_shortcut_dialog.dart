import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/cloud_account.dart';
import '../../models/folder_shortcut.dart';
import '../../models/media_item.dart';
import '../../services/account_manager.dart';
import '../../services/cloud_service_interface.dart';
import '../../services/folder_shortcut_manager.dart';

class AddFolderShortcutDialog extends StatefulWidget {
  const AddFolderShortcutDialog({super.key});

  @override
  State<AddFolderShortcutDialog> createState() => _AddFolderShortcutDialogState();
}

class _AddFolderShortcutDialogState extends State<AddFolderShortcutDialog> {
  CloudAccount? _selectedAccount;
  CloudService? _service;
  bool _isLoading = false;
  String? _errorMessage;

  // Folder navigation stack: list of (folderId, folderName)
  final List<MapEntry<String?, String>> _folderStack = [
    const MapEntry(null, '홈'),
  ];
  List<MediaItem> _subFolders = [];
  MediaItem? _selectedItem;

  @override
  void initState() {
    super.initState();
    final accountManager = context.read<AccountManager>();
    final allAccounts = [AccountManager.localAccount, ...accountManager.accounts];
    _selectedAccount = allAccounts.first;
    _service = accountManager.getService(_selectedAccount!);
    _loadFolders();
  }

  void _onAccountChanged(CloudAccount? account) {
    if (account == null || account.id == _selectedAccount?.id) return;
    setState(() {
      _selectedAccount = account;
      _service = context.read<AccountManager>().getService(account);
      _folderStack.clear();
      _folderStack.add(const MapEntry(null, '홈'));
      _selectedItem = null;
    });
    _loadFolders();
  }

  Future<void> _loadFolders() async {
    if (_service == null) return;
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _selectedItem = null;
    });

    try {
      final currentFolderId = _folderStack.last.key;
      final items = await _service!.listItems(folderId: currentFolderId);
      final folders = items.where((it) => it.isFolder).toList();
      if (mounted) {
        setState(() {
          _subFolders = folders;
          _isLoading = false;
        });
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

  void _enterFolder(MediaItem folder) {
    setState(() {
      _folderStack.add(MapEntry(folder.id, folder.name));
      _selectedItem = null;
    });
    _loadFolders();
  }

  void _navigateUp() {
    if (_folderStack.length > 1) {
      setState(() {
        _folderStack.removeLast();
        _selectedItem = null;
      });
      _loadFolders();
    }
  }

  void _navigateToIndex(int index) {
    if (index >= 0 && index < _folderStack.length - 1) {
      setState(() {
        _folderStack.removeRange(index + 1, _folderStack.length);
        _selectedItem = null;
      });
      _loadFolders();
    }
  }

  String get _currentPath => _folderStack.map((e) => e.value).join(' > ');

  void _saveShortcut() {
    if (_selectedAccount == null) return;

    String targetId;
    String targetName;
    String targetPath;

    if (_selectedItem != null) {
      // 리스트에서 특정 폴더 항목을 선택한 경우
      targetId = _selectedItem!.id;
      targetName = _selectedItem!.name;
      targetPath = '$_currentPath > $targetName';
    } else if (_folderStack.length > 1) {
      // 현재 진입해 있는 하위 폴더 자체를 바로가기로 등록하는 경우
      targetId = _folderStack.last.key!;
      targetName = _folderStack.last.value;
      targetPath = _currentPath;
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('바로가기로 추가할 폴더를 선택하거나 해당 폴더로 진입해주세요.')),
      );
      return;
    }

    final shortcut = FolderShortcut(
      id: '${_selectedAccount!.id}_$targetId',
      accountId: _selectedAccount!.id,
      accountName: _selectedAccount!.name,
      cloudType: _selectedAccount!.type,
      folderId: targetId,
      folderName: targetName,
      folderPath: targetPath,
      createdAt: DateTime.now(),
    );

    context.read<FolderShortcutManager>().addShortcut(shortcut);
    Navigator.pop(context);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('\'$targetName\' 폴더가 첫 화면 바로가기에 추가되었습니다.'),
        backgroundColor: Colors.blueAccent.shade700,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final accountManager = context.watch<AccountManager>();
    final accounts = accountManager.accounts;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      backgroundColor: const Color(0xFF1B202B),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 600),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 헤더
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.amber.withAlpha(40),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.bookmark_add, color: Colors.amber, size: 24),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '폴더 바로가기 추가',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                        SizedBox(height: 2),
                        Text(
                          '첫 화면에서 빠르게 접근할 폴더(로컬 / 클라우드)를 지정합니다',
                          style: TextStyle(fontSize: 12, color: Colors.white54),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white54),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // 저장소 계정 선택 드롭다운 (저장소가 2개 이상일 때)
              Builder(
                builder: (context) {
                  final allAccounts = [AccountManager.localAccount, ...accounts];
                  if (allAccounts.length <= 1) return const SizedBox.shrink();

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('저장소 선택', style: TextStyle(fontSize: 13, color: Colors.white70)),
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        decoration: BoxDecoration(
                          color: Colors.black26,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.white12),
                        ),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<CloudAccount>(
                            value: _selectedAccount,
                            isExpanded: true,
                            dropdownColor: const Color(0xFF222834),
                            items: allAccounts.map((acc) {
                              return DropdownMenuItem(
                                value: acc,
                                child: Row(
                                  children: [
                                    Icon(
                                      acc.type == CloudType.local
                                          ? Icons.computer_rounded
                                          : Icons.cloud_queue,
                                      size: 16,
                                      color: acc.type == CloudType.local
                                          ? Colors.tealAccent
                                          : Colors.blueAccent,
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      acc.type == CloudType.local
                                          ? '내 PC (로컬 저장소)'
                                          : '${acc.name} (${acc.type.name})',
                                    ),
                                  ],
                                ),
                              );
                            }).toList(),
                            onChanged: _onAccountChanged,
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                    ],
                  );
                },
              ),

              // 현재 위치 탐색 바 (Breadcrumb)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black26,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.white12),
                ),
                child: Row(
                  children: [
                    if (_folderStack.length > 1)
                      IconButton(
                        icon: const Icon(Icons.arrow_back, size: 18),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        tooltip: '상위 폴더로 이동',
                        onPressed: _navigateUp,
                      ),
                    if (_folderStack.length > 1) const SizedBox(width: 8),
                    const Icon(Icons.folder_open, size: 18, color: Colors.amber),
                    const SizedBox(width: 8),
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            for (int i = 0; i < _folderStack.length; i++) ...[
                              if (i > 0)
                                const Icon(Icons.chevron_right, size: 16, color: Colors.white30),
                              InkWell(
                                borderRadius: BorderRadius.circular(4),
                                onTap: i == _folderStack.length - 1 ? null : () => _navigateToIndex(i),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                  child: Text(
                                    _folderStack[i].value,
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: i == _folderStack.length - 1 ? FontWeight.bold : FontWeight.normal,
                                      color: i == _folderStack.length - 1 ? Colors.amber : Colors.white70,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.refresh, size: 18),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      tooltip: '새로고침',
                      onPressed: _loadFolders,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),

              // 폴더 리스트 목록
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black12,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.white10),
                  ),
                  child: _buildFolderList(),
                ),
              ),
              const SizedBox(height: 16),

              // 하단 액션 버튼
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _selectedItem != null
                              ? '선택됨: ${_selectedItem!.name}'
                              : (_folderStack.length > 1 ? '현재 진입 폴더: ${_folderStack.last.value}' : '폴더를 선택하거나 더블클릭하여 진입하세요'),
                          style: TextStyle(
                            fontSize: 12,
                            color: (_selectedItem != null || _folderStack.length > 1)
                                ? Colors.blueAccent
                                : Colors.white38,
                            fontWeight: FontWeight.w600,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('취소', style: TextStyle(color: Colors.white60)),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blueAccent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    ),
                    onPressed: (_selectedItem != null || _folderStack.length > 1)
                        ? _saveShortcut
                        : null,
                    icon: const Icon(Icons.add_to_photos, size: 18),
                    label: Text(
                      _selectedItem != null
                          ? '\'${_selectedItem!.name}\' 추가'
                          : (_folderStack.length > 1 ? '현재 폴더 바로가기 추가' : '바로가기 추가'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFolderList() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: Colors.redAccent, size: 36),
              const SizedBox(height: 8),
              Text(_errorMessage!, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12)),
              const SizedBox(height: 8),
              TextButton(onPressed: _loadFolders, child: const Text('다시 시도')),
            ],
          ),
        ),
      );
    }

    if (_subFolders.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.folder_open, size: 48, color: Colors.white24),
              const SizedBox(height: 10),
              const Text('하위 폴더가 없습니다.', style: TextStyle(color: Colors.white54, fontSize: 13)),
              if (_folderStack.length > 1) ...[
                const SizedBox(height: 6),
                const Text('현재 폴더를 바로가기로 등록할 수 있습니다.', style: TextStyle(color: Colors.blueAccent, fontSize: 12)),
              ],
            ],
          ),
        ),
      );
    }

    final shortcutMgr = context.watch<FolderShortcutManager>();

    return ListView.builder(
      itemCount: _subFolders.length,
      itemBuilder: (context, index) {
        final folder = _subFolders[index];
        final isSelected = _selectedItem?.id == folder.id;
        final isAlreadyShortcut = _selectedAccount != null &&
            shortcutMgr.isFolderShortcut(_selectedAccount!.id, folder.id);

        return ListTile(
          selected: isSelected,
          selectedTileColor: Colors.blueAccent.withAlpha(40),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          leading: Icon(
            Icons.folder,
            color: isAlreadyShortcut ? Colors.amber : (isSelected ? Colors.blueAccent : Colors.amber.shade300),
          ),
          title: Text(
            folder.name,
            style: TextStyle(
              fontSize: 14,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              color: isAlreadyShortcut ? Colors.amber.shade200 : Colors.white,
            ),
          ),
          subtitle: isAlreadyShortcut
              ? const Text('이미 바로가기로 등록됨', style: TextStyle(color: Colors.amber, fontSize: 11))
              : null,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_forward, size: 18, color: Colors.white54),
                tooltip: '폴더 내부로 진입',
                onPressed: () => _enterFolder(folder),
              ),
            ],
          ),
          onTap: () {
            setState(() {
              if (_selectedItem?.id == folder.id) {
                // 이미 선택된 상태에서 다시 탭하면 폴더 내부로 진입
                _enterFolder(folder);
              } else {
                _selectedItem = folder;
              }
            });
          },
        );
      },
    );
  }
}
