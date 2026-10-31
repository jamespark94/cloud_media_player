import 'dart:async';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import '../../models/subtitle_settings.dart';
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

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: SubtitleSettingsService.instance,
      builder: (context, _) {
        final settings = SubtitleSettingsService.instance.settings;

        final lines = _subtitle
            .where((s) => s.trim().isNotEmpty)
            .map((s) => s.trim())
            .toList();

        if (lines.isEmpty) {
          return const SizedBox.shrink();
        }

        final text = lines.join('\n');

        Widget subtitleBox = Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: settings.backgroundOpacity > 0.0
                ? settings.backgroundColor.withValues(
                    alpha: settings.backgroundOpacity.clamp(0.0, 1.0),
                  )
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: settings.fontSize,
              color: settings.textColor,
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
            ),
          ),
        );

        Widget positionedContent;
        switch (settings.position) {
          case SubtitlePosition.top:
            positionedContent = Positioned(
              left: 20,
              right: 20,
              top: settings.bottomOffset,
              child: Align(
                alignment: Alignment.topCenter,
                child: subtitleBox,
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
                child: subtitleBox,
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
                child: subtitleBox,
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
