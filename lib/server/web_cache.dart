/// Cache policy for the web client the server hosts.
///
/// Flutter's web files are **not content-hashed** — `main.dart.js` is always
/// that name, not `main.<hash>.js` — so a browser that cached it went on
/// running the previous deploy. "Fixed on the server" and "fixed in your
/// browser" were two different things, and a deploy looked broken long after
/// it had landed.
///
/// So the shell revalidates on every load: a cheap `304` when nothing changed,
/// but never a stale body. The bulk assets (fonts, canvaskit, icons) are held
/// for a year instead, since those *are* versioned by name and are most of the
/// payload.
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
  // Anything else is assumed to be a versioned asset. Wrong in the safe
  // direction: a file Flutter adds later is far more likely to be an asset
  // than the app shell, and every shell name is listed above.
  return const {'cache-control': 'public, max-age=31536000, immutable'};
}
