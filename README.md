# CommandV

A clipboard manager for macOS. Everything you copy is saved, searchable and one shortcut away.

![Clipboard panel in light mode](screenshots/panel_light.png)

![Clipboard panel in dark mode](screenshots/panel_dark.png)

## Features

* Unlimited history of text, links, rich text, images and files
* Instant search, including the text inside screenshots
* Filters by type and by the app a clip came from
* Pinboards for the clips you reuse
* Paste stack: copy several things, then paste them in order
* Drag a card into any app, or onto a pinboard tab to keep it
* Light and dark mode
* Password managers are ignored by default
* Everything stays on your Mac

![Searching for text inside a screenshot](screenshots/search.png)

## How it works

CommandV runs in the menu bar and watches the system pasteboard. 
Each copy is saved to a local SQLite database together with the app it came from. Images are stored on disk with a thumbnail, and their text is read on your Mac with Apple's Vision framework, then added to a full text index so a screenshot can be found by the words in it.

Press ⇧⌘V and a panel slides up along the bottom of the screen. Pick a card with the arrow keys or the mouse and press Return. CommandV puts the clip back on the clipboard, returns to the app you were using and sends ⌘V for you. Hold Shift while pressing Return to paste plain text.

Copies from excluded apps, and anything an app marks as concealed, are never saved. You can edit the excluded list in Settings.

![Settings window](screenshots/settings.png)

## Shortcuts

* ⇧⌘V opens and closes the panel
* ⇧⌘C starts and stops the paste stack, and ⇧⌘V pastes the next item while it runs
* Arrow keys move, Return pastes, Shift Return pastes plain text, Delete removes a clip, Esc clears the search and then closes the panel

Both global shortcuts can be changed in Settings.

## Setup

You build the app yourself, so you need a Mac running macOS 14 or later and Xcode. Nothing else is required.

1. Install Xcode from the Mac App Store. It is a large download.
2. Open Xcode once and accept the license when it asks. Wait until it finishes installing extra components, then quit it.
3. Open Terminal and download the code:

```
git clone https://github.com/jamesebond/CommandV.git
cd CommandV
```

4. Build the app. This takes a few minutes the first time:

```
scripts/bundle.sh
```

5. Start it:

```
open build/CommandV.app
```

CommandV appears as an icon in the menu bar. Press ⇧⌘V to open the panel.

On a Mac with a notch, the icon can be hidden when the menu bar is full. Quit a few other menu bar apps if you cannot see it. The ⇧⌘V shortcut works either way.

## Allow pasting

To paste for you, CommandV needs Accessibility access. Open System Settings, then Privacy and Security, then Accessibility, and turn on CommandV. Without it, clips are still copied and you press ⌘V yourself.

The app is signed ad hoc, so after you rebuild it macOS may ask you to grant access again.

## For developers

```
swift build
swift test
```

## Limits

* Text over 1 MB is shortened when pasted back
* No iCloud sync and no iOS app
