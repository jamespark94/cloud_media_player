import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import '../../services/google_auth_manager.dart';

/// 기존의 복잡한 Client ID/Secret 입력 폼을 대체하는
/// 네이티브 Google 계정 로그인 원터치 버튼 위젯
class GoogleLoginButton extends StatefulWidget {
  final void Function(GoogleSignInAccount account)? onSuccess;
  final void Function(Object error)? onError;
  final String label;

  const GoogleLoginButton({
    super.key,
    this.onSuccess,
    this.onError,
    this.label = 'Google 계정으로 연결',
  });

  @override
  State<GoogleLoginButton> createState() => _GoogleLoginButtonState();
}

class _GoogleLoginButtonState extends State<GoogleLoginButton> {
  bool _isLoading = false;

  Future<void> _handleSignIn() async {
    if (_isLoading) return;

    setState(() {
      _isLoading = true;
    });

    try {
      final account = await GoogleAuthManager().signIn();
      if (!mounted) return;

      if (account != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${account.email} 계정으로 연결되었습니다.'),
            backgroundColor: Colors.green[700],
            behavior: SnackBarBehavior.floating,
          ),
        );
        widget.onSuccess?.call(account);
      } else {
        // 사용자가 취소함
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('로그인이 취소되었습니다.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      debugPrint('[GoogleLoginButton] Sign in failed: $e');

      String errorMessage = '로그인 중 오류가 발생했습니다.';
      final errStr = e.toString();
      if (errStr.contains('10') || errStr.contains('sign_in_failed') || errStr.contains('DEVELOPER_ERROR')) {
        errorMessage = 'Google Play 서비스 설정 오류(코드 10): GCP 콘솔에 패키지명과 SHA-1(05:4F:CA:22:84:A6:85:B3:46:56:91:7E:A3:C7:F3:9C:C2:A2:B2:AA)이 등록되어 있는지 확인하세요.';
      } else if (errStr.contains('권한이 거부')) {
        errorMessage = 'Google Drive 읽기 권한 동의가 필요합니다.';
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(errorMessage),
          backgroundColor: Colors.red[700],
          behavior: SnackBarBehavior.floating,
        ),
      );

      widget.onError?.call(e);
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.white,
          foregroundColor: Colors.black87,
          elevation: 2,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(color: Colors.grey.shade300),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16),
        ),
        onPressed: _isLoading ? null : _handleSignIn,
        child: _isLoading
            ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.blue),
                ),
              )
            : Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _buildGoogleIcon(),
                  const SizedBox(width: 12),
                  Text(
                    widget.label,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: Colors.black87,
                      letterSpacing: 0.2,
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildGoogleIcon() {
    return Container(
      width: 22,
      height: 22,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
      ),
      child: Center(
        child: Text(
          'G',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w900,
            color: Colors.blue.shade700,
            fontFamily: 'Roboto',
          ),
        ),
      ),
    );
  }
}
