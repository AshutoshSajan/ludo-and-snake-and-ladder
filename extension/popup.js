// Toolbar popup: opens the game in a new tab, then closes itself.
//
// The popup is a launcher, not the game. A browser popup is capped at 800x600
// and closes when you click outside it, so running a board game inside one means
// a board too small to read in a window that vanishes mid-move.
//
// A plain tab, and a fresh one every click:
//
//   - chrome.tabs.create needs no permission at all, which is why it is used
//     rather than chrome.windows.create or anything that inspects tabs.
//   - Focusing an already-open game tab is deliberately NOT attempted. Finding
//     a tab by URL needs the "tabs" permission, which Chrome presents to users
//     as "read your browsing history" - not a fair trade for saving one tab.
//     The original launcher did query by URL without declaring the permission,
//     so the reuse never worked and it opened a tab each time regardless. Better
//     to be plainly one-tab-per-click than to ship a dedupe that looks live and
//     silently is not.
//
// If you want one tab to be reused, the honest way is to declare "tabs" in both
// manifests and accept the permission warning. The test in
// test/extension_manifest_test.dart asserts the permission is NOT declared while
// this stays a plain create, so the two cannot drift apart.

const GAME = 'index.html';

function openGame() {
  chrome.tabs.create({ url: chrome.runtime.getURL(GAME) });
  // The launcher has done its job; leaving it open would sit over the game.
  window.close();
}

document.getElementById('play').addEventListener('click', openGame);
