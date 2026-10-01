// Toolbar popup: opens the game in a tab, then closes itself.
//
// The popup is a launcher, not the game. A browser popup is capped at 800x600
// and both boards need more room than that, so running the game inside one
// would give a board too small to read and a window that vanishes the moment
// you misclick.
//
// The same tab is reused every time, so repeatedly launching does not stack up
// duplicates. tabs.create has no `reuse` option, so an existing Game Club tab
// is focused instead of opening a second one.

const GAME = 'index.html';

function openGame() {
  const base = chrome.runtime.getURL(GAME);
  chrome.tabs.query({ url: base + '*' }, (tabs) => {
    const existing = (tabs || [])[0];
    if (existing) {
      chrome.tabs.update(existing.id, { active: true });
      chrome.windows.update(existing.windowId, { focused: true });
    } else {
      chrome.tabs.create({ url: base });
    }
    window.close();
  });
}

document.getElementById('play').addEventListener('click', openGame);
// The app has no router, so both buttons land on the same page. Kept separate
// because "jump straight to online" is what most people want once installed,
// and it is honest about being the same screen rather than faking a route.
document.getElementById('online').addEventListener('click', openGame);
