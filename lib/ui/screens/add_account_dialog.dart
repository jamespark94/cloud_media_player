import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/cloud_account.dart';
import '../../services/account_manager.dart';
import '../../services/google_drive_service.dart';
import '../../services/oauth_helper.dart';
import '../../services/onedrive_service.dart';

class AddAccountDialog extends StatefulWidget {
  const AddAccountDialog({super.key});

  @override
  State<AddAccountDialog> createState() => _AddAccountDialogState();
}

class _AddAccountDialogState extends State<AddAccountDialog> {
  CloudType _selectedType = CloudType.googleDrive;
  bool _isLoading = false;
  String? _statusMessage;

  // Custom API keys (BYOK)
  final TextEditingController _clientIdController = TextEditingController();
  final TextEditingController _clientSecretController = TextEditingController();

  // WebDAV
  final TextEditingController _webDavUrlController = TextEditingController();
  final TextEditingController _webDavUserController = TextEditingController();
  final TextEditingController _webDavPasswordController = TextEditingController();

  Future<void> _startOAuth() async {
    setState(() {
      _isLoading = true;
      _statusMessage = '웹 브라우저를 열어 클라우드 로그인을 진행합니다...';
    });

    try {
      if (_selectedType == CloudType.googleDrive) {
        await _authenticateGoogle();
      } else if (_selectedType == CloudType.oneDrive) {
        await _authenticateOneDrive();
      } else if (_selectedType == CloudType.webDav) {
        await _saveWebDav();
      }
      if (mounted) {
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _statusMessage = '연결 실패: $e';
        });
      }
    }
  }

  Future<void> _authenticateGoogle() async {
    final clientId = _clientIdController.text.trim().isNotEmpty
        ? _clientIdController.text.trim()
        : GoogleDriveService.defaultClientId;
    final clientSecret = _clientSecretController.text.trim().isNotEmpty
        ? _clientSecretController.text.trim()
        : null;

    final codeVerifier = OAuthHelper.generateRandomString();
    final codeChallenge = OAuthHelper.generateCodeChallenge(codeVerifier);

    final params = {
      'client_id': clientId,
      'response_type': 'code',
      'scope': 'https://www.googleapis.com/auth/drive.readonly https://www.googleapis.com/auth/userinfo.email',
      'access_type': 'offline',
      'prompt': 'consent',
      'code_challenge': codeChallenge,
      'code_challenge_method': 'S256',
    };

    final code = await OAuthHelper.authenticateWithLoopback(
      authUrlWithoutParams: GoogleDriveService.authEndpoint,
      params: params,
    );

    if (code == null) throw Exception('인증 코드가 수신되지 않았습니다.');

    setState(() => _statusMessage = '인증 토큰 교환 중...');
    await Future.delayed(const Duration(milliseconds: 600));
    final tokenData = await OAuthHelper.exchangeGoogleToken(
      code: code,
      redirectUri: params['redirect_uri']!,
      clientId: clientId,
      clientSecret: clientSecret,
      codeVerifier: codeVerifier,
    );

    final account = CloudAccount(
      id: 'gdrive_${DateTime.now().millisecondsSinceEpoch}',
      name: 'Google Drive (${DateTime.now().month}/${DateTime.now().day})',
      type: CloudType.googleDrive,
      email: '',
      accessToken: tokenData['access_token'],
      refreshToken: tokenData['refresh_token'],
      tokenExpiry: DateTime.now().add(Duration(seconds: tokenData['expires_in'] as int? ?? 3600)),
      customClientId: _clientIdController.text.trim(),
      customClientSecret: _clientSecretController.text.trim(),
    );

    if (mounted) {
      await context.read<AccountManager>().saveAccount(account);
    }
  }

  Future<void> _authenticateOneDrive() async {
    final clientId = _clientIdController.text.trim().isNotEmpty
        ? _clientIdController.text.trim()
        : OneDriveService.defaultClientId;
    final clientSecret = _clientSecretController.text.trim().isNotEmpty
        ? _clientSecretController.text.trim()
        : null;

    final codeVerifier = OAuthHelper.generateRandomString();
    final codeChallenge = OAuthHelper.generateCodeChallenge(codeVerifier);

    final params = {
      'client_id': clientId,
      'response_type': 'code',
      'scope': 'Files.Read Files.Read.All offline_access User.Read',
      'code_challenge': codeChallenge,
      'code_challenge_method': 'S256',
    };

    final code = await OAuthHelper.authenticateWithLoopback(
      authUrlWithoutParams: 'https://login.microsoftonline.com/common/oauth2/v2.0/authorize',
      params: params,
    );

    if (code == null) throw Exception('인증 코드가 수신되지 않았습니다.');

    setState(() => _statusMessage = '인증 토큰 교환 중...');
    await Future.delayed(const Duration(milliseconds: 600));
    final tokenData = await OAuthHelper.exchangeOneDriveToken(
      code: code,
      redirectUri: params['redirect_uri']!,
      clientId: clientId,
      clientSecret: clientSecret,
      codeVerifier: codeVerifier,
    );

    final account = CloudAccount(
      id: 'onedrive_${DateTime.now().millisecondsSinceEpoch}',
      name: 'OneDrive (${DateTime.now().month}/${DateTime.now().day})',
      type: CloudType.oneDrive,
      email: '',
      accessToken: tokenData['access_token'],
      refreshToken: tokenData['refresh_token'],
      tokenExpiry: DateTime.now().add(Duration(seconds: tokenData['expires_in'] as int? ?? 3600)),
      customClientId: _clientIdController.text.trim(),
      customClientSecret: _clientSecretController.text.trim(),
    );

    if (mounted) {
      await context.read<AccountManager>().saveAccount(account);
    }
  }

  Future<void> _saveWebDav() async {
    final url = _webDavUrlController.text.trim();
    if (url.isEmpty) throw Exception('WebDAV URL을 입력해주세요.');

    final account = CloudAccount(
      id: 'webdav_${DateTime.now().millisecondsSinceEpoch}',
      name: 'WebDAV (${Uri.tryParse(url)?.host ?? 'Server'})',
      type: CloudType.webDav,
      email: _webDavUserController.text.trim(),
      accessToken: '',
      webDavUrl: url,
      webDavUser: _webDavUserController.text.trim(),
      webDavPassword: _webDavPasswordController.text,
    );

    if (mounted) {
      await context.read<AccountManager>().saveAccount(account);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: 480,
        padding: const EdgeInsets.all(24),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '클라우드 드라이브 연결',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                '연결할 클라우드 스토리지를 선택하세요.',
                style: TextStyle(color: Colors.grey, fontSize: 13),
              ),
              const SizedBox(height: 20),

              // 클라우드 서비스 선택 라디오
              SegmentedButton<CloudType>(
                segments: const [
                  ButtonSegment(
                    value: CloudType.googleDrive,
                    label: Text('Google Drive'),
                    icon: Icon(Icons.cloud_queue),
                  ),
                  ButtonSegment(
                    value: CloudType.oneDrive,
                    label: Text('OneDrive'),
                    icon: Icon(Icons.cloud),
                  ),
                  ButtonSegment(
                    value: CloudType.webDav,
                    label: Text('WebDAV/네이버'),
                    icon: Icon(Icons.dns),
                  ),
                ],
                selected: {_selectedType},
                onSelectionChanged: (set) {
                  setState(() => _selectedType = set.first);
                },
              ),
              const SizedBox(height: 20),

              if (_selectedType == CloudType.webDav) ...[
                TextField(
                  controller: _webDavUrlController,
                  decoration: const InputDecoration(
                    labelText: 'WebDAV 서버 URL',
                    hintText: 'https://nas.example.com/webdav',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _webDavUserController,
                  decoration: const InputDecoration(
                    labelText: '사용자 이름/아이디',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _webDavPasswordController,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: '비밀번호',
                    border: OutlineInputBorder(),
                  ),
                ),
              ] else ...[
                // BYOK 필드 (선택 사항)
                ExpansionTile(
                  title: const Text('커스텀 API 키 설정 (선택 사항)',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                  subtitle: const Text('본인의 Client ID/Secret이 있는 경우 입력',
                      style: TextStyle(fontSize: 12, color: Colors.grey)),
                  children: [
                    TextField(
                      controller: _clientIdController,
                      decoration: const InputDecoration(
                        labelText: 'Client ID (선택)',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _clientSecretController,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Client Secret (선택)',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ],

              if (_statusMessage != null) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.blueAccent.withAlpha(30),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      if (_isLoading)
                        const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      else
                        const Icon(Icons.info_outline, size: 18, color: Colors.blueAccent),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _statusMessage!,
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _isLoading ? null : () => Navigator.pop(context),
                    child: const Text('취소'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed: _isLoading ? null : _startOAuth,
                    icon: const Icon(Icons.login),
                    label: Text(_selectedType == CloudType.webDav ? '연결하기' : '로그인 & 연결'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
