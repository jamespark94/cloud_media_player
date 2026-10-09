import 'dart:io';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

class PermissionUtils {
  /// Android 저장소 및 미디어 접근 권한 확인 및 요청
  static Future<bool> ensureStoragePermission() async {
    if (!Platform.isAndroid) return true;

    try {
      // 1. Android 11+ (API 30+) 모든 파일 관리 권한(SD 카드 및 전체 폴더 접근용) 확인
      final manageStatus = await Permission.manageExternalStorage.status;
      if (manageStatus.isGranted) {
        return true;
      }

      // manageExternalStorage 권한 요청 시도
      final reqStatus = await Permission.manageExternalStorage.request();
      if (reqStatus.isGranted) {
        return true;
      }

      // 2. Android 13+ (API 33+) 미디어 권한 또는 레거시 저장소 권한 요청
      final statuses = await [
        Permission.videos,
        Permission.audio,
        Permission.storage,
      ].request();

      final granted = statuses[Permission.videos]?.isGranted == true ||
          statuses[Permission.storage]?.isGranted == true;

      return granted;
    } catch (_) {
      return false;
    }
  }

  /// 현재 저장소 권한이 허용되어 있는지 확인
  static Future<bool> hasStoragePermission() async {
    if (!Platform.isAndroid) return true;

    try {
      if (await Permission.manageExternalStorage.isGranted) return true;
      if (await Permission.videos.isGranted) return true;
      if (await Permission.storage.isGranted) return true;
      return false;
    } catch (_) {
      return false;
    }
  }

  /// SD 카드 및 전체 저장소 직접 파일 접근을 위한 '모든 파일 관리 권한' 여부 확인
  static Future<bool> hasManageStoragePermission() async {
    if (!Platform.isAndroid) return true;
    try {
      return await Permission.manageExternalStorage.isGranted;
    } catch (_) {
      return false;
    }
  }

  /// 모든 파일 관리 권한 허용 안내 팝업 다이얼로그 표시
  static Future<bool> showPermissionGuideDialog(BuildContext context, {String? customMessage}) async {
    if (!context.mounted) return false;

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.folder_special, color: Colors.amber),
            SizedBox(width: 8),
            Text('저장소 권한 안내', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
          ],
        ),
        content: Text(
          customMessage ??
              '외장 SD 카드 및 기기 내 모든 동영상 폴더에 원활하게 접근하려면 \'모든 파일에 대한 접근/관리\' 권한이 필요합니다.\n\n설정 화면으로 이동하여 권한을 허용하시겠습니까?',
          style: const TextStyle(fontSize: 14, height: 1.45),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('나중에'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.blueAccent),
            child: const Text('설정으로 이동', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (result == true) {
      await openAppSettings();
      return true;
    }
    return false;
  }
}
