import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import 'services/account_manager.dart';
import 'services/folder_shortcut_manager.dart';
import 'services/google_auth_manager.dart';
import 'services/local_stream_proxy.dart';
import 'services/playback_history_service.dart';
import 'ui/screens/home_screen.dart';
import 'utils/platform_utils.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await windowManager.ensureInitialized();
  }

  // 1. 고화질 비디오 재생 엔진 (libmpv 기반 media_kit) 초기화
  MediaKit.ensureInitialized();

  // 2. 플랫폼 환경(에뮬레이터 여부 등) 감지 초기화
  await PlatformUtils.initialize();

  // 3. Google Sign-In 이전 로그인 세션 비차단 무음 복구
  unawaited(GoogleAuthManager().initialize());

  // 4. 대용량 동영상 구간 탐색(Seek) 및 토큰 중계 로컬 스트림 프록시 기동
  await LocalStreamProxy.instance.start();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(
          create: (_) => AccountManager()..loadAccounts(),
        ),
        ChangeNotifierProvider(
          create: (_) => FolderShortcutManager()..loadShortcuts(),
        ),
        ChangeNotifierProvider.value(
          value: PlaybackHistoryService.instance,
        ),
      ],
      child: const CloudMediaPlayerApp(),
    ),
  );
}

class CloudMediaPlayerApp extends StatelessWidget {
  const CloudMediaPlayerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Cloud Media Player',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blueAccent,
          brightness: Brightness.dark,
          surface: const Color(0xFF14171F),
        ),
        scaffoldBackgroundColor: const Color(0xFF0D0F14),
        cardColor: const Color(0xFF1B202B),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF14171F),
          elevation: 0,
          centerTitle: false,
        ),
        snackBarTheme: SnackBarThemeData(
          backgroundColor: Colors.black.withAlpha(140),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(color: Colors.white.withAlpha(50), width: 0.8),
          ),
          contentTextStyle: const TextStyle(color: Colors.white, fontSize: 13),
        ),
      ),
      home: const HomeScreen(),
    );
  }
}
