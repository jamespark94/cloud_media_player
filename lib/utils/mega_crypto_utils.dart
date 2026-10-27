import 'dart:convert';
import 'dart:typed_data';
import 'package:pointycastle/export.dart';

/// 복호화된 파일 노드 키 구조체 (16바이트 AES 키 + 8바이트 IV/Nonce)
class MegaFileKey {
  final Uint8List aesKey; // 16 bytes (128-bit)
  final Uint8List iv; // 8 bytes (64-bit nonce for CTR)
  final Uint8List metaMac; // 8 bytes

  const MegaFileKey({
    required this.aesKey,
    required this.iv,
    required this.metaMac,
  });
}

class MegaCryptoUtils {
  MegaCryptoUtils._();

  // ===========================================================================
  // 1. Base64URL 인코딩 / 디코딩 (패딩 '=' 생략 규격 대응)
  // ===========================================================================

  /// MEGA API에서 사용하는 URL-safe Base64 문자열을 Uint8List로 디코딩
  static Uint8List base64UrlDecode(String input) {
    String normalized = input.replaceAll('-', '+').replaceAll('_', '/');
    final remainder = normalized.length % 4;
    if (remainder == 2) {
      normalized += '==';
    } else if (remainder == 3) {
      normalized += '=';
    } else if (remainder == 1) {
      normalized += '===';
    }
    return Uint8List.fromList(base64.decode(normalized));
  }

  /// Uint8List를 패딩 없는 MEGA 규격 Base64URL 문자열로 인코딩
  static String base64UrlEncode(Uint8List bytes) {
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  // ===========================================================================
  // 2. 비밀번호 키 파생 (Password Key Derivation & User Hash)
  // ===========================================================================

  /// MEGA v1 계정용 비밀번호 키 유도 (prepare_key_pw)
  static Uint8List derivePasswordKeyV1(String password) {
    final pwBytes = utf8.encode(password);
    // int32 리스트로 패딩
    final int keyLen = ((pwBytes.length + 3) >> 2);
    final keyInts = Uint32List(keyLen > 4 ? keyLen : 4);
    for (int i = 0; i < pwBytes.length; i++) {
      final shift = 24 - 8 * (i & 3);
      keyInts[i >> 2] |= (pwBytes[i] & 0xFF) << shift;
    }

    final keyBytes = Uint8List(keyInts.length * 4);
    final bdKey = ByteData.sublistView(keyBytes);
    for (int i = 0; i < keyInts.length; i++) {
      bdKey.setUint32(i * 4, keyInts[i], Endian.big);
    }

    final initialKey = Uint32List.fromList([0x93C467E3, 0x7DB0C7A4, 0xD1BE3F81, 0x0152CB56]);
    final defaultKeyBytes = Uint8List(16);
    final bdDef = ByteData.sublistView(defaultKeyBytes);
    for (int i = 0; i < 4; i++) {
      bdDef.setUint32(i * 4, initialKey[i], Endian.big);
    }

    var resultKey = Uint8List.fromList(defaultKeyBytes);
    final cipher = ECBBlockCipher(AESEngine());

    // 65536 rounds
    for (int r = 0; r < 65536; r++) {
      for (int i = 0; i < keyBytes.length; i += 16) {
        Uint8List chunk;
        if (i + 16 <= keyBytes.length) {
          chunk = keyBytes.sublist(i, i + 16);
        } else {
          chunk = Uint8List(16);
          chunk.setRange(0, keyBytes.length - i, keyBytes.sublist(i));
        }
        cipher.init(true, KeyParameter(chunk));
        resultKey = cipher.process(resultKey);
      }
    }
    return resultKey;
  }

  /// MEGA v1 사용자 해시 (userHash) 계산
  static String calculateUserHashV1(String email, Uint8List passwordKey) {
    final emailLower = utf8.encode(email.trim().toLowerCase());
    final emailBuf = Uint8List(16);
    for (int i = 0; i < emailLower.length; i++) {
      emailBuf[i % 16] ^= emailLower[i];
    }

    var block = Uint8List.fromList(emailBuf);
    final cipher = ECBBlockCipher(AESEngine());
    cipher.init(true, KeyParameter(passwordKey));

    for (int i = 0; i < 16384; i++) {
      block = cipher.process(block);
    }

    // 0..4와 8..12 (총 8바이트)
    final hashBytes = Uint8List(8);
    hashBytes.setRange(0, 4, block.sublist(0, 4));
    hashBytes.setRange(4, 8, block.sublist(8, 12));
    return base64UrlEncode(hashBytes);
  }

  /// MEGA v2 계정용 PBKDF2-HMAC-SHA512 키 유도 (100,000 iterations, 32 bytes 출력)
  static ({Uint8List derivedKey, String userHash}) derivePasswordKeyV2(
    String password,
    String base64Salt,
  ) {
    final salt = base64UrlDecode(base64Salt);
    final pwBytes = Uint8List.fromList(utf8.encode(password));

    final pbkdf2 = PBKDF2KeyDerivator(HMac(SHA512Digest(), 128));
    pbkdf2.init(Pbkdf2Parameters(salt, 100000, 32));
    final output = pbkdf2.process(pwBytes);

    final derivedKey = Uint8List.fromList(output.sublist(0, 16));
    final userHash = base64UrlEncode(Uint8List.fromList(output.sublist(16, 32)));

    return (derivedKey: derivedKey, userHash: userHash);
  }

  // ===========================================================================
  // 3. 마스터 키 및 노드 키 복호화 (AES-128-ECB)
  // ===========================================================================

  /// 단일/다중 16바이트 블록을 AES-128-ECB로 복호화
  static Uint8List decryptAes128Ecb(Uint8List cipherBytes, Uint8List key16) {
    if (cipherBytes.isEmpty) return Uint8List(0);
    final cipher = ECBBlockCipher(AESEngine());
    cipher.init(false, KeyParameter(key16));

    final out = Uint8List(cipherBytes.length);
    for (int i = 0; i < cipherBytes.length; i += 16) {
      cipher.processBlock(cipherBytes, i, out, i);
    }
    return out;
  }

  /// 단일/다중 16바이트 블록을 AES-128-ECB로 암호화
  static Uint8List encryptAes128Ecb(Uint8List plainBytes, Uint8List key16) {
    if (plainBytes.isEmpty) return Uint8List(0);
    final cipher = ECBBlockCipher(AESEngine());
    cipher.init(true, KeyParameter(key16));

    final out = Uint8List(plainBytes.length);
    for (int i = 0; i < plainBytes.length; i += 16) {
      cipher.processBlock(plainBytes, i, out, i);
    }
    return out;
  }

  /// 암호화된 마스터 키(`k`)를 파생된 비밀번호 키(`derivedKey`)로 복호화
  static Uint8List decryptMasterKey(String encryptedMasterKeyBase64, Uint8List derivedKey) {
    return decryptAes128Ecb(base64UrlDecode(encryptedMasterKeyBase64), derivedKey);
  }

  /// 노드의 암호화된 키(`encryptedKeyBase64`)를 마스터 키로 복호화
  static MegaFileKey decryptAndUnpackNodeKey(
    String encryptedKeyBase64,
    Uint8List masterKey, {
    required bool isFolder,
  }) {
    final rawKey = decryptAes128Ecb(base64UrlDecode(encryptedKeyBase64), masterKey);

    if (isFolder || rawKey.length == 16) {
      return MegaFileKey(
        aesKey: rawKey.sublist(0, 16),
        iv: Uint8List(8),
        metaMac: Uint8List(8),
      );
    }

    if (rawKey.length >= 32) {
      final aesKey = Uint8List(16);
      for (int i = 0; i < 16; i++) {
        aesKey[i] = rawKey[i] ^ rawKey[i + 16];
      }
      final iv = Uint8List.fromList(rawKey.sublist(16, 24));
      final metaMac = Uint8List.fromList(rawKey.sublist(24, 32));
      return MegaFileKey(aesKey: aesKey, iv: iv, metaMac: metaMac);
    }

    return MegaFileKey(
      aesKey: rawKey,
      iv: Uint8List(8),
      metaMac: Uint8List(8),
    );
  }

  // ===========================================================================
  // 4. 파일/폴더 메타데이터(`a`) 복호화 (AES-128-CBC, Zero IV)
  // ===========================================================================

  /// 암호화된 속성(`a` 필드)을 복호화하여 JSON Map 반환 (예: `{"n": "만화책 01권.zip"}`)
  static Map<String, dynamic>? decryptNodeAttributes(
    String encryptedAttributesBase64,
    Uint8List nodeAesKey16,
  ) {
    try {
      final cipherBytes = base64UrlDecode(encryptedAttributesBase64);
      if (cipherBytes.isEmpty || cipherBytes.length % 16 != 0) return null;

      final cipher = CBCBlockCipher(AESEngine());
      cipher.init(false, ParametersWithIV(KeyParameter(nodeAesKey16), Uint8List(16)));

      final plainBytes = Uint8List(cipherBytes.length);
      for (int i = 0; i < cipherBytes.length; i += 16) {
        cipher.processBlock(cipherBytes, i, plainBytes, i);
      }

      // MEGA attributes are JSON formatted after decrypted.
      // Usually prefixed with 'MEGA{' and padded with 0x00 null bytes.
      final text = utf8.decode(plainBytes, allowMalformed: true);
      final startIdx = text.indexOf('{');
      final endIdx = text.lastIndexOf('}');
      if (startIdx != -1 && endIdx > startIdx) {
        final jsonStr = text.substring(startIdx, endIdx + 1);
        final decoded = jsonDecode(jsonStr);
        if (decoded is Map<String, dynamic>) {
          return decoded;
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  // ===========================================================================
  // 5. 파일 바이너리 복호화 (AES-128-CTR)
  // ===========================================================================

  /// 다운로드한 암호화 파일 바이너리를 해당 파일의 고유 AES 키(16B)와 IV/Nonce(8B)로 복호화
  static Uint8List decryptFileBytesCtr({
    required Uint8List encryptedBytes,
    required Uint8List fileAesKey16,
    required Uint8List fileIv8,
    int initialBlockOffset = 0,
  }) {
    if (encryptedBytes.isEmpty) return Uint8List(0);

    // 16바이트 initialCounter 생성:
    // counter[0..7] = fileIv8[0..7]
    // counter[8..15] = initialBlockOffset (64-bit Big-Endian)
    final counter = Uint8List(16);
    counter.setRange(0, 8, fileIv8);
    final bd = ByteData.sublistView(counter);
    bd.setUint64(8, initialBlockOffset, Endian.big);

    final cipher = CTRStreamCipher(AESEngine());
    cipher.init(false, ParametersWithIV(KeyParameter(fileAesKey16), counter));

    return cipher.process(encryptedBytes);
  }

  // ===========================================================================
  // 6. RSA 개인키 복호화 및 세션 ID(`csid` -> `sid`) 추출
  // ===========================================================================

  /// MPI(Multi-Precision Integer) 바이트에서 BigInt 파싱
  static ({BigInt value, int nextOffset}) _readMpi(Uint8List data, int offset) {
    if (offset + 2 > data.length) {
      throw const FormatException('Invalid MPI length header');
    }
    final bitLen = (data[offset] << 8) | data[offset + 1];
    final byteLen = (bitLen + 7) >> 3;
    final start = offset + 2;
    final end = start + byteLen;
    if (end > data.length) {
      throw const FormatException('MPI payload exceeds buffer');
    }

    final bytes = data.sublist(start, end);
    BigInt val = BigInt.zero;
    for (final b in bytes) {
      val = (val << 8) | BigInt.from(b);
    }
    return (value: val, nextOffset: end);
  }

  /// BigInt 값을 바이트 배열로 변환
  static Uint8List _bigIntToBytes(BigInt number) {
    var hex = number.toRadixString(16);
    if (hex.length % 2 != 0) {
      hex = '0$hex';
    }
    final result = Uint8List(hex.length ~/ 2);
    for (int i = 0; i < result.length; i++) {
      result[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return result;
  }

  /// RSA 복호화 및 43자 세션 ID(`sid`) 추출
  static String decryptSessionId({
    required String encryptedPrivKeyBase64,
    required String encryptedCsidBase64,
    required Uint8List masterKey,
  }) {
    // 1. 개인키 복호화 (AES-128-ECB)
    final privkRaw = base64UrlDecode(encryptedPrivKeyBase64);
    final privkBytes = decryptAes128Ecb(privkRaw, masterKey);

    // 2. MPI 파싱 (p, q, d, u)
    int offset = 0;
    final pRes = _readMpi(privkBytes, offset);
    final p = pRes.value;
    offset = pRes.nextOffset;

    final qRes = _readMpi(privkBytes, offset);
    final q = qRes.value;
    offset = qRes.nextOffset;

    final dRes = _readMpi(privkBytes, offset);
    final d = dRes.value;
    offset = dRes.nextOffset;

    final uRes = _readMpi(privkBytes, offset);
    final u = uRes.value;

    // 3. csid MPI 파싱
    final csidRaw = base64UrlDecode(encryptedCsidBase64);
    final csidMpi = _readMpi(csidRaw, 0);
    final c = csidMpi.value;

    // 4. RSA CRT 복호화:
    // m1 = c ^ (d mod (p-1)) mod p
    // m2 = c ^ (d mod (q-1)) mod q
    // h = (u * (m1 - m2)) mod p
    // m = m2 + h * q
    final dp = d % (p - BigInt.one);
    final dq = d % (q - BigInt.one);
    final m1 = c.modPow(dp, p);
    final m2 = c.modPow(dq, q);

    // MEGA privk의 u = p^-1 mod q 이므로: m = m1 + ((m2 - m1) * u mod q) * p
    final diff = (m2 - m1) % q; // Dart의 %는 항상 0 이상
    final h = (u * diff) % q;
    final m = m1 + h * p;

    final mBytes = _bigIntToBytes(m);

    // 세션 ID는 평문 mBytes의 상위 43바이트
    final sidBytes = mBytes.length >= 43 ? mBytes.sublist(0, 43) : mBytes;
    return base64UrlEncode(sidBytes);
  }
}
