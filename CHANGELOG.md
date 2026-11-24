# Changelog

All notable changes to Protium are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and Protium
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). It is written for players:
what they will notice. `macos/make-release.sh` puts a release's section into the app and
`macos/publish-release.sh` onto its page on GitHub, so this file is where release notes are
written. "Known problems" is a heading of our own, next to Keep a Changelog's.

## [Unreleased]

### Fixed

- Games that keep their saves in Documents, such as Horizon Zero Dawn Remastered, started without
  the saves Steam Cloud had brought down. Steam and the game were using two different folders.
  They now use the same one, and saves already downloaded are moved to where the game finds them.
  Where both folders had a save of the same name, the newer one is used and the older one is kept
  in "My Documents (older copies)".

## [0.3.1] - 2026-11-24

### Added

- A Diagnostics button. It saves one text file to your Desktop that shows how Protium and Steam
  are set up on your Mac and what their logs last said, so you can attach it when you report a
  problem. Nothing is sent anywhere. The file includes the names of your installed games; your
  home folder and Steam account numbers are left out.

### Changed

- The messages in Protium's window are clearer about what happened and what to do next.

### Fixed

- "Set up Steam" on a Steam that had never been opened or signed in to ended in a Python error.
  Protium now tells you to open Steam and sign in first.
- If Steam kept starting without Protium's tools, Protium's background helper restarted it again
  and again, and Steam could not be used. It now stops after three tries and tells you to press
  Repair.
- Deleting Protium.app without pressing Uninstall left Steam changed. Protium now removes itself
  from Steam about ten minutes after the app is deleted.

## [0.3.0] - 2026-11-24

### Added

- Protium updates itself: when a newer version is out, its window shows what that version
  changes and an Update button. The download is only installed if it is signed by Protium's
  developer and notarized by Apple, and the old version comes back if the new one does not
  start. After an update the window says what is new.
- When you start a game and a newer version is out, a small banner at the top of the screen says
  so for a few seconds, once per version. It never takes the keyboard or the mouse from the game.
  If you allow Protium to send notifications ("Allow notifications…" in its window), it is in
  Notification Centre too.
- Protium asks GitHub for new versions once a day at most. The checkbox "Tell me about new
  versions" in its window, or `steamplay updates off`, turns the asking off.

### Fixed

- Protium's own Python no longer writes files into the app. In 0.1.0 and 0.2.0 it did so the
  first time some of its modules were used, which left the app's signature no longer matching
  its contents.

### Known problems

- 0.1.0 and 0.2.0 cannot update themselves: download this version from its page and drag it
  over the older one. From this version on, Protium updates from its own window.
- The first load of a level can take several minutes while shaders are compiled, and a game can
  hitch the first time it draws something new. Later loads are faster.

## [0.2.0] - 2026-11-24

### Added

- Protium's window says when a newer version is out, with a button to its page, and shows its
  own version in the title. For this it asks GitHub for the newest release when it opens; the
  request says nothing about your Mac or your games.
- `steamplay result` keeps the list of games people have tried, and the README's table is written
  from it. Call of Duty: World at War and Modern Warfare Remastered are on it.

### Changed

- While a game hides the pointer, the mouse moves it a pixel per count, without macOS's
  acceleration, so you may want to set the game's sensitivity again.

### Fixed

- Mouse look is even in games that turn the camera by moving the pointer back to the middle of
  the window every frame, such as Call of Duty: World at War and Modern Warfare Remastered. The
  camera used to turn on every second frame, most visibly at a low mouse DPI.

### Known problems

- The first load of a level can take several minutes while shaders are compiled, and a game can
  hitch the first time it draws something new. Later loads are faster.

## [0.1.0] - 2026-11-24

The first release: Steam Play for Apple Silicon Macs, with Windows games from your Steam library
run natively on arm64 with Metal, without Rosetta and without a virtual machine.

### Added

- Protium.app sets up Steam Play in Mac Steam, repairs it, shows its status and takes it out
  again.
- Direct3D 9, 10 and 11 on Metal, Direct3D 12 and Vulkan on KosmicKrisp, 32-bit and 64-bit games.
- Steam sign-in, ownership, stats, achievements and Steam Cloud work through the running Mac
  Steam.
- `steamplay discover` ranks the games in your library by how likely they are to work, and says
  why.

[Unreleased]: https://github.com/0xLeathery/protium/compare/v0.3.1...macos-port
[0.3.1]: https://github.com/0xLeathery/protium/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/0xLeathery/protium/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/0xLeathery/protium/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/0xLeathery/protium/releases/tag/v0.1.0
