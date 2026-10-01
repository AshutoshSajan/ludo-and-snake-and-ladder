// Toolbar popup: the game, filling the popup from the moment it opens.
//
// There is no launcher. The app's own home screen already offers local play,
// online play and the leaderboards, so a die, an "Open Game Club" button and a
// "Play online" button were asking the same question twice before handing over
// to that same UI. The popup now boots straight into the real main screen.
//
// The game runs in an iframe sized to the full popup, so it is correctly
// measured on the first frame rather than being revealed later. A display:none
// iframe has a 0x0 viewport, which is why an earlier version of this that hid
// the frame behind the launcher rendered a blank popup.
//
// Note the popup closes when you click outside it. That is the browser's rule
// for popups, not something this page can override, and it is why "Open in a
// tab" is still one click away - a 10-seat Snakes grid does not fit in 800x600.

const frame = document.getElementById('game');

function openInTab() {
  chrome.tabs.create({ url: chrome.runtime.getURL('index.html') });
  window.close();
}

document.getElementById('tab').addEventListener('click', openInTab);

// Take keyboard input immediately; an iframe that never receives focus swallows
// every key press, which for a game that responds to the arrow keys and Enter
// means the board looks frozen.
frame.focus();
