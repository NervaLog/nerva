# Flutter Mobile Auth Integration

This guide explains how to integrate Nerva authentication in a Flutter mobile app.

## Overview

Nerva supports two authentication methods:
1. **Magic Link** - Email-based passwordless login
2. **Google OAuth** - Sign in with Google

Both methods return a JWT token that should be stored securely and sent with API requests.

## API Endpoints

Base URL: `https://your-api-domain.com`

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/v1/auth/magic-link/send` | POST | Send magic link email |
| `/api/v1/auth/magic-link/verify` | POST | Verify magic link token |
| `/api/v1/auth/oauth/start` | POST | Start OAuth flow |
| `/api/v1/auth/oauth/verify` | POST | Verify OAuth callback |

## Magic Link Flow

### 1. Send Magic Link

```dart
Future<void> sendMagicLink(String email) async {
  final response = await http.post(
    Uri.parse('$baseUrl/api/v1/auth/magic-link/send'),
    headers: {'Content-Type': 'application/json'},
    body: jsonEncode({
      'email': email,
      'deep_link_url': 'nerva://auth/callback',  // Your app's deep link
    }),
  );

  if (response.statusCode == 200) {
    // Show "check your email" message
  } else {
    final error = jsonDecode(response.body);
    throw AuthException(error['message']);
  }
}
```

### 2. Handle Deep Link

Configure your app to handle the `nerva://` scheme.

**Android** (`android/app/src/main/AndroidManifest.xml`):
```xml
<intent-filter>
  <action android:name="android.intent.action.VIEW" />
  <category android:name="android.intent.category.DEFAULT" />
  <category android:name="android.intent.category.BROWSABLE" />
  <data android:scheme="nerva" android:host="auth" />
</intent-filter>
```

**iOS** (`ios/Runner/Info.plist`):
```xml
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleURLSchemes</key>
    <array>
      <string>nerva</string>
    </array>
  </dict>
</array>
```

### 3. Parse Deep Link and Verify Token

```dart
import 'package:uni_links/uni_links.dart';

class AuthService {
  StreamSubscription? _linkSubscription;

  void initDeepLinkListener() {
    _linkSubscription = linkStream.listen((String? link) {
      if (link != null && link.startsWith('nerva://auth/callback')) {
        _handleAuthCallback(Uri.parse(link));
      }
    });
  }

  Future<AuthResult> _handleAuthCallback(Uri uri) async {
    // Extract tokens from query parameters
    final discoveryToken = uri.queryParameters['discovery_request_token'];
    final stytchToken = uri.queryParameters['token'];
    final tokenType = uri.queryParameters['stytch_token_type'];

    if (discoveryToken == null || stytchToken == null || tokenType == null) {
      throw AuthException('Missing auth parameters');
    }

    return verifyToken(
      discoveryToken: discoveryToken,
      stytchToken: stytchToken,
      tokenType: tokenType,
    );
  }

  Future<AuthResult> verifyToken({
    required String discoveryToken,
    required String stytchToken,
    required String tokenType,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/api/v1/auth/magic-link/verify'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'discovery_token': discoveryToken,
        'stytch_token': stytchToken,
        'stytch_token_type': tokenType,
      }),
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return AuthResult(
        token: data['token'],
        user: User.fromJson(data['user']),
      );
    } else {
      final error = jsonDecode(response.body);
      throw AuthException(error['message']);
    }
  }

  void dispose() {
    _linkSubscription?.cancel();
  }
}
```

## Google OAuth Flow

### 1. Start OAuth Flow

```dart
Future<OAuthStartResult> startGoogleOAuth() async {
  final response = await http.post(
    Uri.parse('$baseUrl/api/v1/auth/oauth/start'),
    headers: {'Content-Type': 'application/json'},
    body: jsonEncode({
      'provider': 'google',
      'redirect_url': 'nerva://auth/callback',
    }),
  );

  if (response.statusCode == 200) {
    final data = jsonDecode(response.body);
    return OAuthStartResult(
      oauthUrl: data['oauth_url'],
      discoveryToken: data['discovery_token'],
    );
  } else {
    throw AuthException('Failed to start OAuth');
  }
}
```

### 2. Open OAuth URL in Browser

```dart
import 'package:url_launcher/url_launcher.dart';

Future<void> launchGoogleSignIn() async {
  final result = await startGoogleOAuth();

  // Store discovery token for later verification
  await _secureStorage.write(key: 'discovery_token', value: result.discoveryToken);

  // Open OAuth URL in browser
  await launchUrl(
    Uri.parse(result.oauthUrl),
    mode: LaunchMode.externalApplication,
  );
}
```

### 3. Handle OAuth Callback

The OAuth flow redirects back to your app with the same deep link format. Handle it the same way as magic links, but use the `/oauth/verify` endpoint:

```dart
Future<AuthResult> _handleOAuthCallback(Uri uri) async {
  final stytchToken = uri.queryParameters['token'];
  final tokenType = uri.queryParameters['stytch_token_type'];

  // Retrieve stored discovery token
  final discoveryToken = await _secureStorage.read(key: 'discovery_token');

  if (discoveryToken == null || stytchToken == null || tokenType == null) {
    throw AuthException('Missing auth parameters');
  }

  final response = await http.post(
    Uri.parse('$baseUrl/api/v1/auth/oauth/verify'),
    headers: {'Content-Type': 'application/json'},
    body: jsonEncode({
      'discovery_token': discoveryToken,
      'stytch_token': stytchToken,
      'stytch_token_type': tokenType,
    }),
  );

  // Clean up stored token
  await _secureStorage.delete(key: 'discovery_token');

  if (response.statusCode == 200) {
    final data = jsonDecode(response.body);
    return AuthResult(
      token: data['token'],
      user: User.fromJson(data['user']),
    );
  } else {
    throw AuthException('OAuth verification failed');
  }
}
```

## Storing and Using the JWT Token

### Secure Storage

Use `flutter_secure_storage` to store the JWT:

```dart
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class TokenStorage {
  final _storage = const FlutterSecureStorage();
  static const _tokenKey = 'auth_token';

  Future<void> saveToken(String token) async {
    await _storage.write(key: _tokenKey, value: token);
  }

  Future<String?> getToken() async {
    return await _storage.read(key: _tokenKey);
  }

  Future<void> deleteToken() async {
    await _storage.delete(key: _tokenKey);
  }
}
```

### Making Authenticated Requests

Include the JWT in the `Authorization` header:

```dart
class ApiClient {
  final TokenStorage _tokenStorage;

  ApiClient(this._tokenStorage);

  Future<http.Response> get(String path) async {
    final token = await _tokenStorage.getToken();

    return http.get(
      Uri.parse('$baseUrl$path'),
      headers: {
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      },
    );
  }

  Future<http.Response> post(String path, Map<String, dynamic> body) async {
    final token = await _tokenStorage.getToken();

    return http.post(
      Uri.parse('$baseUrl$path'),
      headers: {
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      },
      body: jsonEncode(body),
    );
  }
}
```

## Data Models

```dart
class AuthResult {
  final String token;
  final User user;

  AuthResult({required this.token, required this.user});
}

class User {
  final String id;
  final String email;
  final String orgId;
  final String orgName;
  final String orgSlug;
  final String role;

  User({
    required this.id,
    required this.email,
    required this.orgId,
    required this.orgName,
    required this.orgSlug,
    required this.role,
  });

  factory User.fromJson(Map<String, dynamic> json) {
    return User(
      id: json['id'],
      email: json['email'],
      orgId: json['org_id'],
      orgName: json['org_name'],
      orgSlug: json['org_slug'],
      role: json['role'],
    );
  }
}

class OAuthStartResult {
  final String oauthUrl;
  final String discoveryToken;

  OAuthStartResult({required this.oauthUrl, required this.discoveryToken});
}

class AuthException implements Exception {
  final String message;
  AuthException(this.message);

  @override
  String toString() => 'AuthException: $message';
}
```

## Required Flutter Packages

Add to `pubspec.yaml`:

```yaml
dependencies:
  http: ^1.1.0
  uni_links: ^0.5.1
  url_launcher: ^6.2.1
  flutter_secure_storage: ^9.0.0
```

## Token Types Reference

When verifying tokens, the `stytch_token_type` will be one of:
- `discovery` - Magic link authentication
- `discovery_oauth` - OAuth authentication

## Error Handling

All error responses follow this format:

```json
{
  "error": "error_code",
  "message": "Human readable message"
}
```

Common error codes:
- `invalid_request` - Malformed request body
- `invalid_email` - Invalid email address format
- `send_failed` - Failed to send magic link
- `invalid_provider` - Unknown OAuth provider
- `verification_failed` - Token verification failed
- `invalid_token_type` - Unknown token type

## Complete Example: Auth Provider

```dart
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class AuthProvider extends ChangeNotifier {
  final _storage = const FlutterSecureStorage();
  final _baseUrl = 'https://your-api-domain.com';

  User? _user;
  bool _isLoading = false;

  User? get user => _user;
  bool get isAuthenticated => _user != null;
  bool get isLoading => _isLoading;

  Future<void> init() async {
    final token = await _storage.read(key: 'auth_token');
    if (token != null) {
      // TODO: Validate token and fetch user info
      // For now, decode JWT claims locally
      _user = _decodeUserFromToken(token);
      notifyListeners();
    }
  }

  Future<void> sendMagicLink(String email) async {
    _isLoading = true;
    notifyListeners();

    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/api/v1/auth/magic-link/send'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'email': email,
          'deep_link_url': 'nerva://auth/callback',
        }),
      );

      if (response.statusCode != 200) {
        throw AuthException(jsonDecode(response.body)['message']);
      }
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> handleAuthCallback(Uri uri) async {
    _isLoading = true;
    notifyListeners();

    try {
      final discoveryToken = uri.queryParameters['discovery_request_token'];
      final stytchToken = uri.queryParameters['token'];
      final tokenType = uri.queryParameters['stytch_token_type'];

      final endpoint = tokenType == 'discovery_oauth'
          ? '/api/v1/auth/oauth/verify'
          : '/api/v1/auth/magic-link/verify';

      final response = await http.post(
        Uri.parse('$_baseUrl$endpoint'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'discovery_token': discoveryToken,
          'stytch_token': stytchToken,
          'stytch_token_type': tokenType,
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        await _storage.write(key: 'auth_token', value: data['token']);
        _user = User.fromJson(data['user']);
        notifyListeners();
      } else {
        throw AuthException(jsonDecode(response.body)['message']);
      }
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> logout() async {
    await _storage.delete(key: 'auth_token');
    _user = null;
    notifyListeners();
  }
}
```

## Security Considerations

1. **Always use HTTPS** in production
2. **Store tokens securely** using `flutter_secure_storage`
3. **Handle token expiration** - JWTs expire after 7 days
4. **Clear tokens on logout** and app uninstall
5. **Validate deep links** - ensure they're from expected sources
