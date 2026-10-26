class VideoQuality {
  final String id;
  final String label;
  final int? height;
  final bool isOriginal;

  const VideoQuality({
    required this.id,
    required this.label,
    this.height,
    this.isOriginal = false,
  });

  static const VideoQuality autoQuality = VideoQuality(
    id: 'auto',
    label: '자동',
  );

  static const VideoQuality q360p = VideoQuality(
    id: '360p',
    label: '360p (절약/빠름)',
    height: 360,
  );

  static const VideoQuality q480p = VideoQuality(
    id: '480p',
    label: '480p (일반)',
    height: 480,
  );

  static const VideoQuality q720p = VideoQuality(
    id: '720p',
    label: '720p (고화질)',
    height: 720,
  );

  static const VideoQuality q1080p = VideoQuality(
    id: '1080p',
    label: '1080p (FHD)',
    height: 1080,
  );

  static const VideoQuality original = VideoQuality(
    id: 'original',
    label: '원본 (Direct)',
    isOriginal: true,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VideoQuality &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;
}
