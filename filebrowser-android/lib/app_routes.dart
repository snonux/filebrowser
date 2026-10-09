/// Route paths. File paths travel as a query parameter so they can contain
/// any character.
abstract final class AppRoutes {
  static const login = '/login';
  static const browse = '/files';
  static const editor = '/edit';
  static const viewer = '/view';
  static const searchPage = '/search';
  static const shares = '/shares';
  static const settings = '/settings';

  static String _with(String route, String path) =>
      Uri(path: route, queryParameters: {'path': path}).toString();

  static String files(String path) => _with(browse, path);
  static String edit(String path) => _with(editor, path);
  static String view(String path) => _with(viewer, path);
  static String search(String path) => _with(searchPage, path);
}
