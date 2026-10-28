# Changelog

## Unreleased

- Project scaffold: an empty menu bar app and the FreesideKit package (M0)
- Volumes: external drives, disk images, network shares and the boot volume, with free space matching Finder; updates within a second of a mount, unmount or rename; network reads time out after 2 s instead of hanging (M1)
- Drives: each volume mapped to its physical drive (AppleRAID sets to every member), with read and write rates, a 60-second trace and session totals; rates within 0.6 % of iostat; disk images aren't counted twice in the combined rate (M2)
- Ejecting: Eject, Eject All and Unmount (network) from the menu, unmounting APFS containers before the physical disk as Finder does; a busy eject opens a Blockers panel listing your processes holding the drive (open files, working directories, apps running from it, mapped files) and disk images attached from it, with Quit, Terminate, Eject Image, Retry and Force Eject; retries on its own when the last blocker exits; "Who's Using This?" without ejecting (M3)
- Menu bar: icon, space, activity, and space plus activity styles at a fixed width; switches to activity during a transfer and back 10 s after; low-space mark; VoiceOver summary and tooltip; menu bar settings in the right-click menu until the settings panel (M4)
- Rates no longer read 0 for a moment when the drive menu opens (M4)
