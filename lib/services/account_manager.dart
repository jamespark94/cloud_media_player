import 'baidu_service.dart';
import 'terabox_service.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/cloud_account.dart';
import 'box_service.dart';
import 'cloud_service_interface.dart';
import 'dropbox_service.dart';
import 'google_drive_service.dart';
import 'local_disk_service.dart';
import 'onedrive_service.dart';
import 'webdav_service.dart';

class AccountManager extends ChangeNotifier {
  static const String _storageKey = 'saved_cloud_accounts';
  List<CloudAccount> _accounts = [];

  /// 가상의 내 기기(로컬 저장소) 기본 계정
  static final CloudAccount localAccount = CloudAccount(
    id: 'local',
    name: '내 PC (로컬 저장소)',
    type: CloudType.local,
    email: '로컬 드라이브 및 내 파일',
    accessToken: '',
  );

  List<CloudAccount> get accounts => List.unmodifiable(_accounts);

  CloudAccount? getAccountById(String id) {
    if (id == 'local') return localAccount;
    return _accounts.cast<CloudAccount?>().firstWhere((a) => a?.id == id, orElse: () => null);
  }

  /// 타 기기에서 동기화된 계정 ID가 현재 기기와 다를 때 스마트하게 매칭
  CloudAccount findMatchingAccount({
    required String accountId,
    required CloudType cloudType,
    String? email,
  }) {
    if (accountId == 'local' || cloudType == CloudType.local) {
      return localAccount;
    }

    // 1. ID 직접 일치
    final byId = getAccountById(accountId);
    if (byId != null) return byId;

    // 2. 이메일 일치
    if (email != null && email.isNotEmpty) {
      final byEmail = _accounts.cast<CloudAccount?>().firstWhere(
        (a) => a?.email.toLowerCase() == email.toLowerCase(),
        orElse: () => null,
      );
      if (byEmail != null) return byEmail;
    }

    // 3. 동일한 CloudType을 가진 첫 번째 계정
    final byType = _accounts.cast<CloudAccount?>().firstWhere(
      (a) => a?.type == cloudType,
      orElse: () => null,
    );
    if (byType != null) return byType;

    return localAccount;
  }

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
      case CloudType.local:
        return LocalDiskService(account, onAccountUpdated: saveAccount);
      case CloudType.googleDrive:
        return GoogleDriveService(account, onAccountUpdated: saveAccount);
      case CloudType.oneDrive:
        return OneDriveService(account, onAccountUpdated: saveAccount);
      case CloudType.webDav:
        return WebDavService(account, onAccountUpdated: saveAccount);
      case CloudType.box:
        return BoxService(account, onAccountUpdated: saveAccount);
      case CloudType.dropbox:
        return DropboxService(account, onAccountUpdated: saveAccount);
      case CloudType.terabox:
        return TeraBoxService(account, onAccountUpdated: saveAccount);
      case CloudType.baidu:
        return BaiduService(account, onAccountUpdated: saveAccount);
    }
  }
}
