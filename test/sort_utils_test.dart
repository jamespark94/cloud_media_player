import 'package:flutter_test/flutter_test.dart';
import 'package:cloud_media_player/models/media_item.dart';
import 'package:cloud_media_player/utils/sort_utils.dart';

void main() {
  final sampleItems = [
    MediaItem(
      id: 'f1',
      name: 'Episode 10.mkv',
      isFolder: false,
      size: 500,
      modifiedTime: DateTime(2026, 1, 10),
    ),
    MediaItem(
      id: 'd2',
      name: 'Season 2',
      isFolder: true,
      modifiedTime: DateTime(2026, 2, 1),
    ),
    MediaItem(
      id: 'f2',
      name: 'Episode 2.mp4',
      isFolder: false,
      size: 1500,
      modifiedTime: DateTime(2026, 3, 5),
    ),
    MediaItem(
      id: 'f3',
      name: 'Episode 2.srt',
      isFolder: false,
      size: 50,
      modifiedTime: DateTime(2026, 1, 1),
    ),
    MediaItem(
      id: 'd1',
      name: 'Season 1',
      isFolder: true,
      modifiedTime: DateTime(2026, 1, 5),
    ),
    MediaItem(
      id: '__ACTION_ADD_STORAGE__',
      name: '➕ 다른 저장소',
      isFolder: true,
    ),
  ];

  test('folders stay first and natural sort applies by name', () {
    final asc = SortUtils.sortMediaItems(sampleItems, field: SortField.name, ascending: true);
    expect(asc.map((e) => e.id).toList(), ['__ACTION_ADD_STORAGE__', 'd1', 'd2', 'f2', 'f3', 'f1']);

    final desc = SortUtils.sortMediaItems(sampleItems, field: SortField.name, ascending: false);
    expect(desc.map((e) => e.id).toList(), ['__ACTION_ADD_STORAGE__', 'd2', 'd1', 'f1', 'f3', 'f2']);
  });

  test('sort by size', () {
    final asc = SortUtils.sortMediaItems(sampleItems, field: SortField.size, ascending: true);
    expect(asc.skip(3).map((e) => e.id).toList(), ['f3', 'f1', 'f2']);

    final desc = SortUtils.sortMediaItems(sampleItems, field: SortField.size, ascending: false);
    expect(desc.skip(3).map((e) => e.id).toList(), ['f2', 'f1', 'f3']);
  });

  test('sort by modifiedDate', () {
    final desc = SortUtils.sortMediaItems(sampleItems, field: SortField.modifiedDate, ascending: false);
    expect(desc.map((e) => e.id).toList(), ['__ACTION_ADD_STORAGE__', 'd2', 'd1', 'f2', 'f1', 'f3']);
  });

  test('sort by type', () {
    final asc = SortUtils.sortMediaItems(sampleItems, field: SortField.type, ascending: true);
    expect(asc.skip(3).map((e) => e.id).toList(), ['f1', 'f2', 'f3']);
  });
}
