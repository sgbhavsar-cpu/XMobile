// Keeps HttpApiClient's bearer token and device id alive across app restarts. Backed by
// flutter_secure_storage (Keystore on Android, Keychain on iOS) — the same package docs/07 §2
// names for auth material. Injected into HttpApiClient's constructor exactly the way its
// http.Client already is, so tests can supply an in-memory fake instead of exercising a real
// platform keystore (which `flutter test` can't do headless).

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

abstract class TokenStore {
  Future<String?> readToken();

  Future<void> writeToken(String? token);

  /// Stable across calls and across app restarts — generated once on first read, then reused.
  Future<String> deviceId();
}

class SecureTokenStore implements TokenStore {
  SecureTokenStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const _tokenKey = 'xmobile.access_token';
  static const _deviceIdKey = 'xmobile.device_id';

  @override
  Future<String?> readToken() => _storage.read(key: _tokenKey);

  @override
  Future<void> writeToken(String? token) => token == null
      ? _storage.delete(key: _tokenKey)
      : _storage.write(key: _tokenKey, value: token);

  @override
  Future<String> deviceId() async {
    final existing = await _storage.read(key: _deviceIdKey);
    if (existing != null) return existing;

    final generated = const Uuid().v4();
    await _storage.write(key: _deviceIdKey, value: generated);
    return generated;
  }
}

/// Test double — same contract, no platform channel. `flows_test.dart`/`http_api_client_test.dart`
/// use this instead of `SecureTokenStore` for the same reason `MockClient` stands in for a real
/// `http.Client`.
class InMemoryTokenStore implements TokenStore {
  InMemoryTokenStore({String? initialDeviceId}) : _deviceId = initialDeviceId;

  String? _token;
  String? _deviceId;

  @override
  Future<String?> readToken() async => _token;

  @override
  Future<void> writeToken(String? token) async => _token = token;

  @override
  Future<String> deviceId() async => _deviceId ??= const Uuid().v4();
}
