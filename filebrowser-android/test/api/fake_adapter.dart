import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// A scripted HTTP adapter: records every request and answers from [handler].
class FakeAdapter implements HttpClientAdapter {
  FakeAdapter(this.handler);

  final ResponseBody Function(RequestOptions options) handler;
  final requests = <RequestOptions>[];

  /// Headers as sent; a retried request reuses and changes its options.
  final sentHeaders = <Map<String, dynamic>>[];

  /// When set, a request is answered only once the future this returns for
  /// it completes; null answers it at once. For tests of what happens while
  /// a request is under way.
  Future<void>? Function(RequestOptions options)? hold;

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    if (requestStream != null) await requestStream.drain<void>();
    requests.add(options);
    sentHeaders.add(Map.of(options.headers));
    await hold?.call(options);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody reply(int status,
        {Object body = '', Map<String, String> headers = const {}}) =>
    ResponseBody.fromString(
      body is String ? body : jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [
          body is String ? 'text/plain' : 'application/json'
        ],
        for (final e in headers.entries) e.key: [e.value],
      },
    );

/// A JWT whose payload the app can decode (the signature is not checked).
String fakeToken(
    {String username = 'alice',
    int id = 1,
    Duration ttl = const Duration(hours: 2),
    int iat = 0}) {
  String part(Object json) =>
      base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
  final exp = DateTime.now().add(ttl).millisecondsSinceEpoch ~/ 1000;
  return '${part({'alg': 'HS256'})}.${part({
        'user': {
          'id': id,
          'username': username,
          'perm': {'create': true, 'delete': false},
          'hideDotfiles': true,
        },
        'exp': exp,
        'iat': iat,
      })}.sig';
}
