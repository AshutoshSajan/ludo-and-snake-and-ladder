// Toolbar popup: launches the game *inside* the popup.
//
// The game is loaded in an iframe over the launcher, so nothing opens a new
// page and the tab count never changes. A browser popup is capped at 800x600,
// so the board is smaller here than in a tab - popup.html says so, and "Open
// in a tab" is still one click away for when the space is not enough.
//
// Note the popup closes when you click outside it. That is the browser's rule
// for popups, not something this page can override, and it is the main reason
// the tab is still offered rather than removed.

const body = document.body;
const frame = document.getElementById('game');
const launcher = document.getElementById('launcher');

function play() {
  body.classList.add('playing');
  // Focus the frame so the game takes keyboard input immediately; an iframe
  // that never receives focus swallows every key press.
  frame.focus();
}

function openInTab() {
  chrome.tabs.create({ url: chrome.runtime.getURL('index.html') });
  window.close();
}

document.getElementById('play').addEventListener('click', play);
document.getElementById('online').addEventListener('click', play);
document.getElementById('tab').addEventListener('click', openInTab);
document.getElementById('back').addEventListener('click', () => {
  body.classList.remove('playing');
});
