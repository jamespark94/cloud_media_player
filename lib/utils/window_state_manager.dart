import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

/// 윈도우(데스크톱) 환경에서 창의 이전 위치, 크기, 최대화 상태를 저장하고
/// 다음 실행 시 그대로 복원해주는 유틸리티 클래스
class WindowStateManager with WindowListener {
  static final WindowStateManager instance = WindowStateManager._internal();
  WindowStateManager._internal();

  static const String _keyX = 'window_state_x';
  static const String _keyY = 'window_state_y';
  static const String _keyWidth = 'window_state_width';
  static const String _keyHeight = 'window_state_height';
  static const String _keyMaximized = 'window_state_maximized';

  Timer? _saveDebounceTimer;
  bool _isInitialized = false;

  /// 앱 시작 시 이전 위치/크기 복원 및 이벤트 리스너 등록
  Future<void> initialize({
    Size defaultSize = const Size(1280, 720),
    Size minimumSize = const Size(600, 400),
  }) async {
    if (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS) return;
    if (_isInitialized) return;
    _isInitialized = true;

    try {
      windowManager.addListener(this);

      await windowManager.setMinimumSize(minimumSize);

      final prefs = await SharedPreferences.getInstance();
      final isMaximized = prefs.getBool(_keyMaximized) ?? false;
      final x = prefs.getDouble(_keyX);
      final y = prefs.getDouble(_keyY);
      final width = prefs.getDouble(_keyWidth) ?? defaultSize.width;
      final height = prefs.getDouble(_keyHeight) ?? defaultSize.height;

      final restoredSize = Size(
        width < minimumSize.width ? defaultSize.width : width,
        height < minimumSize.height ? defaultSize.height : height,
      );

      // 위치 및 크기 복원
      if (x != null && y != null && x > -5000 && y > -5000 && x < 50000 && y < 50000) {
        await windowManager.setBounds(
          Rect.fromLTWH(x, y, restoredSize.width, restoredSize.height),
        );
      } else {
        await windowManager.setSize(restoredSize);
        await windowManager.setAlignment(Alignment.center);
      }

      await windowManager.show();

      if (isMaximized) {
        await windowManager.maximize();
      }

      await windowManager.focus();

      // 첫 렌더링 프레임 및 러너(Runner) 초기화 완료 후 최대화 상태 재확인/재적용
      if (isMaximized) {
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          await Future.delayed(const Duration(milliseconds: 150));
          try {
            if (!(await windowManager.isMaximized())) {
              await windowManager.maximize();
            }
          } catch (_) {}
        });
      }
    } catch (e) {
      debugPrint('[WindowStateManager] 초기화/복원 실패: $e');
    }
  }

  void _debounceSave() {
    _saveDebounceTimer?.cancel();
    _saveDebounceTimer = Timer(const Duration(milliseconds: 600), () {
      _saveCurrentState();
    });
  }

  Future<void> _saveCurrentState() async {
    if (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS) return;
    try {
      final isFull = await windowManager.isFullScreen();
      if (isFull) return; // 전체화면 모드 크기/위치는 창 상태로 덮어쓰지 않음

      final isMax = await windowManager.isMaximized();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keyMaximized, isMax);

      if (!isMax) {
        final bounds = await windowManager.getBounds();
        if (bounds.width >= 200 && bounds.height >= 200) {
          await prefs.setDouble(_keyX, bounds.left);
          await prefs.setDouble(_keyY, bounds.top);
          await prefs.setDouble(_keyWidth, bounds.width);
          await prefs.setDouble(_keyHeight, bounds.height);
        }
      }
    } catch (_) {}
  }

  @override
  void onWindowMoved() {
    _debounceSave();
  }

  @override
  void onWindowResized() {
    _debounceSave();
  }

  @override
  void onWindowMaximize() {
    // 최대화 시에는 지연 타이머를 즉시 취소하고 최대화 상태를 즉각 영구 저장
    _saveDebounceTimer?.cancel();
    SharedPreferences.getInstance().then((prefs) {
      prefs.setBool(_keyMaximized, true);
    });
  }

  @override
  void onWindowUnmaximize() {
    // 최대화 해제 시 즉시 최대화 플래그 false 저장 후 복원된 위치/크기 디바운스 저장
    _saveDebounceTimer?.cancel();
    SharedPreferences.getInstance().then((prefs) {
      prefs.setBool(_keyMaximized, false);
    });
    _debounceSave();
  }

  @override
  void onWindowClose() {
    _saveDebounceTimer?.cancel();
    _saveCurrentState();
  }
}
