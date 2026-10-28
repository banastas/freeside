# Changelog

## Unreleased

- Project scaffold: an empty menu bar app and the FreesideKit package (M0)
- Volumes: external drives, disk images, network shares and the boot volume, with free space matching Finder; updates within a second of a mount, unmount or rename; network reads time out after 2 s instead of hanging (M1)
- Drives: each volume mapped to its physical drive (AppleRAID sets to every member), with read and write rates, a 60-second trace and session totals; rates within 0.6 % of iostat; disk images aren't counted twice in the combined rate (M2)
