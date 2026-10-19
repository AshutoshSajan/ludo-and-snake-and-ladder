import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/services/online_client.dart';
import 'package:game_club/ui/shared/chat_line_view.dart';

/// The GIF bubble's loader phases.
///
/// Phase decisions key on the decoded frame (`frameBuilder`), not on
/// chunk progress: between stream resolution and the first fetched bytes,
/// progress is null, and a progress-based reader mistakes "not yet" for
/// "done" — painting a zero-height empty bubble (the player's "empty gold
/// strip") or parking a loaded GIF behind a spinner. [MemoryImage] drives
/// the phases offline — valid bytes reach the rendered image, garbage
/// bytes reach the error card, and [_NeverResolvingProvider] holds the
/// placeholder phase forever — while a real `NetworkImage` is never
/// touched in a widget test.
void main() {
  // A known-good 1x1 RGBA PNG (built chunk-by-chunk with verified CRCs —
  // content irrelevant, decode must succeed).
  final goodPng = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4f4bhPwAHZALLB0SopwAAAABJRU5ErkJggg==',
  );

  Future<void> pumpGifLine(WidgetTester tester, ImageProvider provider) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatLineView(
            line: ChatLine(from: 'Nova', gif: 'https://via.test/gif.gif'),
            myName: 'Rex',
            gifImageProvider: provider,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('a loaded GIF renders the image — no spinner left behind', (
    tester,
  ) async {
    await pumpGifLine(tester, MemoryImage(goodPng));

    // The codec hands the first frame over on the real event loop; a
    // fake-clock pump alone cannot flush it. One runAsync turn, then
    // frame the rebuild the stream notification schedules.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();

    expect(find.byType(Image), findsAtLeastNWidgets(1));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('GIF unavailable'), findsNothing);

    // The frame is fixed: the loaded image is the same 5:3 crop the
    // placeholder reserved (230 x 138), so the bubble never jumps size
    // when the pixels land. A 1x1 source proves the widget — not the
    // intrinsic image — decides the geometry.
    expect(tester.getSize(find.byType(Image)), equals(const Size(230, 138)));
  });

  testWidgets('an image that fails to decode shows the GIF unavailable card', (
    tester,
  ) async {
    await pumpGifLine(tester, MemoryImage(Uint8List.fromList(const [1, 2, 3])));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('GIF unavailable'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('a GIF that has fetched nothing yet shows the felt placeholder — '
      'not an empty bubble', (tester) async {
    // The pre-first-chunk phase: stream resolved, zero bytes in. The old
    // progress-based read called this "loaded" and painted the unresolved
    // child at zero height — the player's empty gold strip.
    await pumpGifLine(tester, _NeverResolvingProvider());
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('GIF unavailable'), findsNothing);
    expect(find.byType(Image), findsAtLeastNWidgets(1));

    // The placeholder reserves the full fixed frame while it waits — the
    // same 230 x 138 the loaded image will occupy, never a bar.
    expect(tester.getSize(find.byType(Image)), equals(const Size(230, 138)));
  });
}

/// An image source whose stream never resolves: `obtainKey` answers at
/// once, but `load` hands back a completer fed by a future that never
/// completes, which holds the bubble in the pre-frame phase indefinitely —
/// the exact state a slow or stalled CDN fetch produces live.
class _NeverResolvingProvider extends ImageProvider<Object> {
  @override
  Future<Object> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<Object>(this);

  @override
  ImageStreamCompleter loadImage(Object key, ImageDecoderCallback decode) {
    return OneFrameImageStreamCompleter(Completer<ImageInfo>().future);
  }
}
