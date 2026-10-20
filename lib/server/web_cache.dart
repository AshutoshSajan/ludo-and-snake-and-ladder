/// Cache policy for the web client the server hosts.
///
/// Flutter's web files are **not content-hashed** — `main.dart.js` is always
/// that name, not `main.<hash>.js` — so a browser that cached it went on
/// running the previous deploy. "Fixed on the server" and "fixed in your
/// browser" were two different things, and a deploy looked broken long after
/// it had landed.
///
/// So the shell revalidates on every load: a cheap `304` when nothing changed,
/// but never a stale body. And under `/assets/` nothing may be pinned for a
/// year either. Flutter's web outputs there are constant-**named but
/// build-**derived**: the tree-shaken MaterialIcons subset always ships at
/// `assets/fonts/MaterialIcons-Regular.otf`, and which glyphs it contains
/// changes the moment any new icon is used; `AssetManifest` and `FontManifest`
/// describe every other asset and go stale in the same breath; shaders are
/// regenerated per Flutter version. Pinning those immutable was exactly the
/// "new icons render blank after a deploy" bug — the browser kept last
/// deploy's font subset while the code asking for it was fresh. They
/// revalidate like the shell. The genuinely version-stable output — canvaskit,
/// which ships under a Flutter-version-named directory, and the launcher
/// icons — is held for a year.
library;

/// Headers for one requested path, e.g. `/main.dart.js`.
///
/// The path is the *request* path, not the file that ends up served — so `/`
/// is handled explicitly: the static handler resolves it to `index.html`, which
/// is app shell and must revalidate, but its request path carries no file
/// name. Keying off the name alone quietly gave the home page a year-long
/// immutable cache.
Map<String, String> webCacheHeaders(String path) {
  const shell = {
    'index.html',
    'main.dart.js',
    'flutter_bootstrap.js',
    'flutter.js',
    'flutter_service_worker.js',
    'version.json',
    'manifest.json',
  };
  final name = path.split('/').last;
  // An empty name means a directory request, answered with the default
  // document — index.html, i.e. shell.
  if (name.isEmpty || shell.contains(name)) {
    return const {'cache-control': 'no-cache, must-revalidate'};
  }
  // Everything Flutter emits under /assets/ is constant-named but
  // build-derived — the tree-shaken MaterialIcons subset, the asset and font
  // manifests, shaders, and the app's own sounds and images. None of those
  // paths are versioned, so none of them may be pinned immutable: a cached
  // font subset is exactly how "the new icons render blank after a deploy"
  // looks. They revalidate like the shell — a cheap 304 when unchanged.
  if (path.startsWith('/assets/')) {
    return const {'cache-control': 'no-cache, must-revalidate'};
  }
  // Genuinely version-stable output: canvaskit ships under a
  // Flutter-version-named directory; the launcher icons are fixed images.
  if (path.startsWith('/canvaskit/') || path.startsWith('/icons/')) {
    return const {'cache-control': 'public, max-age=31536000, immutable'};
  }
  // Anything else: revalidate. Wrong in the safe direction — a revalidation
  // costs a request, a stale body costs a bug report.
  return const {'cache-control': 'no-cache, must-revalidate'};
}
