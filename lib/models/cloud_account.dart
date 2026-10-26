import 'dart:convert';

enum CloudType {
  googleDrive,
  oneDrive,
  webDav,
  box,
  dropbox,
  local,
  terabox,
}

class CloudAccount {
  final String id;
  final String name;
  final CloudType type;
  final String email;
  String accessToken;
  String? refreshToken;
  DateTime? tokenExpiry;
  
  // Custom API Credentials (BYOK)
  final String? customClientId;
  final String? customClientSecret;

  // WebDAV / Naver Bridge specific
  final String? webDavUrl;
  final String? webDavUser;
  final String? webDavPassword;

  CloudAccount({
    required this.id,
    required this.name,
    required this.type,
    required this.email,
    required this.accessToken,
    this.refreshToken,
    this.tokenExpiry,
    this.customClientId,
    this.customClientSecret,
    this.webDavUrl,
    this.webDavUser,
    this.webDavPassword,
  });

  bool get isTokenExpired =>
      tokenExpiry != null && DateTime.now().isAfter(tokenExpiry!.subtract(const Duration(minutes: 5)));

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'type': type.name,
        'email': email,
        'accessToken': accessToken,
        'refreshToken': refreshToken,
        'tokenExpiry': tokenExpiry?.toIso8601String(),
        'customClientId': customClientId,
        'customClientSecret': customClientSecret,
        'webDavUrl': webDavUrl,
        'webDavUser': webDavUser,
        'webDavPassword': webDavPassword,
      };

  factory CloudAccount.fromJson(Map<String, dynamic> json) => CloudAccount(
        id: json['id'] as String,
        name: json['name'] as String,
        type: CloudType.values.firstWhere(
          (e) => e.name == json['type'],
          orElse: () => CloudType.googleDrive,
        ),
        email: json['email'] as String? ?? '',
        accessToken: json['accessToken'] as String? ?? '',
        refreshToken: json['refreshToken'] as String?,
        tokenExpiry: json['tokenExpiry'] != null ? DateTime.parse(json['tokenExpiry'] as String) : null,
        customClientId: json['customClientId'] as String?,
        customClientSecret: json['customClientSecret'] as String?,
        webDavUrl: json['webDavUrl'] as String?,
        webDavUser: json['webDavUser'] as String?,
        webDavPassword: json['webDavPassword'] as String?,
      );

  static String encodeList(List<CloudAccount> accounts) =>
      jsonEncode(accounts.map((e) => e.toJson()).toList());

  static List<CloudAccount> decodeList(String jsonStr) {
    if (jsonStr.isEmpty) return [];
    final list = jsonDecode(jsonStr) as List<dynamic>;
    return list.map((e) => CloudAccount.fromJson(e as Map<String, dynamic>)).toList();
  }
}
