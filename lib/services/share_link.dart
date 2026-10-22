/// Native share-sheet entry point, platform-split.
///
/// Web builds use the browser's Web Share API through `package:web`
/// ([share_link_web.dart]); every other platform resolves the no-op stub
/// ([share_link_stub.dart]) and the caller falls back to copying the link.
/// The split is a conditional export so native builds never compile browser
/// APIs.
library;

export 'share_link_stub.dart' if (dart.library.js_util) 'share_link_web.dart';
