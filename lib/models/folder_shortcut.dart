import '../models/cloud_account.dart';

class FolderShortcut {
  final String id;
  final String accountId;
  final String accountName;
  final CloudType cloudType;
  final String folderId;
  final String folderName;
  final String? folderPath;
  final DateTime createdAt;

  FolderShortcut({
    required this.id,
    required this.accountId,
    required this.accountName,
    required this.cloudType,
    required this.folderId,
    required this.folderName,
    this.folderPath,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'accountId': accountId,
    'accountName': accountName,
    'cloudType': cloudType.name,
    'folderId': folderId,
    'folderName': folderName,
    'folderPath': folderPath,
    'createdAt': createdAt.toIso8601String(),
  };

  factory FolderShortcut.fromJson(Map<String, dynamic> json) => FolderShortcut(
    id: json['id'] as String,
    accountId: json['accountId'] as String,
    accountName: json['accountName'] as String,
    cloudType: CloudType.values.firstWhere(
      (e) => e.name == json['cloudType'],
      orElse: () => CloudType.googleDrive,
    ),
    folderId: json['folderId'] as String,
    folderName: json['folderName'] as String,
    folderPath: json['folderPath'] as String?,
    createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now(),
  );
}
