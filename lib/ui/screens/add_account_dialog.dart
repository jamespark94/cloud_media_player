import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../models/cloud_account.dart';
import '../../services/account_manager.dart';
import '../../services/box_service.dart';
import '../../services/dropbox_service.dart';
import '../../services/google_drive_service.dart';
import '../../services/oauth_helper.dart';
import '../../services/onedrive_service.dart';
import '../../utils/battery_utils.dart';

class AddAccountDialog extends StatefulWidget {
  const AddAccountDialog({super.key});

  @override
  State<AddAccountDialog> createState() => _AddAccountDialogState();
}

class _AddAccountDialogState extends State<AddAccountDialog> {
  // null이면 1단계(서비스 목록 선택), 값이 있으면 2단계(해당 서비스 상세 설정/로그인)
  CloudType? _selectedType;
  bool _isLoading = false;
  String? _statusMessage;
  String? _errorMessage;
  bool _showManualInput = false;

  // Battery & Power Saving detection
  bool _isPowerSaveActive = false;
  bool _isBatteryOptimized = false;
  Timer? _manualRevealTimer;

  // Custom API keys (BYOK)
  final TextEditingController _clientIdController = TextEditingController();
  final TextEditingController _clientSecretController = TextEditingController();

  // WebDAV
  final TextEditingController _webDavUrlController = TextEditingController();
  final TextEditingController _webDavUserController = TextEditingController();
  final TextEditingController _webDavPasswordController = TextEditingController();

  // Manual OAuth URL/Code Fallback
  final TextEditingController _manualUrlController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _checkPowerSaveStatus();
  }

  Future<void> _checkPowerSaveStatus() async {
    if (Platform.isAndroid) {
      final isPowerSave = await BatteryUtils.isPowerSaveMode();
      final isIgnoring = await BatteryUtils.isIgnoringBatteryOptimizations();
      if (mounted) {
        setState(() {
          _isPowerSaveActive = isPowerSave;
          _isBatteryOptimized = !isIgnoring;
        });
      }
    }
  }

  @override
  void dispose() {
    _cancelOAuth();
    _manualRevealTimer?.cancel();
    _clientIdController.dispose();
    _clientSecretController.dispose();
    _webDavUrlController.dispose();
    _webDavUserController.dispose();
    _webDavPasswordController.dispose();
    _manualUrlController.dispose();
    super.dispose();
  }

  void _cancelOAuth() {
    OAuthHelper.cancelAuthentication();
    _manualRevealTimer?.cancel();
    if (mounted) {
      setState(() {
        _isLoading = false;
        _statusMessage = null;
      });
    }
  }

  Future<void> _startOAuth() async {
    if (_selectedType == null) return;

    _manualRevealTimer?.cancel();
    _manualRevealTimer = Timer(const Duration(seconds: 10), () {
      if (mounted && _isLoading && !_showManualInput) {
        setState(() => _showManualInput = true);
      }
    });

    if ((_selectedType == CloudType.box || _selectedType == CloudType.dropbox) &&
        _clientIdController.text.trim().isEmpty) {
      setState(() {
        final name = _selectedType == CloudType.box ? 'Box' : 'Dropbox';
        _errorMessage = '$name 서비스는 보안 정책상 타사 공용 키가 차단되어 있습니다.\n아래 [API 키 설정]에 본인의 개발자 App Key를 입력해 주세요.';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _statusMessage = '웹 브라우저를 열어 클라우드 로그인을 진행합니다...';
    });

    try {
      if (_selectedType == CloudType.googleDrive) {
        await _authenticateGoogle();
      } else if (_selectedType == CloudType.oneDrive) {
        await _authenticateOneDrive();
      } else if (_selectedType == CloudType.box) {
        await _authenticateBox();
      } else if (_selectedType == CloudType.dropbox) {
        await _authenticateDropbox();
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
          _statusMessage = null;
          _errorMessage = '$e';
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
        : GoogleDriveService.defaultClientSecret;

    final codeVerifier = OAuthHelper.generateRandomString();
    final codeChallenge = OAuthHelper.generateCodeChallenge(codeVerifier);

    final params = {
      'client_id': clientId,
      'response_type': 'code',
      'scope': 'https://www.googleapis.com/auth/drive.readonly https://www.googleapis.com/auth/drive.file https://www.googleapis.com/auth/userinfo.email',
      'access_type': 'offline',
      'prompt': 'consent',
      'code_challenge': codeChallenge,
      'code_challenge_method': 'S256',
    };

    final code = await OAuthHelper.authenticateWithLoopback(
      authUrlWithoutParams: GoogleDriveService.authEndpoint,
      params: params,
      port: 8999,
      redirectPath: '/callback',
    );

    if (code == null) throw Exception('인증 코드가 수신되지 않았거나 취소되었습니다.');

    setState(() => _statusMessage = '인증이 확인되었습니다. 토큰 발급 및 계정 등록 중...');
    await Future.delayed(const Duration(milliseconds: 1200));
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
      'scope': 'Files.Read Files.ReadWrite offline_access User.Read',
      'code_challenge': codeChallenge,
      'code_challenge_method': 'S256',
    };

    final port = clientId == OneDriveService.defaultClientId ? 53682 : 8999;
    final redirectPath = clientId == OneDriveService.defaultClientId ? '/' : '/callback';

    final code = await OAuthHelper.authenticateWithLoopback(
      authUrlWithoutParams: 'https://login.microsoftonline.com/common/oauth2/v2.0/authorize',
      params: params,
      port: port,
      redirectPath: redirectPath,
    );

    if (code == null) throw Exception('인증 코드가 수신되지 않았거나 취소되었습니다.');

    setState(() => _statusMessage = '인증이 확인되었습니다. 토큰 발급 및 계정 등록 중...');
    await Future.delayed(const Duration(milliseconds: 1200));
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

  Future<void> _authenticateBox() async {
    final clientId = _clientIdController.text.trim().isNotEmpty
        ? _clientIdController.text.trim()
        : BoxService.defaultClientId;
    final clientSecret = _clientSecretController.text.trim().isNotEmpty
        ? _clientSecretController.text.trim()
        : null;

    final codeVerifier = OAuthHelper.generateRandomString();
    final codeChallenge = OAuthHelper.generateCodeChallenge(codeVerifier);

    final params = {
      'client_id': clientId,
      'response_type': 'code',
      'code_challenge': codeChallenge,
      'code_challenge_method': 'S256',
    };

    final code = await OAuthHelper.authenticateWithLoopback(
      authUrlWithoutParams: BoxService.authEndpoint,
      params: params,
      port: 53682,
      redirectPath: '/',
    );

    if (code == null) throw Exception('인증 코드가 수신되지 않았거나 취소되었습니다.');

    setState(() => _statusMessage = '인증이 확인되었습니다. 토큰 발급 및 계정 등록 중...');
    await Future.delayed(const Duration(milliseconds: 1200));
    final tokenData = await OAuthHelper.exchangeBoxToken(
      code: code,
      clientId: clientId,
      clientSecret: clientSecret,
      codeVerifier: codeVerifier,
      redirectUri: params['redirect_uri'],
    );

    final account = CloudAccount(
      id: 'box_${DateTime.now().millisecondsSinceEpoch}',
      name: 'Box (${DateTime.now().month}/${DateTime.now().day})',
      type: CloudType.box,
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

  Future<void> _authenticateDropbox() async {
    final clientId = _clientIdController.text.trim().isNotEmpty
        ? _clientIdController.text.trim()
        : DropboxService.defaultClientId;
    final clientSecret = _clientSecretController.text.trim().isNotEmpty
        ? _clientSecretController.text.trim()
        : null;

    final codeVerifier = OAuthHelper.generateRandomString();
    final codeChallenge = OAuthHelper.generateCodeChallenge(codeVerifier);

    final params = {
      'client_id': clientId,
      'response_type': 'code',
      'token_access_type': 'offline',
      'code_challenge': codeChallenge,
      'code_challenge_method': 'S256',
    };

    final code = await OAuthHelper.authenticateWithLoopback(
      authUrlWithoutParams: DropboxService.authEndpoint,
      params: params,
      port: 53682,
      redirectPath: '/',
    );

    if (code == null) throw Exception('인증 코드가 수신되지 않았거나 취소되었습니다.');

    setState(() => _statusMessage = '인증이 확인되었습니다. 토큰 발급 및 계정 등록 중...');
    await Future.delayed(const Duration(milliseconds: 1200));
    final tokenData = await OAuthHelper.exchangeDropboxToken(
      code: code,
      redirectUri: params['redirect_uri']!,
      clientId: clientId,
      clientSecret: clientSecret,
      codeVerifier: codeVerifier,
    );

    final account = CloudAccount(
      id: 'dropbox_${DateTime.now().millisecondsSinceEpoch}',
      name: 'Dropbox (${DateTime.now().month}/${DateTime.now().day})',
      type: CloudType.dropbox,
      email: '',
      accessToken: tokenData['access_token'],
      refreshToken: tokenData['refresh_token'],
      tokenExpiry: DateTime.now().add(Duration(seconds: tokenData['expires_in'] as int? ?? 14400)),
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
    return PopScope(
      canPop: !_isLoading,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _isLoading) {
          _cancelOAuth();
        }
      },
      child: Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Container(
          width: 480,
          padding: const EdgeInsets.all(24),
          child: SingleChildScrollView(
            child: _selectedType == null ? _buildServiceSelectionList() : _buildServiceDetailView(),
          ),
        ),
      ),
    );
  }

  /// 1단계: 세로형 클라우드 서비스 선택 목록
  Widget _buildServiceSelectionList() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              '클라우드 드라이브 연결',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            IconButton(
              icon: const Icon(Icons.close, color: Colors.grey),
              onPressed: () => Navigator.pop(context),
            ),
          ],
        ),
        const SizedBox(height: 4),
        const Text(
          '연결할 클라우드 스토리지를 선택하세요.',
          style: TextStyle(color: Colors.grey, fontSize: 13),
        ),
        const SizedBox(height: 16),

        _buildServiceTile(
          type: CloudType.googleDrive,
          title: 'Google Drive',
          subtitle: '개인/공유 구글 드라이브 동영상 스트리밍',
          icon: Icons.add_to_drive,
          iconColor: Colors.amber.shade700,
        ),
        const SizedBox(height: 8),
        _buildServiceTile(
          type: CloudType.oneDrive,
          title: 'Microsoft OneDrive',
          subtitle: '마이크로소프트 원드라이브 개인 계정 연결',
          icon: Icons.cloud,
          iconColor: Colors.blue,
        ),
        const SizedBox(height: 8),
        _buildServiceTile(
          type: CloudType.box,
          title: 'Box (Box.com)',
          subtitle: '초고속 CDN 다이렉트 스트리밍 지원',
          icon: Icons.inventory_2_outlined,
          iconColor: Colors.blue.shade600,
        ),
        const SizedBox(height: 8),
        _buildServiceTile(
          type: CloudType.dropbox,
          title: 'Dropbox',
          subtitle: '4시간 유효 직링크 고속 스트리밍 지원',
          icon: Icons.folder_shared_outlined,
          iconColor: Colors.indigoAccent,
        ),
        const SizedBox(height: 8),
        _buildServiceTile(
          type: CloudType.webDav,
          title: 'WebDAV / NAS',
          subtitle: '개인 NAS (시놀로지, QNAP, ipTIME) 및 Nextcloud',
          icon: Icons.dns,
          iconColor: Colors.teal,
        ),
      ],
    );
  }

  Widget _buildServiceTile({
    required CloudType type,
    required String title,
    required String subtitle,
    required IconData icon,
    required Color iconColor,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () {
        setState(() {
          _selectedType = type;
          _errorMessage = null;
        });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white12),
          color: Colors.white.withAlpha(8),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: iconColor.withAlpha(30),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: iconColor, size: 24),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(color: Colors.grey, fontSize: 12),
                  ),
                ],
              ),
            ),
            const Icon(Icons.arrow_forward_ios, size: 14, color: Colors.grey),
          ],
        ),
      ),
    );
  }

  /// 2단계: 선택된 서비스의 로그인/설정 상세 화면
  Widget _buildServiceDetailView() {
    final type = _selectedType!;
    String title;
    IconData icon;
    Color iconColor;

    switch (type) {
      case CloudType.googleDrive:
        title = 'Google Drive 연결';
        icon = Icons.add_to_drive;
        iconColor = Colors.amber.shade700;
        break;
      case CloudType.oneDrive:
        title = 'OneDrive 연결';
        icon = Icons.cloud;
        iconColor = Colors.blue;
        break;
      case CloudType.box:
        title = 'Box 연결';
        icon = Icons.inventory_2_outlined;
        iconColor = Colors.blue.shade600;
        break;
      case CloudType.dropbox:
        title = 'Dropbox 연결';
        icon = Icons.folder_shared_outlined;
        iconColor = Colors.indigoAccent;
        break;
      case CloudType.webDav:
        title = 'WebDAV / NAS 연결';
        icon = Icons.dns;
        iconColor = Colors.teal;
        break;
      default:
        title = '클라우드 연결';
        icon = Icons.cloud;
        iconColor = Colors.blue;
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back),
              tooltip: '서비스 목록으로 돌아가기',
              onPressed: _isLoading
                  ? null
                  : () {
                      setState(() {
                        _selectedType = null;
                        _errorMessage = null;
                      });
                    },
            ),
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: iconColor.withAlpha(30),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, color: iconColor, size: 20),
            ),
            const SizedBox(width: 8),
            Text(
              title,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        const SizedBox(height: 16),

        // 로딩 중인 경우
        if (_isLoading) ...[
          Container(
            padding: const EdgeInsets.all(24),
            alignment: Alignment.center,
            child: Column(
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 20),
                Text(
                  _statusMessage ?? '로그인 진행 중...',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 14),
                ),
                const SizedBox(height: 20),

                // 사용자가 요청한 [로그인 취소] 버튼
                OutlinedButton.icon(
                  onPressed: _cancelOAuth,
                  icon: const Icon(Icons.cancel_outlined, color: Colors.redAccent),
                  label: const Text('로그인 취소', style: TextStyle(color: Colors.redAccent)),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Colors.redAccent),
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                  ),
                ),

                if (_showManualInput) ...[
                  const SizedBox(height: 20),
                  const Divider(),
                  const SizedBox(height: 8),
                  const Text(
                    '자동으로 앱으로 돌아오지 않나요?',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    '브라우저 주소창의 전체 URL 또는 code= 값을 아래에 붙여넣으세요:',
                    style: TextStyle(color: Colors.grey, fontSize: 12),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _manualUrlController,
                    decoration: const InputDecoration(
                      hintText: 'http://localhost:53682/?code=...',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 8),
                  ElevatedButton(
                    onPressed: () {
                      final input = _manualUrlController.text.trim();
                      if (input.isNotEmpty) {
                        final ok = OAuthHelper.submitManualCallback(input);
                        if (!ok) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('유효한 인증 코드를 찾을 수 없습니다.')),
                          );
                        }
                      }
                    },
                    child: const Text('수동 코드 등록'),
                  ),
                ],
              ],
            ),
          ),
        ] else ...[
          // 에러 메시지가 있는 경우 표시
          if (_errorMessage != null) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.red.withAlpha(30),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.redAccent),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.error_outline, color: Colors.redAccent, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _errorMessage!,
                      style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
          ],

          if (type == CloudType.webDav) ...[
            TextField(
              controller: _webDavUrlController,
              decoration: const InputDecoration(
                labelText: 'WebDAV 서버 URL',
                hintText: 'https://nas.example.com:5006/webdav',
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
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              height: 46,
              child: ElevatedButton.icon(
                onPressed: _startOAuth,
                icon: const Icon(Icons.link),
                label: const Text('연결 및 계정 저장'),
              ),
            ),
          ] else ...[
            // OAuth 서비스 설정
            Text(
              type == CloudType.googleDrive
                  ? '로그인 버튼을 누르면 구글 로그인 페이지가 열립니다.'
                  : type == CloudType.oneDrive
                      ? '마이크로소프트 개인 계정으로 로그인합니다.'
                      : type == CloudType.box
                          ? 'Box.com 계정으로 로그인하여 파일을 연동합니다.'
                          : 'Dropbox 계정으로 로그인하여 파일을 연동합니다.',
              style: const TextStyle(color: Colors.grey, fontSize: 13),
            ),
            const SizedBox(height: 12),

            // 안드로이드 배터리 절전 모드 안내
            if (Platform.isAndroid && _isPowerSaveActive && _isBatteryOptimized) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.amber.withAlpha(35),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.amber.shade700, width: 1),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: const [
                        Icon(Icons.battery_alert, color: Colors.amber, size: 20),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '절전 모드 활성화됨 (네트워크 제한 주의)',
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.amber),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      '기기가 절전 모드이면 브라우저로 전환 시 백그라운드 네트워크가 차단될 수 있습니다. 아래 버튼으로 배터리 제한을 해제해 주세요.',
                      style: TextStyle(fontSize: 12),
                    ),
                    const SizedBox(height: 8),
                    ElevatedButton.icon(
                      onPressed: () async {
                        await BatteryUtils.requestIgnoreBatteryOptimizations();
                        await _checkPowerSaveStatus();
                      },
                      icon: const Icon(Icons.settings, size: 16),
                      label: const Text('배터리 최적화 예외 설정 열기'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.amber.shade800,
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],

            // Box / Dropbox 전용 필수 API Key 안내 및 입력
            if (type == CloudType.box || type == CloudType.dropbox) ...[
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: (type == CloudType.box ? Colors.blue : Colors.indigo).withAlpha(25),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: (type == CloudType.box ? Colors.blue : Colors.indigo).withAlpha(80)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.vpn_key_outlined, size: 18, color: type == CloudType.box ? Colors.blueAccent : Colors.indigoAccent),
                        const SizedBox(width: 8),
                        Text(
                          type == CloudType.box ? 'Box 무료 App Key 등록 안내' : 'Dropbox 무료 App Key 등록 안내',
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      type == CloudType.box
                          ? 'Box는 타사 공용 키를 엄격히 차단하므로, Box Developer Console(developer.box.com)에서 생성한 본인의 Custom App 키가 필요합니다.\n\n'
                            '1. developer.box.com 접속 → Custom App (OAuth 2.0)\n'
                            '2. Redirect URI에 아래 주소 등록 후 아래에 키 입력:'
                          : 'Dropbox는 타사 공용 키를 엄격히 차단하므로, Dropbox App Console(dropbox.com/developers/apps)에서 생성한 본인의 App 키가 필요합니다.\n\n'
                            '1. dropbox.com/developers/apps 접속 → Create app\n'
                            '2. Scoped access → Full Dropbox 선택\n'
                            '3. Permissions에서 files.metadata.read, files.content.read 체크\n'
                            '4. Redirect URI에 아래 주소 등록 후 아래에 키 입력:',
                      style: const TextStyle(fontSize: 11, color: Colors.white70, height: 1.4),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              color: Colors.black26,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: Colors.white24),
                            ),
                            child: const SelectableText(
                              'http://localhost:53682/',
                              style: TextStyle(fontFamily: 'monospace', fontSize: 11),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton.icon(
                          onPressed: () {
                            Clipboard.setData(const ClipboardData(text: 'http://localhost:53682/'));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Redirect URI가 클립보드에 복사되었습니다.')),
                            );
                          },
                          icon: const Icon(Icons.copy, size: 14),
                          label: const Text('복사', style: TextStyle(fontSize: 12)),
                          style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _clientIdController,
                decoration: InputDecoration(
                  labelText: type == CloudType.dropbox ? 'App Key (Client ID) *' : 'Client ID *',
                  hintText: '발급받은 Client ID 입력',
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _clientSecretController,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: type == CloudType.dropbox ? 'App Secret (Client Secret) *' : 'Client Secret *',
                  hintText: '발급받은 Client Secret 입력',
                  border: const OutlineInputBorder(),
                ),
              ),
            ] else ...[
              // 구글 드라이브 / 원드라이브는 선택적 BYOK
              ExpansionTile(
                title: const Text('커스텀 API 키 설정 (선택 사항)',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                subtitle: const Text('본인만의 Client ID/Secret이 있는 경우에만 입력',
                    style: TextStyle(fontSize: 11, color: Colors.grey)),
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

            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 46,
              child: ElevatedButton.icon(
                onPressed: _startOAuth,
                icon: const Icon(Icons.open_in_browser),
                label: const Text('브라우저 열어 로그인 및 연결', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ],
      ],
    );
  }
}
