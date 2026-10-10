import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../models/models.dart';
import 'paths.dart';

/// An error answer from the server, or a failure to reach it.
class ApiException implements Exception {
  const ApiException(this.message, {this.statusCode});

  final String message;

  /// HTTP status, or null when the server could not be reached.
  final int? statusCode;

  bool get isUnauthorized => statusCode == 401;
  bool get isConflict => statusCode == 409;

  @override
  String toString() => message;

  static ApiException from(Object error) {
    if (error is ApiException) return error;
    if (error is DioException) {
      final status = error.response?.statusCode;
      if (status == null) {
        return ApiException(
            'Cannot reach the server (${error.message ?? error.type.name})');
      }
      return ApiException(_describe(status), statusCode: status);
    }
    return ApiException(error.toString());
  }

  static String _describe(int status) => switch (status) {
        400 => 'The server rejected the request',
        401 => 'Not signed in or the session expired',
        403 => 'You do not have permission to do that',
        404 => 'Not found',
        409 => 'An item with that name already exists',
        413 => 'The upload is larger than announced',
        423 => 'The file is busy, try again',
        429 => 'Too many attempts, try again later',
        _ => 'Server error ($status)',
      };
}

/// Credentials for a reverse proxy that uses HTTP basic auth in front of
/// File Browser. They are sent with every request to the server's origin.
class BasicAuth {
  const BasicAuth(this.username, this.password);

  final String username;
  final String password;

  String get header =>
      'Basic ${base64.encode(utf8.encode('$username:$password'))}';
}

/// Called after a 401 to get a fresh token (for example by logging in again
/// with a remembered password). Returns null when that is not possible.
typedef Reauthenticate = Future<String?> Function();

/// Client for File Browser's REST API (the same endpoints its web UI uses).
///
/// Every request carries the JWT in the `X-Auth` header. When the server sets
/// `X-Renew-Token: true` the client fetches a fresh token from `/api/renew`
/// and reports it through [onTokenRenewed]. A 401 triggers [reauthenticate]
/// once and the request is retried with the new token.
class FileBrowserApi {
  FileBrowserApi({
    required String baseUrl,
    this.basicAuth,
    this.onTokenRenewed,
    this.reauthenticate,
    Dio? dio,
  })  : baseUrl = normalizeBaseUrl(baseUrl),
        _dio = dio ?? Dio() {
    _dio.options
      ..connectTimeout = const Duration(seconds: 15)
      ..receiveTimeout = const Duration(minutes: 5);
    _dio.interceptors.add(_AuthInterceptor(this));
  }

  /// Server address without a trailing slash, e.g. `https://host/files`.
  final String baseUrl;
  final BasicAuth? basicAuth;
  final void Function(String token)? onTokenRenewed;
  final Reauthenticate? reauthenticate;
  final Dio _dio;

  /// The current JWT; null before login.
  String? token;

  Future<String>? _renewing;
  DateTime? _renewedAt;
  Future<String?>? _reauthenticating;

  Dio get dio => _dio;

  /// Turns user input like `files.example.com/` into `https://files.example.com`.
  static String normalizeBaseUrl(String input) {
    var url = input.trim();
    if (!url.contains('://')) url = 'https://$url';
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }

  String _api(String endpoint, [String path = '']) =>
      '$baseUrl/api/$endpoint${path.isEmpty ? '' : encodePath(normalizePath(path))}';

  /// Headers for clients that fetch URLs themselves (thumbnails, images).
  Map<String, String> get authHeaders => {
        if (token != null) 'X-Auth': token!,
        if (basicAuth != null) 'Authorization': basicAuth!.header,
      };

  Future<T> _call<T>(Future<T> Function() request) async {
    try {
      return await request();
    } catch (e) {
      throw ApiException.from(e);
    }
  }

  // ---------------------------------------------------------------------------
  // Authentication
  // ---------------------------------------------------------------------------

  /// Logs in and stores the returned JWT in [token].
  Future<String> login(String username, String password) => _call(() async {
        final res = await _dio.post<String>(
          '$baseUrl/api/login',
          data: jsonEncode(
              {'username': username, 'password': password, 'recaptcha': ''}),
          options: Options(
            responseType: ResponseType.plain,
            contentType: 'application/json',
            extra: {_kNoAuth: true},
          ),
        );
        return token = _checkToken(res.data);
      });

  /// Exchanges the current token for a fresh one.
  Future<String> renew() {
    return _renewing ??= _call(() async {
      final res = await _dio.post<String>(
        '$baseUrl/api/renew',
        options: Options(
          responseType: ResponseType.plain,
          extra: {_kNoRenew: true},
        ),
      );
      final fresh = _checkToken(res.data);
      token = fresh;
      onTokenRenewed?.call(fresh);
      return fresh;
    }).whenComplete(() => _renewing = null);
  }

  String _checkToken(String? body) {
    final t = body?.trim() ?? '';
    if ('.'.allMatches(t).length != 2) {
      throw const ApiException('The server did not return a session token. '
          'Is this a File Browser address?');
    }
    return t;
  }

  // ---------------------------------------------------------------------------
  // Files and folders
  // ---------------------------------------------------------------------------

  /// Lists a directory, or fetches one file (with `content` for text files).
  Future<Resource> fetch(String path) => _call(() async {
        final res =
            await _dio.get<Map<String, dynamic>>(_api('resources', path));
        return Resource.fromJson(res.data!);
      });

  Future<void> createFolder(String path) => _call(() async {
        await _dio.post<void>('${_api('resources', path)}/',
            queryParameters: {'override': 'false'});
      });

  /// Creates a file with [content] in one request. Use [TusUploader] for
  /// anything but small files.
  Future<void> createFile(String path,
          {List<int> content = const [], bool override = false}) =>
      _call(() async {
        await _dio.post<void>(
          _api('resources', path),
          queryParameters: {'override': '$override'},
          data: Uint8List.fromList(content),
          options: Options(
              headers: {Headers.contentTypeHeader: 'application/octet-stream'}),
        );
      });

  /// Replaces the text of an existing file.
  Future<void> saveText(String path, String text) => _call(() async {
        final bytes = utf8.encode(text);
        await _dio.put<void>(
          _api('resources', path),
          data: bytes,
          options: Options(headers: {
            Headers.contentTypeHeader: 'text/plain; charset=utf-8'
          }),
        );
      });

  Future<void> delete(String path) => _call(() async {
        await _dio.delete<void>(_api('resources', path));
      });

  /// Moves or renames [from] to [to].
  Future<void> move(String from, String to, {bool override = false}) =>
      _patch('rename', from, to, override: override);

  Future<void> copy(String from, String to, {bool override = false}) =>
      _patch('copy', from, to, override: override);

  Future<void> _patch(String action, String from, String to,
          {required bool override}) =>
      _call(() async {
        // The server unescapes `destination` once more after the query string
        // is decoded, so it is encoded twice here. Otherwise names with `%` or
        // `+` would arrive changed.
        await _dio.patch<void>(_api('resources', from), queryParameters: {
          'action': action,
          'destination': Uri.encodeComponent(normalizePath(to)),
          'override': '$override',
          'rename': 'false',
        });
      });

  /// Computes a checksum on the server (`md5`, `sha1`, `sha256`, `sha512`).
  Future<String> checksum(String path, String algorithm) => _call(() async {
        final res = await _dio.get<Map<String, dynamic>>(
            _api('resources', path),
            queryParameters: {'checksum': algorithm});
        return (res.data!['checksums'] as Map)[algorithm] as String;
      });

  Future<DiskUsage> usage(String path) => _call(() async {
        final res = await _dio.get<Map<String, dynamic>>(_api('usage', path));
        return DiskUsage(
          total: (res.data!['total'] as num).toInt(),
          used: (res.data!['used'] as num).toInt(),
        );
      });

  /// Searches below [path]. The server streams one JSON object per line.
  Future<List<SearchHit>> search(String path, String query) => _call(() async {
        final res = await _dio.get<String>(
          _api('search', path),
          queryParameters: {'query': query},
          options: Options(responseType: ResponseType.plain),
        );
        return const LineSplitter()
            .convert(res.data ?? '')
            .where((line) => line.trim().isNotEmpty)
            .map((line) {
          final json = jsonDecode(line) as Map<String, dynamic>;
          return SearchHit(
            path: json['path'] as String,
            isDir: json['dir'] as bool? ?? false,
          );
        }).toList();
      });

  // ---------------------------------------------------------------------------
  // Downloads and previews
  // ---------------------------------------------------------------------------

  /// URL of a file's raw bytes. For a folder, [archive] picks the format the
  /// server packs it in (`zip`, `tar.gz`, …).
  String rawUrl(String path, {String? archive}) =>
      _api('raw', path) + (archive == null ? '' : '?algo=$archive');

  /// URL of an image preview; [size] is `thumb` or `big`.
  String previewUrl(String path, String size, {DateTime? modified}) =>
      '${_api('preview/$size', path)}?inline=true'
      '${modified == null ? '' : '&key=${modified.millisecondsSinceEpoch}'}';

  /// Downloads [path] (or a folder as an archive) into [savePath].
  Future<void> download(
    String path,
    String savePath, {
    String? archive,
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) =>
      _call(() async {
        await _dio.download(
          rawUrl(path, archive: archive),
          savePath,
          onReceiveProgress: onProgress,
          cancelToken: cancelToken,
        );
      });

  // ---------------------------------------------------------------------------
  // Shares
  // ---------------------------------------------------------------------------

  /// Every link of the account; for an administrator, everyone's links.
  Future<List<ShareLink>> shares() => _call(() async {
        final res = await _dio.get<List<dynamic>>('$baseUrl/api/shares');
        return _shareLinks(res.data);
      });

  /// The links that already exist for the file or folder at [path].
  Future<List<ShareLink>> sharesFor(String path) => _call(() async {
        final res = await _dio.get<List<dynamic>>(_api('share', path));
        return _shareLinks(res.data);
      });

  List<ShareLink> _shareLinks(List<dynamic>? json) => (json ?? const [])
      .cast<Map<String, dynamic>>()
      .map(ShareLink.fromJson)
      .toList();

  /// Creates a share link. [expires] of 0 means it never expires; [unit] is
  /// one of [shareUnits]. An empty [password] leaves the link unprotected.
  ///
  /// The server falls back to hours for a unit it does not know and accepts
  /// negative lifetimes, so both are refused here rather than sent.
  Future<ShareLink> createShare(String path,
      {int expires = 0, String unit = 'hours', String password = ''}) {
    if (expires < 0 || expires > maxShareExpiry) {
      throw ArgumentError.value(expires, 'expires');
    }
    if (!shareUnits.contains(unit)) throw ArgumentError.value(unit, 'unit');
    return _call(() async {
      final res = await _dio.post<Map<String, dynamic>>(
        _api('share', path),
        // The server expects the number as a string; empty means "never".
        data: jsonEncode({
          'password': password,
          'expires': expires == 0 ? '' : '$expires',
          'unit': unit,
        }),
        options: Options(contentType: 'application/json'),
      );
      return ShareLink.fromJson(res.data!);
    });
  }

  Future<void> deleteShare(String hash) => _call(() async {
        await _dio
            .delete<void>('$baseUrl/api/share/${Uri.encodeComponent(hash)}');
      });

  /// The public address of a share, as the web UI builds it. It starts with
  /// the server address the user signed in to, including any base path.
  String shareUrl(ShareLink share) =>
      '$baseUrl/share/${Uri.encodeComponent(share.hash)}';

  /// The address that serves a shared file directly instead of showing the
  /// share page (for a folder: its archive). The web UI offers it only for
  /// links without a password, because it cannot carry one.
  String shareDownloadUrl(ShareLink share) =>
      '$baseUrl/api/public/dl/${Uri.encodeComponent(share.hash)}?inline=true';

  /// User names by account id. Only administrators may list users; it labels
  /// the owner of each link in their list of everyone's shares.
  Future<Map<int, String>> usernames() => _call(() async {
        final res = await _dio.get<List<dynamic>>('$baseUrl/api/users');
        return {
          for (final user
              in (res.data ?? const []).cast<Map<String, dynamic>>())
            (user['id'] as num?)?.toInt() ?? 0:
                user['username'] as String? ?? '',
        };
      });

  // ---------------------------------------------------------------------------
  // Resumable uploads (tus)
  // ---------------------------------------------------------------------------

  /// Starts a tus upload of [length] bytes to [path]. A 409 means the file
  /// exists and [override] was false.
  Future<void> tusCreate(String path, int length, {bool override = false}) =>
      _call(() async {
        await _dio.post<void>(
          _api('tus', path),
          queryParameters: {'override': '$override'},
          options: Options(headers: {
            'Tus-Resumable': '1.0.0',
            'Upload-Length': '$length',
          }),
        );
      });

  /// Returns how many bytes of [path] the server already has.
  Future<int> tusOffset(String path) => _call(() async {
        final res = await _dio.head<void>(_api('tus', path),
            options: Options(headers: {'Tus-Resumable': '1.0.0'}));
        return int.parse(res.headers.value('upload-offset') ?? '0');
      });

  /// Sends one chunk starting at [offset]; returns the new offset.
  Future<int> tusPatch(String path, int offset, Uint8List chunk,
          {CancelToken? cancelToken, void Function(int sent)? onSent}) =>
      _call(() async {
        final res = await _dio.patch<void>(
          _api('tus', path),
          data: chunk,
          cancelToken: cancelToken,
          onSendProgress: onSent == null ? null : (sent, _) => onSent(sent),
          options: Options(headers: {
            'Tus-Resumable': '1.0.0',
            'Upload-Offset': '$offset',
            Headers.contentTypeHeader: 'application/offset+octet-stream',
          }),
        );
        return int.parse(res.headers.value('upload-offset') ?? '$offset');
      });

  /// Uploads a local file with tus in [chunkSize] pieces, resuming from the
  /// server's offset after a failed chunk.
  Future<void> upload(
    File file,
    String path, {
    bool override = false,
    int chunkSize = 10 * 1024 * 1024,
    int retries = 3,
    void Function(int sent, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final length = await file.length();
    await tusCreate(path, length, override: override);
    onProgress?.call(0, length);
    final raf = await file.open();
    try {
      var offset = 0;
      var failures = 0;
      while (offset < length) {
        final size =
            (length - offset) < chunkSize ? length - offset : chunkSize;
        await raf.setPosition(offset);
        final chunk = await raf.read(size);
        try {
          final start = offset;
          offset = await tusPatch(path, offset, chunk,
              cancelToken: cancelToken,
              onSent: (sent) => onProgress?.call(start + sent, length));
          failures = 0;
        } on ApiException catch (e) {
          if (cancelToken?.isCancelled ?? false) rethrow;
          if (e.statusCode == 403 ||
              e.statusCode == 401 ||
              ++failures > retries) {
            rethrow;
          }
          await Future<void>.delayed(Duration(seconds: failures));
          offset = await tusOffset(path);
        }
        onProgress?.call(offset, length);
      }
    } finally {
      await raf.close();
    }
  }
}

const _kNoAuth = 'fbNoAuth';
const _kNoRenew = 'fbNoRenew';
const _kRetried = 'fbRetried';

class _AuthInterceptor extends Interceptor {
  _AuthInterceptor(this._api);

  final FileBrowserApi _api;

  bool _sameOrigin(Uri uri) => uri.origin == Uri.parse(_api.baseUrl).origin;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    // Never send credentials to another host, even if a caller passes an
    // absolute URL elsewhere.
    if (_sameOrigin(options.uri)) {
      if (_api.basicAuth != null) {
        options.headers['Authorization'] = _api.basicAuth!.header;
      }
      if (options.extra[_kNoAuth] != true && _api.token != null) {
        options.headers['X-Auth'] = _api.token;
      }
    }
    handler.next(options);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    // The server asks for renewal on every response once the token has less
    // than an hour left, which with a short configured lifetime is always.
    // Renewing at most once a minute keeps that from doubling the traffic.
    final renew = response.headers.value('x-renew-token') == 'true';
    final recent = _api._renewedAt != null &&
        DateTime.now().difference(_api._renewedAt!) <
            const Duration(minutes: 1);
    if (renew && !recent && response.requestOptions.extra[_kNoRenew] != true) {
      _api._renewedAt = DateTime.now();
      // Renew in the background; a failure only means the next request
      // renews or re-authenticates instead.
      unawaited(_api.renew().then((_) {}, onError: (_) {}));
    }
    handler.next(response);
  }

  @override
  Future<void> onError(
      DioException err, ErrorInterceptorHandler handler) async {
    final options = err.requestOptions;
    final canRetry = err.response?.statusCode == 401 &&
        options.extra[_kNoAuth] != true &&
        options.extra[_kRetried] != true &&
        _api.reauthenticate != null;
    if (!canRetry) {
      handler.next(err);
      return;
    }
    final fresh = await (_api._reauthenticating ??= _api.reauthenticate!()
        .catchError((Object _) => null)
        .whenComplete(() => _api._reauthenticating = null));
    if (fresh == null) {
      handler.next(err);
      return;
    }
    _api.token = fresh;
    options.extra[_kRetried] = true;
    try {
      handler.resolve(await _api._dio.fetch(options));
    } on DioException catch (e) {
      handler.next(e);
    }
  }
}
