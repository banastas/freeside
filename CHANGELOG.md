# Changelog

## 0.2.0 (2026-10-28)

- Uses far less CPU: about 0.13 % while showing live rates, down from 1.8 %. Free space is no longer re-read in full every time a drive writes, and the menu bar no longer redraws several times per update.
- An app icon: a drive with a capacity bar
- The popover's header shows how many external drives are attached and their total free space; Eject All moves to the footer
- The popover opens a little faster

## 0.1.1 (2026-10-28)

- Tests the update from 0.1.0. Nothing else has changed.

## 0.1.0 (2026-10-28)

The first preview release.

- Free space for external drives, disk images, network shares and the internal disk, matching Finder, with a mark when a volume runs low
- Read and write rates for each physical drive, with a 60-second trace and session totals
- Eject and Eject All, done the way Finder does; when a drive won't eject, a list of the apps and processes holding it and the files they have open, with Quit, Terminate, Retry and Force Eject
- "Who's using this?" for any drive, without ejecting
- Menu bar shows a drive icon, free space on one volume, live rates, or both, and switches to rates during a copy
- Optional notifications for low space and for a finished copy of 1 GB or more
- Copy Diagnostics for bug reports, with no file paths in it
- Signed, notarized and updated automatically

## Development (M0–M9)

- Project scaffold: an empty menu bar app and the FreesideKit package (M0)
- Volumes: external drives, disk images, network shares and the boot volume, with free space matching Finder; updates within a second of a mount, unmount or rename; network reads time out after 2 s instead of hanging (M1)
- Drives: each volume mapped to its physical drive (AppleRAID sets to every member), with read and write rates, a 60-second trace and session totals; rates within 0.6 % of iostat; disk images aren't counted twice in the combined rate (M2)
- Ejecting: Eject, Eject All and Unmount (network) from the menu, unmounting APFS containers before the physical disk as Finder does; a busy eject opens a Blockers panel listing your processes holding the drive (open files, working directories, apps running from it, mapped files) and disk images attached from it, with Quit, Terminate, Eject Image, Retry and Force Eject; retries on its own when the last blocker exits; "Who's Using This?" without ejecting (M3)
- Menu bar: icon, space, activity, and space plus activity styles at a fixed width; switches to activity during a transfer and back 10 s after; low-space mark; VoiceOver summary and tooltip; menu bar settings in the right-click menu until the settings panel (M4)
- Rates no longer read 0 for a moment when the drive menu opens (M4)
- Popover: a click on the menu bar item opens a card per drive with read and write rates, a mirrored 60-second trace, session totals, Eject, and each volume's used/total bar and free space; disk images and network shares in their own sections; the internal disk collapsed; Eject All in the header lists what ejected (M5)
- Blockers now show inside the drive's card instead of a separate window, with Terminate, Kill and Force Eject confirmed inline (M5)
- Settings: every setting in the popover's settings panel: menu bar style and volume, volumes shown, units, low-space threshold (5, 10 or 20 %, or a fixed amount in GB), notifications, accent color and launch at login; offers to start at login on first run from Applications (M6)
- Notifications, both off by default: Low space when a volume crosses the threshold, and Transfer finished after writing 1 GB or more to an external drive (M6)
- Copy Diagnostics in the right-click menu and settings: a plain-text report of versions, the drive map, recent eject failures and the last scan, with no file paths (M6)
- Disk images attached with `diskutil image attach` are now named after their file and listed as blockers of the drive holding them (M6)
- New drives no longer show "no I/O statistics" before their first sample (M6)
- The first reading after sampling starts is no longer 0, which could hide a transfer that began just then (M6)
- Release script: builds a Developer ID signed, notarized and stapled DMG (M7)
- Updates: Sparkle checks freeside.banast.as daily; Check for Updates in the right-click menu and settings, with automatic check and download toggles; the popover's footer shows when an update is available (M8)
- Site: freeside.banast.as with a download button, a screenshot, requirements and release notes; the release script adds each version to the update feed (M8)
- Tick profiler: `FREESIDE_PROFILE=1`, as in flatline, with the popover's time to first frame and `FREESIDE_POPOVER=cycle` (M9)
