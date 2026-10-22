/// Non-web half of [shareJoinLink]: there is no share sheet to open, so the
/// caller's copy fallback is the whole answer.
library;

Future<bool> shareJoinLink(
  String url, {
  String title = 'Game Club',
  String? text,
}) async => false;
