import 'package:flutter/foundation.dart';
import '../models/subtitle_settings.dart';

class SubtitleSettingsService extends ChangeNotifier {
  static final SubtitleSettingsService instance = SubtitleSettingsService._internal();

  SubtitleSettingsService._internal();

  SubtitleSettings _settings = const SubtitleSettings();
  bool _isLoaded = false;

  SubtitleSettings get settings => _settings;
  bool get isLoaded => _isLoaded;

  Future<void> init() async {
    if (_isLoaded) return;
    _settings = await SubtitleSettings.load();
    _isLoaded = true;
    notifyListeners();
  }

  Future<void> updateSettings(SubtitleSettings newSettings) async {
    _settings = newSettings;
    notifyListeners();
    await _settings.save();
  }

  Future<void> resetToDefaults() async {
    _settings = const SubtitleSettings();
    notifyListeners();
    await _settings.save();
  }
}
