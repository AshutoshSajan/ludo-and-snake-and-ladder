// Toolbar popup: opens the game in its own window, then closes itself.
//
// The popup is a launcher, not the game. A browser popup is capped at 800x600
// and closes when you click outside it, so running a board game inside one
// means a board too small to read in a window that vanishes mid-move.
//
// The window is a real browser window (`type: 'popup'`: no tab strip, no
// address bar) sized for the board, which is also what makes an existing one
// findable and reusable instead of stacking up a window per click.
//
// Why not chrome.tabs.query to find the game's tab, which is what the original
// launcher did: filtering tabs by URL requires the "tabs" permission, and
// neither manifest declares it. That query returned nothing, so the reuse path
// never ran and every click opened another tab. windows.getAll does not need
// the permission.
//
// The permission-free `windows.getAll` still cannot promise `tab.url` is
// populated, so the lookup is written to treat a missing URL as "no match"
// rather than throw - worst case it opens a window that could have been
// focused, which is the old behaviour and not a failure.

const GAME = 'index.html';

function openGame() {
  const url = chrome.runtime.getURL(GAME);

  const open = () => {
    chrome.windows.create({
      url,
      type: 'popup',
      width: 1100,
      height: 820,
    });
  };

  chrome.windows.getAll({ populate: true, windowTypes: ['popup'] }, (wins) => {
    if (chrome.runtime.lastError) {
      open();
      window.close();
      return;
    }
    const existing = (wins || []).find((w) =>
      (w.tabs || []).some((t) => typeof t.url === 'string' && t.url === url));
    if (existing) {
      chrome.windows.update(existing.id, { focused: true });
    } else {
      open();
    }
    window.close();
  });
}

document.getElementById('play').addEventListener('click', openGame);
