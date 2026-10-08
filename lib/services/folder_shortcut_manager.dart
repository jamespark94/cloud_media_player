import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/folder_shortcut.dart';

class FolderShortcutManager extends ChangeNotifier {
  static const String _storageKey = 'saved_folder_shortcuts';
  List<FolderShortcut> _shortcuts = [];

  List<FolderShortcut> get shortcuts => List.unmodifiable(_shortcuts);

  Future<void> loadShortcuts() async {
    final prefs = await SharedPreferences.getInstance();
    final data = prefs.getString(_storageKey);
    if (data != null && data.isNotEmpty) {
      try {
        final List<dynamic> list = jsonDecode(data);
        _shortcuts = list.map((e) => FolderShortcut.fromJson(e as Map<String, dynamic>)).toList();
      } catch (_) {
        _shortcuts = [];
      }
    } else {
      _shortcuts = [];
    }
    notifyListeners();
  }

  bool isFolderShortcut(String accountId, String folderId) {
    return _shortcuts.any((s) => s.accountId == accountId && s.folderId == folderId);
  }

  Future<void> addShortcut(FolderShortcut shortcut) async {
    _shortcuts.removeWhere((s) => s.accountId == shortcut.accountId && s.folderId == shortcut.folderId);
    _shortcuts.insert(0, shortcut);
    await _persist();
    notifyListeners();
  }

  Future<void> removeShortcut(String id) async {
    _shortcuts.removeWhere((s) => s.id == id);
    await _persist();
    notifyListeners();
  }

  Future<void> removeShortcutByFolder(String accountId, String folderId) async {
    _shortcuts.removeWhere((s) => s.accountId == accountId && s.folderId == folderId);
    await _persist();
    notifyListeners();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = jsonEncode(_shortcuts.map((e) => e.toJson()).toList());
    await prefs.setString(_storageKey, jsonStr);
  }
}
