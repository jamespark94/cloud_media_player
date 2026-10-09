class MediaItem {
  final String id;
  final String name;
  final String? parentId;
  final bool isFolder;
  final int? size;
  final String? mimeType;
  final String? thumbnailUrl;
  final String? directStreamUrl;
  final DateTime? modifiedTime;
  final Duration? duration;

  MediaItem({
    required this.id,
    required this.name,
    this.parentId,
    required this.isFolder,
    this.size,
    this.mimeType,
    this.thumbnailUrl,
    this.directStreamUrl,
    this.modifiedTime,
    this.duration,
  });

  bool get isVideo {
    if (isFolder) return false;
    final lowerName = name.toLowerCase();
    final videoExtensions = [
      '.mp4',
      '.mkv',
      '.avi',
      '.mov',
      '.wmv',
      '.flv',
      '.webm',
      '.m4v',
      '.ts',
      '.tp',
      '.m2ts',
      '.mts',
      '.3gp',
      '.asf',
      '.vob',
      '.mpg',
      '.mpeg',
      '.m2v',
      '.ogv',
      '.divx',
      '.rm',
      '.rmvb',
      '.f4v',
    ];
    if (videoExtensions.any((ext) => lowerName.endsWith(ext))) return true;
    if (mimeType != null && mimeType!.startsWith('video/')) return true;
    return false;
  }

  bool get isSubtitle {
    final lowerName = name.toLowerCase();
    return lowerName.endsWith('.srt') ||
        lowerName.endsWith('.smi') ||
        lowerName.endsWith('.ass') ||
        lowerName.endsWith('.ssa') ||
        lowerName.endsWith('.sub') ||
        lowerName.endsWith('.vtt');
  }

  String get formattedSize {
    if (size == null || size == 0) return '';
    const suffixes = ['B', 'KB', 'MB', 'GB', 'TB'];
    var i = 0;
    double dSize = size!.toDouble();
    while (dSize >= 1024 && i < suffixes.length - 1) {
      dSize /= 1024;
      i++;
    }
    return '${dSize.toStringAsFixed(1)} ${suffixes[i]}';
  }

  String get formattedDuration {
    if (duration == null || duration == Duration.zero) return '';
    final hours = duration!.inHours;
    final minutes = duration!.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration!.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (hours > 0) {
      return '$hours:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }
}
