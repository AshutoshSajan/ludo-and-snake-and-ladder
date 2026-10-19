import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../services/gif_search.dart';
import '../page_app_bar.dart';
import '../theme.dart';

/// The GIF picker: trending-first search (through the game server's
/// provider-neutral proxy) with a paste-a-link fallback that needs no
/// API key at all.
///
/// Why the fallback is a first-class citizen rather than an error
/// state: `/media/gif` answers 503 on servers without a provider key —
/// that is configuration, not breakage — so the sheet presents the link
/// path as the remaining way to share, with the reason spelled out.
///
/// The sheet opens on the provider's trending feed so the first screen
/// is content, not a dead prompt; searching swaps to results, and a
/// load-more row keeps pulling pages back from the cursor the server
/// remembers per provider.
class GifPickerSheet extends StatefulWidget {
  const GifPickerSheet({
    super.key,
    required this.serverUrl,
    required this.onPick,
    this.httpClient,
  });

  final String serverUrl;

  /// Called with the chosen GIF's full-resolution URL. The caller owns
  /// the send (and any feedback), so the sheet stays a pure picker.
  final void Function(String url) onPick;

  /// Injectable transport for tests; production uses the default `http`
  /// client against the game server's `/media/gif`.
  final http.Client? httpClient;

  static Future<void> show(
    BuildContext context, {
    required String serverUrl,
    required void Function(String url) onPick,
    http.Client? httpClient,
  }) {
    // Same reading width as the chat sheet it opens from: a picker
    // belted across a desktop window under a 720px chat column would
    // read as a second, wider app.
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: kContentMaxWidth),
      backgroundColor: AppColors.feltLight,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) =>
          GifPickerSheet(serverUrl: serverUrl, onPick: onPick, httpClient: httpClient),
    );
  }

  @override
  State<GifPickerSheet> createState() => _GifPickerSheetState();
}

class _GifPickerSheetState extends State<GifPickerSheet> {
  final _searchCtrl = TextEditingController();
  final _linkCtrl = TextEditingController();

  List<GifItem>? _results;
  String? _next;
  String _provider = '';
  bool _loadingMore = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // The first screen is the provider's trending feed: content before
    // any typing, on the sheet's one designed fetch.
    WidgetsBinding.instance.addPostFrameCallback((_) => _fetch());
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _linkCtrl.dispose();
    super.dispose();
  }

  /// One page, trending or searched. With a cursor this is a
  /// load-more: results append instead of replacing, so a player never
  /// loses their place in the grid.
  Future<void> _fetch() async {
    if (_loadingMore) return;
    final query = _searchCtrl.text.trim();
    final cursor = _next;
    setState(() {
      _loadingMore = true;
      if (cursor == null) _error = null;
    });
    try {
      final page = await searchGifsPage(
        widget.serverUrl,
        query,
        pos: cursor,
        httpClient: widget.httpClient,
      );
      if (!mounted) return;
      setState(() {
        _provider = page.provider;
        _next = page.next;
        _results = cursor == null
            ? page.gifs
            : [...?_results, ...page.gifs];
        _loadingMore = false;
        if (_results!.isEmpty && cursor == null) {
          _error = 'Nothing found — try another word';
        }
      });
    } on GifSearchException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.text;
        _loadingMore = false;
        if (cursor == null) _results = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'GIF search failed — paste an image link instead';
        _loadingMore = false;
        if (cursor == null) _results = null;
      });
    }
  }

  void _runSearch() {
    if (_loadingMore) return;
    setState(() => _next = null);
    _fetch();
  }

  /// A pasted link only needs to be a usable https image URL; the room's
  /// server applies the same https check, so this is a pre-flight mirror
  /// of it, not the authority.
  bool get _linkLooksValid {
    final value = _linkCtrl.text.trim();
    if (value.isEmpty) return false;
    final uri = Uri.tryParse(value);
    return uri != null && uri.scheme == 'https' && uri.host.isNotEmpty;
  }

  void _pickLink() {
    if (!_linkLooksValid) return;
    widget.onPick(_linkCtrl.text.trim());
    Navigator.of(context).pop();
  }

  void _pickResult(GifItem item) {
    widget.onPick(item.url);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 10),
          Container(
            width: 42,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                Icon(Icons.gif_box, size: 18, color: AppColors.gold),
                SizedBox(width: 8),
                Text(
                  'Send a GIF',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                    color: AppColors.ivory,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchCtrl,
                    autofocus: true,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _runSearch(),
                    style: const TextStyle(color: AppColors.ivory),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: 'Search GIFs…',
                      hintStyle: TextStyle(
                        color: AppColors.ivory.withValues(alpha: 0.5),
                      ),
                      filled: true,
                      fillColor: AppColors.felt,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.search, color: AppColors.gold),
                  tooltip: 'Search',
                  onPressed: _runSearch,
                ),
              ],
            ),
          ),
          if (_results == null && _error == null && _loadingMore)
            const Padding(
              padding: EdgeInsets.all(24),
              child: CircularProgressIndicator(),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                _error!,
                style: const TextStyle(color: AppColors.danger, fontSize: 13),
              ),
            ),
          if (_results != null && _results!.isNotEmpty)
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final item in _results!) _GifTile(item: item, onPick: _pickResult),
                    ],
                  ),
                  // Load more rides the server's opaque cursor; gone when
                  // the provider runs out of pages.
                  if (_next != null || _loadingMore) ...[
                    const SizedBox(height: 12),
                    Center(
                      child: _loadingMore
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : OutlinedButton.icon(
                              icon: const Icon(Icons.expand_more, size: 16),
                              label: const Text('More GIFs'),
                              onPressed: _fetch,
                            ),
                    ),
                  ],
                  // Provider attribution lives inside the content area,
                  // the spot the attribution guides call out.
                  const SizedBox(height: 12),
                  Center(
                    child: Text(
                      _provider.isEmpty ? '' : 'Powered by $_provider',
                      style: const TextStyle(color: Colors.white38, fontSize: 10),
                    ),
                  ),
                ],
              ),
            ),
          const Divider(height: 1, color: Colors.white12),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _linkCtrl,
                    style: const TextStyle(color: AppColors.ivory),
                    onSubmitted: (_) => _pickLink(),
                    // Validity gates the send button, so keystrokes must
                    // re-evaluate it — without this the button stays
                    // disabled until some other rebuild.
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: 'Or paste an image link (https://…)',
                      hintStyle: TextStyle(
                        color: AppColors.ivory.withValues(alpha: 0.5),
                      ),
                      filled: true,
                      fillColor: AppColors.felt,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                IconButton.filled(
                  icon: const Icon(Icons.send),
                  tooltip: 'Send GIF',
                  onPressed: _linkLooksValid ? _pickLink : null,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One search result: the animated preview, tap to send.
class _GifTile extends StatelessWidget {
  const _GifTile({required this.item, required this.onPick});

  final GifItem item;
  final void Function(GifItem) onPick;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => onPick(item),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          width: 110,
          height: 90,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image.network(
                item.preview,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const ColoredBox(
                  color: AppColors.felt,
                  child: Center(child: Icon(Icons.broken_image, size: 20)),
                ),
              ),
              Align(
                alignment: Alignment.bottomCenter,
                child: Container(
                  color: Colors.black45,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 2,
                  ),
                  child: Text(
                    item.desc,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white70, fontSize: 10),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
