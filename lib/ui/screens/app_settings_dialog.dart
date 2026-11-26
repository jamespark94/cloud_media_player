import 'package:flutter/material.dart';
import '../../services/ai_subtitle/ai_subtitle_service.dart';
import '../widgets/api_key_settings_card.dart';

/// 앱 전역 설정 다이얼로그 (GCP Cloud Translation API 키 및 Gemini API 키 관리).
class AppSettingsDialog extends StatefulWidget {
  final AiSubtitleService? aiSubtitleService;

  const AppSettingsDialog({
    super.key,
    this.aiSubtitleService,
  });

  @override
  State<AppSettingsDialog> createState() => _AppSettingsDialogState();
}

class _AppSettingsDialogState extends State<AppSettingsDialog> {
  String? _feedbackMessage;
  bool _feedbackIsWarning = false;

  AiSubtitleService get _ai =>
      widget.aiSubtitleService ?? AiSubtitleService.instance;

  @override
  void initState() {
    super.initState();
    _ai.loadGcpTranslationApiKey();
    _ai.loadGeminiApiKey();
  }

  void _showFeedback(String message, {bool isWarning = false}) {
    if (!mounted) return;
    setState(() {
      _feedbackMessage = message;
      _feedbackIsWarning = isWarning;
    });
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor:
            isWarning ? Colors.orange.shade800 : Colors.teal.shade700,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF1B202B),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: 520,
        constraints: const BoxConstraints(maxHeight: 560),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: ListenableBuilder(
          listenable: _ai,
          builder: (context, _) {
            final ai = _ai;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.settings, color: Colors.blueAccent),
                    const SizedBox(width: 10),
                    const Text(
                      '앱 설정',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(
                        Icons.close,
                        size: 20,
                        color: Colors.white70,
                      ),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
                const Divider(color: Colors.white12, height: 20),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '자막 번역 및 AI API 설정',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          '입력한 API 키는 OS 보안 저장소(flutter_secure_storage)에 암호화되어 저장됩니다.',
                          style: TextStyle(color: Colors.white60, fontSize: 11),
                        ),
                        const SizedBox(height: 12),
                        ApiKeySettingsCard(
                          title: 'GCP Cloud Translation API 키',
                          description:
                              '자막 번역을 Cloud Translation v2 API로 일괄 처리합니다. 키가 비어 있거나 403/429 오류 시 온디바이스 ML Kit(또는 기본 폴백 번역기)으로 자동 전환됩니다.',
                          hintExisting:
                              '새 GCP Cloud Translation API 키 입력 시 덮어쓰기',
                          hintEmpty: 'AIza... 형태의 GCP Translation API 키 입력',
                          icon: Icons.translate,
                          hasKey: ai.hasGcpTranslationApiKey,
                          maskedKey: ai.maskedGcpTranslationApiKey,
                          onSave: ai.saveGcpTranslationApiKey,
                          onDelete: ai.deleteGcpTranslationApiKey,
                          onFeedback: _showFeedback,
                        ),
                        const SizedBox(height: 12),
                        ApiKeySettingsCard(
                          title: 'Gemini API Key (클라우드 멀티모달 AI 자막용)',
                          description:
                              '클라우드 AI 자막 생성 모드에서 오디오 전사 및 문맥 의역에 사용됩니다.',
                          hintExisting: '새 Gemini API Key 입력 시 덮어쓰기',
                          hintEmpty: 'AIza... 형태의 Gemini API Key 입력',
                          icon: Icons.vpn_key,
                          hasKey: ai.hasGeminiApiKey,
                          maskedKey: ai.maskedGeminiApiKey,
                          onSave: ai.saveGeminiApiKey,
                          onDelete: ai.deleteGeminiApiKey,
                          onFeedback: _showFeedback,
                        ),
                        if (_feedbackMessage != null) ...[
                          const SizedBox(height: 10),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: (_feedbackIsWarning
                                      ? Colors.orangeAccent
                                      : Colors.cyanAccent)
                                  .withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: (_feedbackIsWarning
                                        ? Colors.orangeAccent
                                        : Colors.cyanAccent)
                                    .withValues(alpha: 0.45),
                              ),
                            ),
                            child: Text(
                              _feedbackMessage!,
                              style: TextStyle(
                                color: _feedbackIsWarning
                                    ? Colors.orangeAccent
                                    : Colors.cyanAccent,
                                fontSize: 11.5,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('닫기'),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
