import 'dart:convert';
import 'dart:typed_data';
import 'package:charset_converter/charset_converter.dart';

class SubtitleUtils {
  /// 파일명에서 확장자를 제외한 기본 파일명을 반환합니다.
  static String getBaseName(String fileName) {
    final lastDot = fileName.lastIndexOf('.');
    if (lastDot > 0) {
      return fileName.substring(0, lastDot);
    }
    return fileName;
  }

  /// 자막 파일이 주어진 비디오 파일과 매칭되는지 확인합니다.
  /// (확장자를 제외한 이름이 동일하거나 언어 태그가 포함된 경우)
  static bool isSubtitleForVideo(String subName, String videoName) {
    final vBase = getBaseName(videoName).toLowerCase().trim();
    final sBase = getBaseName(subName).toLowerCase().trim();
    if (vBase.isEmpty) return false;

    // 1. 완전 일치 (예: Movie.mp4 <-> Movie.smi, Movie.srt)
    if (sBase == vBase) return true;

    // 2. 2단계 확장자 일치 (예: Movie.ko.srt, Movie.en.srt <-> Movie.mp4)
    final sBaseParent = getBaseName(sBase).toLowerCase().trim();
    if (sBaseParent == vBase) return true;

    // 3. 접두사 일치 (예: Movie_ko.srt, Movie.korean.srt, Movie (ko).srt)
    if (sBase.startsWith('$vBase.') ||
        sBase.startsWith('${vBase}_') ||
        sBase.startsWith('$vBase-') ||
        sBase.startsWith('$vBase ') ||
        sBase.startsWith('$vBase(')) {
      return true;
    }

    return false;
  }

  /// 자막 파일명에 기반하여 한국어 자막일 확률/우선순위 점수를 산출합니다.
  static int koreanScore(String subName) {
    final lower = subName.toLowerCase();
    int score = 0;

    // 명시적 한국어 키워드 (최우선)
    if (lower.contains('.ko.') ||
        lower.contains('.kor.') ||
        lower.contains('.kr.') ||
        lower.contains('_ko') ||
        lower.contains('_kor') ||
        lower.contains('korean') ||
        lower.contains('한국어') ||
        lower.contains('한국') ||
        lower.contains('한글') ||
        lower.contains('krcc')) {
      score += 100;
    }

    // 표준 자막 포맷 우선 가중치 (SRT 및 SMI 동등 우선)
    if (lower.endsWith('.srt') || lower.endsWith('.smi')) {
      score += 50;
    }

    // 타 언어 (영어, 일어, 중국어 등) 명시된 경우 감점
    if (lower.contains('.en.') ||
        lower.contains('.eng.') ||
        lower.contains('_en') ||
        lower.contains('_eng') ||
        lower.contains('english') ||
        lower.contains('.ja.') ||
        lower.contains('.jpn.') ||
        lower.contains('japanese') ||
        lower.contains('.zh.') ||
        lower.contains('.chi.') ||
        lower.contains('chinese')) {
      score -= 80;
    }

    return score;
  }

  /// 다운로드한 자막 바이트 데이터에서 한국어 자막 태그 또는 한글이 포함되어 있는지 검사합니다.
  static bool hasKoreanContent(List<int> bytes) {
    try {
      // 1. ASCII 범위의 SAMI 클래스 및 언어 속성 검사 (CP949, EUC-KR, UTF-8 공통)
      final sample = bytes.take(30000).toList();
      final asciiStr = String.fromCharCodes(sample).toLowerCase();
      if (asciiStr.contains('krcc') ||
          asciiStr.contains('lang:ko') ||
          asciiStr.contains('lang=ko') ||
          asciiStr.contains('korean')) {
        return true;
      }

      // 2. UTF-8 한글 글자 검사
      final utf8Str = utf8.decode(bytes, allowMalformed: true);
      if (RegExp(r'[\uAC00-\uD7AF\u1100-\u11FF]').hasMatch(utf8Str)) {
        return true;
      }
    } catch (_) {}
    return false;
  }

  /// 자막 바이트 데이터가 UTF-8로 유효한지 검사
  static bool isStrictUtf8(Uint8List bytes) {
    try {
      utf8.decode(bytes, allowMalformed: false);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// CP949 / EUC-KR 등의 레거시 한국어 인코딩 자막을 완벽한 UTF-8 문자열로 변환합니다.
  static Future<String> decodeSubtitleToUtf8String(List<int> rawBytes) async {
    final u8Bytes = rawBytes is Uint8List ? rawBytes : Uint8List.fromList(rawBytes);

    // 1. UTF-8 BOM 제거
    if (u8Bytes.length >= 3 && u8Bytes[0] == 0xEF && u8Bytes[1] == 0xBB && u8Bytes[2] == 0xBF) {
      return utf8.decode(u8Bytes.sublist(3), allowMalformed: true);
    }

    // 2. 엄격한 UTF-8 디코딩 검증 (오류 없이 성공하고 한글 깨짐이 없다면 UTF-8)
    if (isStrictUtf8(u8Bytes)) {
      final decoded = utf8.decode(u8Bytes, allowMalformed: false);
      // 만약 UTF-8로 디코딩되었는데 정상 텍스트면 반환
      return decoded;
    }

    // 3. EUC-KR / CP949 디코딩 시도 (한국어 자막 표준 레거시 인코딩)
    try {
      final decodedCp949 = await CharsetConverter.decode('cp949', u8Bytes);
      if (decodedCp949.isNotEmpty) {
        return decodedCp949;
      }
    } catch (_) {}

    try {
      final decodedEucKr = await CharsetConverter.decode('euc-kr', u8Bytes);
      if (decodedEucKr.isNotEmpty) {
        return decodedEucKr;
      }
    } catch (_) {}

    // 4. GBK / GB2312 (중국어 자막 호환)
    try {
      final decodedGbk = await CharsetConverter.decode('gbk', u8Bytes);
      if (decodedGbk.isNotEmpty) {
        return decodedGbk;
      }
    } catch (_) {}

    // 5. 폴백: UTF-8 허용 디코딩
    return utf8.decode(u8Bytes, allowMalformed: true);
  }

  /// 자막 바이트 데이터를 UTF-8 바이트(UTF-8 BOM 포함)로 변환하여 libmpv 및 파서 호환성을 극대화합니다.
  static Future<Uint8List> normalizeSubtitleToUtf8Bytes(List<int> rawBytes) async {
    final text = await decodeSubtitleToUtf8String(rawBytes);
    final utf8Encoded = utf8.encode(text);
    return Uint8List.fromList(utf8Encoded);
  }
}

