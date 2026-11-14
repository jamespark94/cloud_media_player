import 'package:flutter/material.dart';
import '../models/media_item.dart';

enum SortField {
  name('이름', Icons.sort_by_alpha_rounded),
  size('크기', Icons.data_usage_rounded),
  modifiedDate('변경날짜', Icons.schedule_rounded),
  type('유형', Icons.category_outlined);

  final String label;
  final IconData icon;

  const SortField(this.label, this.icon);

  bool get defaultAscending => this == name || this == type;
}

class NaturalSortUtils {
  static final RegExp _numRegex = RegExp(r'(\d+)');

  static int compare(String a, String b) {
    final aTokens = _tokenize(a.toLowerCase());
    final bTokens = _tokenize(b.toLowerCase());
    final minLength = aTokens.length < bTokens.length ? aTokens.length : bTokens.length;

    for (int i = 0; i < minLength; i++) {
      final aTok = aTokens[i];
      final bTok = bTokens[i];

      if (aTok.isNumber && bTok.isNumber) {
        final aVal = BigInt.tryParse(aTok.text) ?? BigInt.zero;
        final bVal = BigInt.tryParse(bTok.text) ?? BigInt.zero;
        final comp = aVal.compareTo(bVal);
        if (comp != 0) return comp;
        final lenComp = aTok.text.length.compareTo(bTok.text.length);
        if (lenComp != 0) return lenComp;
      } else {
        final comp = aTok.text.compareTo(bTok.text);
        if (comp != 0) return comp;
      }
    }

    return aTokens.length.compareTo(bTokens.length);
  }

  static List<_SortToken> _tokenize(String str) {
    final List<_SortToken> tokens = [];
    int lastEnd = 0;
    for (final match in _numRegex.allMatches(str)) {
      if (match.start > lastEnd) {
        tokens.add(_SortToken(str.substring(lastEnd, match.start), false));
      }
      tokens.add(_SortToken(match.group(0)!, true));
      lastEnd = match.end;
    }
    if (lastEnd < str.length) {
      tokens.add(_SortToken(str.substring(lastEnd), false));
    }
    return tokens;
  }
}

class _SortToken {
  final String text;
  final bool isNumber;
  const _SortToken(this.text, this.isNumber);
}

class SortUtils {
  static String getMediaTypeLabel(MediaItem item) {
    if (item.isFolder) return '폴더';
    final ext = item.name.contains('.') ? item.name.split('.').last.toUpperCase() : '';
    if (item.isVideo) {
      return ext.isNotEmpty ? '동영상 ($ext)' : '동영상';
    }
    if (item.isSubtitle) {
      return ext.isNotEmpty ? '자막 ($ext)' : '자막';
    }
    if (item.isComicArchive) {
      return ext.isNotEmpty ? '만화 ($ext)' : '만화';
    }
    if (item.isImage) {
      return ext.isNotEmpty ? '이미지 ($ext)' : '이미지';
    }
    if (ext.isNotEmpty) {
      return '파일 ($ext)';
    }
    return item.mimeType?.isNotEmpty == true ? item.mimeType! : '파일';
  }

  static List<MediaItem> sortMediaItems(
    Iterable<MediaItem> items, {
    required SortField field,
    required bool ascending,
  }) {
    final list = List<MediaItem>.from(items);
    list.sort((a, b) => compareMediaItems(a, b, field: field, ascending: ascending));
    return list;
  }

  static int compareMediaItems(
    MediaItem a,
    MediaItem b, {
    required SortField field,
    required bool ascending,
  }) {
    // 1. 특수 액션 항목("__ACTION_ADD_STORAGE__")은 항상 최상단 고정
    if (a.id == '__ACTION_ADD_STORAGE__' && b.id != '__ACTION_ADD_STORAGE__') return -1;
    if (b.id == '__ACTION_ADD_STORAGE__' && a.id != '__ACTION_ADD_STORAGE__') return 1;

    // 2. 폴더를 항상 파일보다 앞에 배치
    if (a.isFolder != b.isFolder) {
      return a.isFolder ? -1 : 1;
    }

    int cmp = 0;
    switch (field) {
      case SortField.name:
        cmp = NaturalSortUtils.compare(a.name, b.name);
        return ascending ? cmp : -cmp;

      case SortField.size:
        if (a.size == null && b.size == null) {
          return NaturalSortUtils.compare(a.name, b.name);
        }
        if (a.size == null) return 1;
        if (b.size == null) return -1;
        cmp = a.size!.compareTo(b.size!);
        if (cmp != 0) return ascending ? cmp : -cmp;
        return NaturalSortUtils.compare(a.name, b.name);

      case SortField.modifiedDate:
        if (a.modifiedTime == null && b.modifiedTime == null) {
          return NaturalSortUtils.compare(a.name, b.name);
        }
        if (a.modifiedTime == null) return 1;
        if (b.modifiedTime == null) return -1;
        cmp = a.modifiedTime!.compareTo(b.modifiedTime!);
        if (cmp != 0) return ascending ? cmp : -cmp;
        return NaturalSortUtils.compare(a.name, b.name);

      case SortField.type:
        cmp = getMediaTypeLabel(a).toLowerCase().compareTo(getMediaTypeLabel(b).toLowerCase());
        if (cmp != 0) return ascending ? cmp : -cmp;
        return NaturalSortUtils.compare(a.name, b.name);
    }
  }
}
