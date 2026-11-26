import 'package:flutter/material.dart';

/// API 키 입력·마스킹 표시·저장·삭제를 공통 처리하는 보안 키 설정 카드 위젯.
class ApiKeySettingsCard extends StatefulWidget {
  final String title;
  final String? description;
  final String hintExisting;
  final String hintEmpty;
  final bool hasKey;
  final String? maskedKey;
  final IconData icon;
  final Future<void> Function(String apiKey) onSave;
  final Future<void> Function() onDelete;
  final void Function(String message, {bool isWarning})? onFeedback;

  const ApiKeySettingsCard({
    super.key,
    required this.title,
    this.description,
    required this.hintExisting,
    required this.hintEmpty,
    required this.hasKey,
    this.maskedKey,
    this.icon = Icons.vpn_key,
    required this.onSave,
    required this.onDelete,
    this.onFeedback,
  });

  @override
  State<ApiKeySettingsCard> createState() => _ApiKeySettingsCardState();
}

class _ApiKeySettingsCardState extends State<ApiKeySettingsCard> {
  final TextEditingController _controller = TextEditingController();
  bool _obscure = true;
  bool _isSaving = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _handleSave() async {
    final input = _controller.text.trim();
    if (input.isEmpty) {
      widget.onFeedback?.call('${widget.title}를 입력해 주세요.', isWarning: true);
      return;
    }
    setState(() => _isSaving = true);
    try {
      await widget.onSave(input);
      _controller.clear();
      widget.onFeedback?.call('${widget.title}가 보안 저장소에 저장되었습니다.');
    } catch (e) {
      widget.onFeedback?.call('API 키 저장 중 오류가 발생했습니다: $e', isWarning: true);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _handleDelete() async {
    setState(() => _isSaving = true);
    try {
      await widget.onDelete();
      _controller.clear();
      widget.onFeedback?.call('저장된 ${widget.title}를 삭제했습니다.');
    } catch (e) {
      widget.onFeedback?.call('API 키 삭제 중 오류가 발생했습니다: $e', isWarning: true);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(widget.icon, size: 15, color: Colors.cyanAccent),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  widget.title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: (widget.hasKey
                          ? Colors.greenAccent
                          : Colors.orangeAccent)
                      .withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  widget.hasKey
                      ? '저장됨 (${widget.maskedKey ?? ''})'
                      : '미입력',
                  style: TextStyle(
                    fontSize: 10,
                    color: widget.hasKey
                        ? Colors.greenAccent
                        : Colors.orangeAccent,
                  ),
                ),
              ),
            ],
          ),
          if (widget.description != null) ...[
            const SizedBox(height: 5),
            Text(
              widget.description!,
              style: const TextStyle(color: Colors.white60, fontSize: 10.5),
            ),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  obscureText: _obscure,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText:
                        widget.hasKey ? widget.hintExisting : widget.hintEmpty,
                    hintStyle:
                        const TextStyle(color: Colors.white38, fontSize: 11),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    filled: true,
                    fillColor: const Color(0xFF141821),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide: const BorderSide(color: Colors.white12),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide: const BorderSide(color: Colors.white12),
                    ),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscure ? Icons.visibility_off : Icons.visibility,
                        size: 16,
                        color: Colors.white54,
                      ),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              ElevatedButton(
                onPressed: _isSaving ? null : _handleSave,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.cyanAccent,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 9,
                  ),
                  minimumSize: Size.zero,
                ),
                child: const Text(
                  '저장',
                  style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold),
                ),
              ),
              if (widget.hasKey) ...[
                const SizedBox(width: 4),
                IconButton(
                  tooltip: '저장된 API Key 삭제',
                  icon: const Icon(
                    Icons.delete_outline,
                    size: 18,
                    color: Colors.redAccent,
                  ),
                  onPressed: _isSaving ? null : _handleDelete,
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
