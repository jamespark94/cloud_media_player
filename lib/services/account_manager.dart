import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/cloud_account.dart';
import 'cloud_service_interface.dart';
import 'google_drive_service.dart';
import 'onedrive_service.dart';
import 'webdav_service.dart';

class AccountManager extends ChangeNotifier {
  static const String _storageKey = 'saved_cloud_accounts';
  List<CloudAccount> _accounts = [];

  List<CloudAccount> get accounts => List.unmodifiable(_accounts);

  Future<void> loadAccounts() async {
    final prefs = await SharedPreferences.getInstance();
    final data = prefs.getString(_storageKey);
    if (data != null && data.isNotEmpty) {
      _accounts = CloudAccount.decodeList(data);
    } else {
      _accounts = [];
    }
    notifyListeners();
  }

  Future<void> saveAccount(CloudAccount account) async {
    final index = _accounts.indexWhere((a) => a.id == account.id);
    if (index >= 0) {
      _accounts[index] = account;
    } else {
      _accounts.add(account);
    }
    await _persist();
    notifyListeners();
  }

  Future<void> removeAccount(String id) async {
    _accounts.removeWhere((a) => a.id == id);
    await _persist();
    notifyListeners();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_storageKey, CloudAccount.encodeList(_accounts));
  }

  CloudService getService(CloudAccount account) {
    switch (account.type) {
      case CloudType.googleDrive:
        return GoogleDriveService(account);
      case CloudType.oneDrive:
        return OneDriveService(account);
      case CloudType.webDav:
        return WebDavService(account);
    }
  }
}
