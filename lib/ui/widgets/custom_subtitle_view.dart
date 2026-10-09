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

  @override
  void initState() {
    super.initState();
    _subtitle = widget.player.state.subtitle;
    _subscription = widget.player.stream.subtitle.listen((value) {
      if (mounted) {
        setState(() {
          _subtitle = value;
        });
      }
    });
    SubtitleSettingsService.instance.init();
  }

  @override
  void dispose() {
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
