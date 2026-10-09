import 'dart:convert';

/// One entry of a directory listing, or a single file fetched on its own.
class FileItem {
  const FileItem({
    required this.path,
    required this.name,
    required this.size,
    required this.modified,
    required this.isDir,
    required this.type,
    this.extension = '',
    this.isSymlink = false,
    this.content,
  });

  factory FileItem.fromJson(Map<String, dynamic> json) => FileItem(
        path: json['path'] as String? ?? '/',
        name: json['name'] as String? ?? '',
        size: (json['size'] as num?)?.toInt() ?? 0,
        modified: DateTime.tryParse(json['modified'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
        isDir: json['isDir'] as bool? ?? false,
        type: json['type'] as String? ?? '',
        extension: json['extension'] as String? ?? '',
        isSymlink: json['isSymlink'] as bool? ?? false,
        content: json['content'] as String?,
      );

  final String path;
  final String name;
  final int size;
  final DateTime modified;
  final bool isDir;

  /// The server's type detection: `image`, `video`, `audio`, `pdf`, `text`,
  /// `textImmutable`, `blob`, or empty for directories.
  final String type;
  final String extension;
  final bool isSymlink;

  /// The text of a text file, only present when the file itself was fetched.
  final String? content;

  bool get isImage => type == 'image';
  bool get isText => type == 'text' || type == 'textImmutable';
  bool get isHidden => name.startsWith('.');
}

/// A fetched resource: a directory with its entries, or a single file.
class Resource {
  const Resource({required this.item, this.items = const []});

  factory Resource.fromJson(Map<String, dynamic> json) => Resource(
        item: FileItem.fromJson(json),
        items: ((json['items'] as List?) ?? const [])
            .cast<Map<String, dynamic>>()
            .map(FileItem.fromJson)
            .toList(),
      );

  final FileItem item;
  final List<FileItem> items;
}

/// A share link as the server returns it.
class ShareLink {
  const ShareLink({
    required this.hash,
    required this.path,
    required this.expire,
    this.hasPassword = false,
  });

  factory ShareLink.fromJson(Map<String, dynamic> json) => ShareLink(
        hash: json['hash'] as String? ?? '',
        path: json['path'] as String? ?? '',
        expire: (json['expire'] as num?)?.toInt() ?? 0,
        hasPassword: json['hasPassword'] as bool? ?? false,
      );

  final String hash;
  final String path;

  /// Unix seconds; 0 means the link never expires.
  final int expire;
  final bool hasPassword;

  DateTime? get expiresAt => expire == 0
      ? null
      : DateTime.fromMillisecondsSinceEpoch(expire * 1000, isUtc: true);
}

/// One search hit. [path] is relative to the folder that was searched.
class SearchHit {
  const SearchHit({required this.path, required this.isDir});

  final String path;
  final bool isDir;
}

class DiskUsage {
  const DiskUsage({required this.total, required this.used});

  final int total;
  final int used;
}

/// The user's permissions, as carried in the JWT.
class Permissions {
  const Permissions({
    this.admin = false,
    this.create = false,
    this.rename = false,
    this.modify = false,
    this.delete = false,
    this.share = false,
    this.download = false,
  });

  factory Permissions.fromJson(Map<String, dynamic> json) => Permissions(
        admin: json['admin'] as bool? ?? false,
        create: json['create'] as bool? ?? false,
        rename: json['rename'] as bool? ?? false,
        modify: json['modify'] as bool? ?? false,
        delete: json['delete'] as bool? ?? false,
        share: json['share'] as bool? ?? false,
        download: json['download'] as bool? ?? false,
      );

  final bool admin;
  final bool create;
  final bool rename;
  final bool modify;
  final bool delete;
  final bool share;
  final bool download;
}

/// The signed-in user, decoded from the JWT the server issues at login.
class UserInfo {
  const UserInfo({
    required this.id,
    required this.username,
    required this.perm,
    this.hideDotfiles = false,
    this.lockPassword = false,
  });

  factory UserInfo.fromJson(Map<String, dynamic> json) => UserInfo(
        id: (json['id'] as num?)?.toInt() ?? 0,
        username: json['username'] as String? ?? '',
        perm: Permissions.fromJson(
            (json['perm'] as Map?)?.cast<String, dynamic>() ?? const {}),
        hideDotfiles: json['hideDotfiles'] as bool? ?? false,
        lockPassword: json['lockPassword'] as bool? ?? false,
      );

  final int id;
  final String username;
  final Permissions perm;
  final bool hideDotfiles;
  final bool lockPassword;
}

/// The parts of a File Browser JWT the app needs. The signature is not
/// checked here: the server checks it on every request.
class TokenClaims {
  const TokenClaims({required this.user, required this.expiresAt});

  final UserInfo user;
  final DateTime expiresAt;

  bool get isExpired => !DateTime.now().isBefore(expiresAt);

  static TokenClaims parse(String token) {
    final parts = token.split('.');
    if (parts.length != 3) throw const FormatException('Not a JWT');
    final payload =
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1])));
    final json = jsonDecode(payload) as Map<String, dynamic>;
    final exp = (json['exp'] as num?)?.toInt() ?? 0;
    return TokenClaims(
      user: UserInfo.fromJson(
          (json['user'] as Map?)?.cast<String, dynamic>() ?? const {}),
      expiresAt: DateTime.fromMillisecondsSinceEpoch(exp * 1000),
    );
  }
}
