import 'dart:async';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import '../../models/subtitle_settings.dart';
import '../../services/ai_subtitle/ai_subtitle_service.dart';
import '../../services/subtitle_settings_service.dart';

class CustomSubtitleView extends StatefulWidget {
  final Player player;

  const CustomSubtitleView({
    super.key,
    required this.player,
  });

  @override
  State<CustomSubtitleView> createState() => _CustomSubtitleViewState();
}

class _CustomSubtitleViewState extends State<CustomSubtitleView> {
  List<String> _subtitle = [];
  StreamSubscription<List<String>>? _subscription;
  Timer? _bridgeClearTimer;

  @override
  void initState() {
    super.initState();
    _subscribeToPlayer(widget.player);
    SubtitleSettingsService.instance.init();
  }

  @override
  void didUpdateWidget(covariant CustomSubtitleView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.player != widget.player) {
      _subscription?.cancel();
      // 이전 플레이어에 자막이 떠 있던 상태에서 새 플레이어로 전환될 때
      // 새 플레이어가 첫 자막을 읽어오기 전까지 직전 자막을 1.5초간 브릿지 유지하여 깜빡임 방지
      final oldSubs = _subtitle;
      _subscribeToPlayer(widget.player);
      if (_subtitle.isEmpty && oldSubs.isNotEmpty) {
        _subtitle = oldSubs;
        _bridgeClearTimer?.cancel();
        _bridgeClearTimer = Timer(const Duration(milliseconds: 1500), () {
          if (mounted && widget.player.state.subtitle.isEmpty) {
            setState(() {
              _subtitle = [];
            });
          }
        });
      }
    }
  }

  void _subscribeToPlayer(Player player) {
    final cur = player.state.subtitle;
    if (cur.isNotEmpty) {
      _subtitle = cur;
    }
    _subscription = player.stream.subtitle.listen((value) {
      _bridgeClearTimer?.cancel();
      if (mounted) {
        setState(() {
          _subtitle = value;
        });
      }
    });
  }

  @override
  void dispose() {
    _bridgeClearTimer?.cancel();
    _subscription?.cancel();
    super.dispose();
  }

  Widget _buildSubtitleBox({
    required String text,
    required SubtitleSettings settings,
    required double fontSize,
    required Color textColor,
    String? badgeLabel,
    Color? borderColor,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: settings.backgroundOpacity > 0.0
            ? settings.backgroundColor.withValues(
                alpha: settings.backgroundOpacity.clamp(0.0, 1.0),
              )
            : (borderColor != null
                ? Colors.black.withValues(alpha: 0.45)
                : Colors.transparent),
        borderRadius: BorderRadius.circular(8),
        border: borderColor != null
            ? Border.all(color: borderColor, width: 1)
            : null,
      ),
      child: badgeLabel != null
          ? Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  margin: const EdgeInsets.only(right: 8),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.cyanAccent.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(
                      color: Colors.cyanAccent.withValues(alpha: 0.6),
                      width: 0.8,
                    ),
                  ),
                  child: Text(
                    badgeLabel,
                    style: const TextStyle(
                      fontSize: 10,
                      color: Colors.cyanAccent,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                Flexible(
                  child: Text(
                    text,
                    textAlign: TextAlign.center,
                    style: _subtitleTextStyle(
                      fontSize: fontSize,
                      color: textColor,
                    ),
                  ),
                ),
              ],
            )
          : Text(
              text,
              textAlign: TextAlign.center,
              style: _subtitleTextStyle(
                fontSize: fontSize,
                color: textColor,
              ),
            ),
    );
  }

  TextStyle _subtitleTextStyle({
    required double fontSize,
    required Color color,
  }) {
    return TextStyle(
      fontSize: fontSize,
      color: color,
      fontWeight: FontWeight.w600,
      height: 1.35,
      shadows: [
        Shadow(
          offset: const Offset(1.2, 1.2),
          blurRadius: 2.5,
          color: Colors.black.withValues(alpha: 0.95),
        ),
        Shadow(
          offset: const Offset(-1.2, -1.2),
          blurRadius: 2.5,
          color: Colors.black.withValues(alpha: 0.95),
        ),
        Shadow(
          offset: const Offset(1.2, -1.2),
          blurRadius: 2.5,
          color: Colors.black.withValues(alpha: 0.95),
        ),
        Shadow(
          offset: const Offset(-1.2, 1.2),
          blurRadius: 2.5,
          color: Colors.black.withValues(alpha: 0.95),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        SubtitleSettingsService.instance,
        AiSubtitleService.instance,
      ]),
      builder: (context, _) {
        final settings = SubtitleSettingsService.instance.settings;
        final aiService = AiSubtitleService.instance;

        final origLines = _subtitle
            .where((s) => s.trim().isNotEmpty)
            .map((s) => s.trim())
            .toList();

        List<String> aiLines = const [];
        bool isAiStatusOnly = false;
        if (aiService.isEnabled) {
          final seg = aiService.currentSegment;
          if (seg != null) {
            final formatted = seg.formatForDisplay(
              displayMode: settings.aiDisplayMode,
            );
            aiLines = formatted
                .split('\n')
                .where((s) => s.trim().isNotEmpty)
                .map((s) => s.trim())
                .toList();
          } else if (aiService.isInitializing || aiService.isProcessingChunk) {
            final status = aiService.statusMessage ?? 'AI 실시간 자막 분석 중...';
            aiLines = [status];
            isAiStatusOnly = true;
          }
        }

        if (origLines.isEmpty && aiLines.isEmpty) {
          return const SizedBox.shrink();
        }

        final hasBoth = origLines.isNotEmpty && aiLines.isNotEmpty;

        Widget subtitleContent;
        if (hasBoth) {
          // 원 자막(SMI/SRT)과 AI 자막을 위아래로 동시 표시해 정확도 비교 가능
          subtitleContent = Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildSubtitleBox(
                text: aiLines.join('\n'),
                settings: settings,
                fontSize: isAiStatusOnly
                    ? (settings.fontSize * 0.6).clamp(11.0, 16.0)
                    : (settings.fontSize * 0.88).clamp(13.0, 38.0),
                textColor: isAiStatusOnly
                    ? Colors.cyanAccent
                    : const Color(0xFFB2F5EA),
                badgeLabel: 'AI',
                borderColor: Colors.cyanAccent.withValues(alpha: 0.45),
              ),
              const SizedBox(height: 6),
              _buildSubtitleBox(
                text: origLines.join('\n'),
                settings: settings,
                fontSize: settings.fontSize,
                textColor: settings.textColor,
              ),
            ],
          );
        } else if (aiLines.isNotEmpty) {
          subtitleContent = _buildSubtitleBox(
            text: aiLines.join('\n'),
            settings: settings,
            fontSize: isAiStatusOnly
                ? (settings.fontSize * 0.65).clamp(12.0, 18.0)
                : settings.fontSize,
            textColor: isAiStatusOnly ? Colors.cyanAccent : settings.textColor,
          );
        } else {
          subtitleContent = _buildSubtitleBox(
            text: origLines.join('\n'),
            settings: settings,
            fontSize: settings.fontSize,
            textColor: settings.textColor,
          );
        }

        Widget positionedContent;
        switch (settings.position) {
          case SubtitlePosition.top:
            positionedContent = Positioned(
              left: 20,
              right: 20,
              top: settings.bottomOffset,
              child: Align(
                alignment: Alignment.topCenter,
                child: subtitleContent,
              ),
            );
            break;
          case SubtitlePosition.center:
            positionedContent = Positioned(
              left: 20,
              right: 20,
              top: 0,
              bottom: 0,
              child: Center(
                child: subtitleContent,
              ),
            );
            break;
          case SubtitlePosition.bottom:
            positionedContent = Positioned(
              left: 20,
              right: 20,
              bottom: settings.bottomOffset,
              child: Align(
                alignment: Alignment.bottomCenter,
                child: subtitleContent,
              ),
            );
            break;
        }

        return IgnorePointer(
          child: Stack(
            fit: StackFit.expand,
            children: [positionedContent],
          ),
        );
      },
    );
  }
}
