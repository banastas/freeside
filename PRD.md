# freeside: Product Requirements

| | |
|---|---|
| **Status** | 1.0.0 released (2026-11-04). Checked after 1.0: VoiceOver, the §9.1 hardware not yet at hand, Transfer finished with the Mac fully asleep |
| **Owner** | Bill Anastas |
| **Last updated** | 2026-10-28 |
| **Repo** | [banastas/freeside](https://github.com/banastas/freeside) |
| **Site / updates** | https://freeside.banast.as |
| **Sibling** | [flatline](https://github.com/banastas/flatline) (CPU, memory, network) |

---

## 1. Summary

freeside is a menu bar app for Apple Silicon Macs running macOS 27 or later that watches your drives. It does three things: it shows **free space** on mounted volumes, shows **live read/write speed** for each drive, and when a drive won't eject, it tells you **which process is holding it** and helps you let go.

The name is free space, plus Freeside, the orbital resort in *Neuromancer*. It follows flatline's rules: narrow scope, Apple Silicon only, no root, and close to zero cost when idle.

## 2. Background

"The disk wasn't ejected because one or more programs may be using it." macOS doesn't say which programs. The usual fix is `lsof` in Terminal, or quitting apps one at a time until the eject works. Anyone who offloads cards and moves projects between external drives every day runs into this constantly. The usual holders are a photo catalog (Lightroom, Capture One, Photos), Quick Look previews, a Terminal shell whose working directory is on the drive, Preview, a video app with media open, or Spotlight indexing.

Finder shows free space but not speed or blockers. Disk Utility and Activity Monitor show parts of it. Large suites like iStat Menus show space and I/O but not blockers. Eject utilities handle ejecting on sleep, not "why is this stuck." Nothing small puts all three together.

## 3. Goals

1. **One click to "why won't it eject?"** Name the process and the file, and offer a fix.
2. **Accurate space.** Free space matches Finder (see §9).
3. **Transfer speed at a glance.** See read/write rates during a card offload or project copy without opening Activity Monitor.
4. **Negligible footprint.** Event-driven when nothing is happening. With no external drives attached and the menu bar not showing space, freeside runs no timers of its own (see §7.3 for the exceptions and §8 for budgets).
5. **Steady menu bar, flatline look.** Fixed width, monospaced digits, monochrome, phosphor accent in the popover.
6. **Ships and updates itself.** Developer ID signed, notarized, Sparkle updates from freeside.banast.as.

## 4. Non-goals

- Drive health, SMART, temperatures
- Formatting, partitioning, repair (Disk Utility does this)
- Copy, verify, or offload with checksums (a possible separate app; see §13)
- I/O rates for network volumes (SMB, AFP, NFS); they show space only
- Ejecting on sleep or on a schedule
- Per-process disk I/O in 1.0 (see §13)
- Intel Macs, macOS earlier than 27, root privileges, privileged helpers, kernel extensions, private frameworks
- Mac App Store distribution or the sandbox

## 5. Users

- **Photographers and video editors** who offload cards and move projects between external SSDs and RAIDs every day.
- **Developers** with external build or cache drives and mounted disk images.

## 6. Functional requirements

### 6.1 Data sources

#### Volumes

| Value | Source | Notes |
|---|---|---|
| Mounted volumes | The kernel mount table (`getmntinfo_r_np` with `MNT_NOWAIT`), skipping `MNT_DONTBROWSE` mounts other than `/` | Rebuilt only on mount, unmount and rename events. Never polled. The same set as `FileManager.mountedVolumeURLs(…, .skipHiddenVolumes)` (a test checks this), but `MNT_NOWAIT` guarantees a dead share can't block it. |
| Mount / unmount / rename events | DiskArbitration `DARegisterDiskAppearedCallback`, `DARegisterDiskDisappearedCallback`, `DARegisterDiskDescriptionChangedCallback`, on a `DASession` set to the main queue | `NSWorkspace` mount notifications as a fallback |
| Name, format, icon | DA `kDADiskDescriptionVolumeNameKey` (the mount point's last component for network volumes); a short format name from the mount table's file system type ("APFS", "HFS+", "ExFAT", "SMB"); `NSWorkspace.icon(forFile:)` | Nothing here touches the file system, so listing never blocks on a dead share |
| Total | `volumeTotalCapacityKey` | |
| **Available** | `volumeAvailableCapacityForImportantUsageKey` | The number Finder shows. On APFS it includes purgeable space. When it is nil or 0, fall back to `volumeAvailableCapacityKey`, then `statfs`. SMB shares return 0, not nil (spike, §15). |
| Available (strict) | `volumeAvailableCapacityKey` | Shown in the popover only when it differs from Available by more than 1 GB |
| Kind | DA `kDADiskDescriptionDeviceInternalKey`, `kDADiskDescriptionMediaRemovableKey`, `kDADiskDescriptionDeviceProtocolKey` (USB, Thunderbolt, PCI-Express, SATA, Secure Digital); `volumeIsLocalKey` | Shown as e.g. "USB · APFS". See "What counts as external" below. |
| Disk images | DA `kDADiskDescriptionDeviceModelKey` = "Disk Image" | Identified first and grouped separately |

**What counts as external:** a local volume that is not a disk image is external if its device is not internal (`kDADiskDescriptionDeviceInternalKey` false) **or** its media is removable. The URL keys can't be used for this: fixed USB drives report `volumeIsEjectableKey` and `volumeIsRemovableKey` as false even though Finder ejects them (spike, §15). The removable-media half covers cards in a MacBook Pro's built-in SD slot, which may report an internal device; they must show up as external, get a device card, and be included in Eject All. Check this on a MacBook Pro in M1 (the development Mac, a Mac mini, has no SD slot).

The default list is external volumes, disk images, and the boot volume ("Macintosh HD"). Everything under `/System/Volumes`, Preboot, Recovery, VM and Time Machine local snapshots stay hidden.

Free space is refreshed on mount, every 30 s while it is visible, and on every I/O tick for a device that is writing. It only changes when something writes. Each refresh must bypass `URL`'s resource-value cache (`removeAllCachedResourceValues()` or a fresh `URL`); otherwise it keeps returning the first value read.

**Network volumes** can hang: reading anything from a share whose server has gone away can block for minutes. Their reads run off the main actor with a 2 s timeout. A volume that times out shows its last known value, marked stale, and is tried again on the next refresh. One dead share must never stall the UI or other volumes.

**Privacy prompts (checked in the spike, §15):** capacity resource keys, `statfs` and `NSWorkspace.icon(forFile:)` don't trigger the removable or network volume prompts. Listing a volume's contents does. So freeside must never list, open or read anything inside a volume; the same rule keeps it from becoming a holder (§6.1, Eject blockers).

#### Drive I/O

| Value | Source | Notes |
|---|---|---|
| Read / write bytes per second | IOKit `IOBlockStorageDriver` → `Statistics` dictionary (`Bytes (Read)`, `Bytes (Write)`), differenced between ticks | The same counters `iostat` reads. Shown in the units chosen in Settings (§6.6): decimal MB/s by default. |
| Volume → device | The volume's BSD name (from the mount table) → its `IOMedia` → walk every parent in the IOService plane to the `IOBlockStorageDriver`s above it, remembering the last whole-disk `IOMedia` passed. For APFS the walk goes through the container to the physical disk on its own. | I/O is per physical device. Volumes on one device share a rate, so the popover groups them under the device. The walk runs only when the volume list changes; each tick reads only the drivers' `Statistics`. |
| Multi-device volumes | An AppleRAID set: the walk finds one driver per member | Shown as one card for the set, with the members' rates summed and the members listed. Multi-store APFS (Fusion) can't be created on macOS 27 ("Fusion drives are deprecated"), so it isn't tested; the walk would handle it the same way. |
| Session totals | Bytes moved since freeside first saw the device | The IOKit counters run from attach, so freeside records a baseline when it first sees a device (at attach, or at launch if the device was already attached) |

Device statistics are read only for devices with a visible volume. Network volumes have no block device and show space only. If a device has no `Statistics` dictionary (some USB bridges), its rate shows "—", not 0.

**Disk images on external drives:** a mounted image's I/O also lands on the device that holds its backing file. The menu bar's combined rate sums physical external devices only, so image traffic isn't counted twice. The image's own card still shows its rate.

#### Eject blockers

| Value | Source | Notes |
|---|---|---|
| Processes using a volume | libproc, scanning only the current user's processes: `proc_listallpids` → `PROC_PIDT_SHORTBSDINFO` to skip other users' PIDs → working directory and open vnodes, matched by device ID (`vst_dev` against the volume's `st_dev`) rather than by path prefix | The same information as `lsof +f`. Skip vnodes opened `O_EVTONLY` (`fi_openflags`): FSEvents and kqueue watchers don't block unmount. `proc_listpidspath` gives the same PIDs but took 105–186 ms with ~780 processes; this scan took ~10 ms (spike, §15). |
| Which files | Per PID: `proc_pidinfo(PROC_PIDLISTFDS)` → `proc_pidfdinfo(PROC_PIDFDVNODEPATHINFO)` for open files; `proc_pidinfo(PROC_PIDVNODEPATHINFO)` for the working directory; the executable path (`proc_pidpath`) checked against the mount paths. Memory-mapped files only in a second pass, run when the first finds no process and no disk image: `PROC_PIDREGIONPATHINFO2` (22, private; `vmmap` and `lsof` use it), which returns only file-backed regions | Shown as "open file", "working directory", or "mapped file" (for example an app running from the drive). Measured in M3 with ~530 processes: first pass 20–30 ms; second pass 170–185 ms. Public `PROC_PIDREGIONPATHINFO` visits every region (~950,000) and took 1.4–2.2 s; `PROC_PIDREGIONPATHINFO3`, which filters by device in the kernel, returned `EINVAL` for every argument tried (2026-10-28). |
| Who it is | `NSRunningApplication(processIdentifier:)`. Otherwise walk parent PIDs (`PROC_PIDT_SHORTBSDINFO`) to the owning app, so a shell shows as Terminal. | Rows show the app's icon and name, not just a PID. A process that is itself an app or one of its helpers is offered **Quit** (quitting its app); a plain process under an app, such as a shell under Terminal, is offered **Terminate**, so stopping it doesn't quit every Terminal window. |
| Disk images mounted from the volume | Each attached image's backing-file path, checked against the volume's mount path. Two drivers serve images: `hdiutil attach` uses the older `IOHDIXHDDriveOutKernel` (`image-path`, bytes; verified in M3), and `diskutil image attach` uses DiskImages2's `AppleDiskImageDevice` (`DiskImageURL`, a file URL; found in M6, when `.dmg` files attached that way were missed). Which one Finder uses isn't checked, so both are read. | A mounted image blocks the eject, and its file is held open by the user's `diskimages-helper` (IOHDIX) or by `diskimagesiod`, which runs as a system user and so never shows up (DiskImages2). It gets its own row ("Project.sparsebundle is mounted from this drive") with **Eject image**, and the helper's open-file use of that file is dropped from the process rows: terminating the helper would damage the image. Disk-image drives are named after their file, since every image's device model is "Disk Image". |

A device scan covers every mounted volume on the device, not just the one the user clicked.

**freeside must never be a holder.** It keeps no file descriptors, working directory or mapped files on a watched volume, and reads icons and resource values without leaving anything open. Its own PID is not filtered out of results, so if it ever does hold a volume the bug is visible; a test checks that it never appears (§7.2).

**Limit:** without root, freeside can only inspect the current user's processes. Root-owned holders (Spotlight's `mds`, Time Machine's `backupd`) are invisible to it. If the scan finds no user processes but the eject still fails, freeside says a system process is holding the drive, names the likely ones, and offers Force Eject.

The scan runs only on demand (§7.3), never on the idle tick.

### 6.2 Ejecting

- Each device has an **Eject** button, and the popover's footer has **Eject All** for external devices. Ejecting a device unmounts all of its volumes, as Finder does, in this order:
  1. `DADiskUnmount` with `kDADiskUnmountOptionWhole` on each synthesized APFS container whose physical store is on the device.
  2. `DADiskUnmount` with `kDADiskUnmountOptionWhole` on the physical disk, for any non-APFS partitions.
  3. `DADiskEject` on the physical disk.

  Step 1 is required: unmounting the whole physical disk reports success but leaves the APFS volumes mounted, and the eject then fails as busy (spike, §15). Synthesized disks are found two ways: whole `IOMedia` below each physical disk in the registry (APFS containers), and the whole disk of each mounted volume (an AppleRAID set's disk, which isn't below its members). An AppleRAID set of two images ejects with both members (M3).
- A failed unmount can leave a device half unmounted: the volumes that weren't busy are already gone (spike, §15). The device card shows which volumes are still mounted, and **Retry** continues from there.
- **Eject All** ejects devices one at a time and keeps going after a failure. When it's done, the popover lists which devices ejected and opens the Blockers panel for the first one that didn't.
- Network volumes get an **Unmount** button (`DADiskUnmount` on the disk from `DADiskCreateFromVolumePath`). "Who's using this?" works on them the same way. Not yet tested on a real share: unmounting the development Mac's SMB shares would need them reconnected.
- If the unmount or eject fails as busy, freeside runs the blocker scan and opens the **Blockers** panel:
  - One row per process: icon, name, PID, reason, and the first path (expand to see all).
  - **Quit** for apps, using `NSRunningApplication.terminate()`, so the app can save and ask about unsaved work.
  - **Terminate** for other processes (`SIGTERM`), after a confirmation. `SIGKILL` needs a second confirmation.
  - **Retry**. freeside also retries on its own when the last listed process exits (`DispatchSource.makeProcessSource(eventMask: .exit)`).
  - **Force Eject** (`kDADiskUnmountOptionForce`), with a warning that open files may be lost or damaged.
- "Busy" means the dissenter status is `unix_err(EBUSY)` (`0x0000C010`), which is what DiskArbitration actually returns for a volume in use, or `kDAReturnBusy` (spike, §15).
- Other dissent statuses get a message on the device card instead of the Blockers panel:
  - `kDAReturnNotPermitted`: another app refused the unmount. Name it if the dissenter's status string does.
  - `kDAReturnExclusiveAccess`: a process has the device open exclusively (for example Disk Utility).
  - Anything else: shown with its status string, and logged for Copy Diagnostics (§6.8).
- **Who's using this?** is available from any volume's context menu without ejecting.

### 6.3 Menu bar

- A single `NSStatusItem`, monochrome in the menu bar's label color, fixed width.
- **Display styles**:
  - `icon`: a drive glyph
  - `space`: free space on one pinned volume, label stacked above value (`RAID` / `1.2T`). Long names are truncated to fit the reserved width (eight characters); the full name is in the tooltip and the VoiceOver label. If the pinned volume isn't mounted, the item shows `icon` until it returns (and `space+activity` shows `activity`).
  - `activity`: combined read/write rate across external devices, stacked (`R 412M` / `W 380M`), with an optional trace that goes flat when idle
  - `space+activity`
- **Show activity during transfers** (on by default): in `icon` or `space` style, the item switches to `activity` while a transfer runs (over 1 MB/s for 3 s) and switches back 10 s after it ends. The item's width is reserved for both, so nothing moves. The switched-to view is rates only, without the trace, so `icon` reserves 44 pt and `space` 48 pt, padding included (with the trace both took 76 pt, mostly empty while idle; changed in 0.2.1). As soon as a 5 s check sees more than 1 MB/s, sampling goes to every second to confirm it, so a transfer shows within about 3–8 s. Any I/O over the threshold counts, including Spotlight reading a large file just copied (M4).
- When any visible volume is below the low-space threshold, the glyph gets a `!` mark (`externaldrive.badge.exclamationmark`). No color. In `space` style, which has no glyph, the caption gets a `!` when the pinned volume is low (`RAID!`).
- Click opens the popover. Right-click or Control-click opens a small menu: Eject All, Open, Settings, Copy Diagnostics, Check for Updates, Quit. Settings opens the popover on its settings panel. Check for Updates arrives with Sparkle (M8).
- Optional: hide the item when no external drives are attached.
- VoiceOver reads a summary such as "2 external drives. RAID, 1.2 terabytes free, writing 380 megabytes per second."

### 6.4 Popover

A single scrolling panel about 340 pt wide, built with SwiftUI.

1. **Header**: as in flatline, the name on the left and two quiet lines on the right: the number of external drives and their total free space.
2. **One card per physical device**: model, interface (USB, Thunderbolt, internal), read and write rates with a 60-second trace (read above the baseline, write below, mirrored like flatline's network trace), session totals, and an Eject button. Under it, each volume on that device: name, format, a used/total bar, free space.
3. **Disk images**, grouped.
4. **Network volumes**, space only.
5. **Internal disk**, collapsed by default.
6. **Blockers panel**, inline, when an eject fails or "Who's using this?" is open. It sits inside the device's card (or under the network volume's row), so it's clear which drive it's about, and Eject All shows one in each card that failed and scrolls to the first. Its confirmations (Terminate, Kill, Force Eject) are inline too: a transient popover is a poor host for sheets. It rescans when the popover reopens, since the 2 s rescans stop while it's closed (M5).
7. **Footer**: settings gear, update indicator, **Eject All** (moved from the header so the header matches flatline's; just its symbol when an update notice needs the room, hidden in settings), Quit. The gear swaps the cards for the settings panel and back, as in flatline. When a Sparkle check has found a newer version, "update to X" takes the version number's place and opens Sparkle's window (M8).

Each card's ⋯ menu and each volume's context menu have Eject and "Who's Using This?". Device icons come from SF Symbols and the disk-image type icon, never `NSWorkspace.icon(forFile:)`, which reads the volume and could block on a dead share. "Free without purging" appears under a volume only when it differs from Available by more than 1 GB and reads differently at the displayed precision. The scroll view grows with its content up to the screen's height. Button labels are lowercase, as in flatline.

Popover views exist only while the popover is open.

**Empty state:** with no external drives, the header reads "No external drives" and the popover shows the remaining sections (disk images, network volumes, internal disk) as usual.

**Errors** appear inline on the card they belong to, never as modal alerts: an eject refused for a reason other than busy (§6.2), a network volume that timed out (stale value), a device with no I/O statistics, a failed update check (in the footer).

### 6.5 Notifications (opt-in)

- **Low space**: a volume crosses the low-space threshold. Once per crossing, with hysteresis so it doesn't repeat: it re-arms only when free space is 10 % above the threshold. A volume that is already low when first seen (at launch, on mount, or after the threshold changes) isn't a crossing. Only volumes in "Volumes shown" count. No sound.
- **Transfer finished**: write activity on a device drops to near zero after a sustained transfer of at least 1 GB. Useful when you walk away from a card offload, so it must fire while the display is asleep (§7.3). A write starts when an external drive's write rate goes over 1 MB/s and ends once it has stayed below for 10 s; the bytes written in between must reach 1 GB. Disk images are left out, since their writes also land on the drive holding the file. With a sound. Because idle checks run every 5 s, it arrives 10–15 s after the copy ends.

The low-space watch runs whether or not the notification is on, so turning it on doesn't announce volumes that were already low. Verified in M6 with `FREESIDE_LOG_NOTIFICATIONS=1`, which prints each notification as it's posted: a 200 MB image filled past 10 %, and a 2.1 GB write to a USB SSD (reported about 15 s after it ended). Not yet seen in Notification Center, since the debug build hasn't been granted permission.

**Display asleep (M6, 2026-10-28):** a 16.8 GB write to a USB SSD with the display put to sleep (`pmset displaysleepnow`) 7 s in. While it was off, the 5 s check kept running with the write open; App Nap didn't stretch it. The display came back on 11 s after the write ended, just before the 10 s quiet period was up, so the notification itself (16.8 GB in 20 s) was sent with the display on. A run that stays asleep throughout is still to do. The first attempt found a bug: the timer's first tick after starting had nothing to difference against and read 0, so a write that began within one tick of the timer starting went unseen, and with the display then asleep the timer stopped for good. The monitor now reads a baseline when the timer starts.

Both are off by default. Turning either on asks for notification permission (`UNUserNotificationCenter`); if it's denied, the setting says so and links to System Settings → Notifications. macOS already warns when a drive is unplugged without ejecting, so freeside doesn't.

### 6.6 Settings

Shown in the popover (an inline settings panel, as in flatline), stored in `UserDefaults`:

| Setting | Options | Default |
|---|---|---|
| Volumes shown | External, Disk images, Internal, Network (multi-select) | All four (Network added 2026-11-04: with it off, a mounted NAS looked missing rather than hidden) |
| Menu bar style | icon, space, activity, space+activity | icon |
| Pinned volume (for `space`) | any visible volume | first external, else the boot volume |
| Show activity during transfers | on / off | on |
| Activity trace (the graph beside the rates, in the `activity` and `space+activity` styles) | on / off | on |
| Units (space and rates) | decimal (GB, MB/s, like Finder), binary (GiB, MiB/s) | decimal |
| Low-space threshold | 5 %, 10 %, 20 %, or a fixed amount in GB | 10 % |
| Notifications | Low space, Transfer finished | off |
| Hide when no external drives | on / off | off |
| Accent color | phosphor green, cyan, magenta, amber, system | phosphor green |
| Launch at login | on / off (`SMAppService.mainApp`) | off, with a prompt on first run |
| Automatic updates | check automatically / download automatically | check automatically, daily (arrives with Sparkle in M8) |

### 6.7 Updates and website

Same setup as flatline:

- **Sparkle 2.10.0** (pinned) via Swift Package Manager, using `SPUStandardUpdaterController`. Checks daily without a first-run prompt (`SUEnableAutomaticChecks`); gentle reminders are on because freeside has no Dock icon. "Check for Updates…" is in the right-click menu, and the settings panel has check/download toggles and "check now".
- Appcast at `https://freeside.banast.as/appcast.xml`, served with `Cache-Control: no-cache`. Updates are the same notarized, stapled DMGs people download, under `/releases/` (cached as immutable).
- Updates are signed with **EdDSA (ed25519)**. The public key is in `Info.plist` (`SUPublicEDKey`); the private key was generated in M8 into the release Mac's login keychain under account `freeside`, separate from flatline's, and is **never committed**. Losing it means installed copies can't verify future updates, so keep an exported backup (`generate_keys --account freeside -x <file>`) in a password manager.
- `scripts/release.sh` copies each DMG and its notes into `releases/` (local, git-ignored: the archive of everything shipped) and runs `generate_appcast`, which signs the entries and rewrites `site/appcast.xml` (committed). Notes are the `CHANGELOG.md` section for the version, as HTML. The milestone history sits under "Development (M0–M9)" so it stays out of the notes.
- A small static site in `site/`, flatline's design with freeside's content: landing page, popover screenshot, menu bar strip, download button, requirements, release notes. `scripts/deploy-site.sh` fills in the version, size and notes, writes `_redirects` (`/download` → the newest DMG), and deploys the static-assets Worker in `wrangler.jsonc` with `freeside.banast.as` as its custom domain. The Apple touch icon and favicons are full-bleed versions of the app icon. `scripts/social-card.html`, laid out like flatline's, renders to `site/social.png` (1280×640, everything inside GitHub's 40 pt crop) for the page's `og:image` and the repo's social preview.

**End-to-end test (M8, 2026-10-28):** 0.1.0 (build 1) and 0.1.1 (build 2) were released and deployed; the site, feed (`no-cache`), `/download` redirect and DMG (checksum matching the local file) all checked live. A copy of 0.1.0 from the published DMG, with automatic downloads turned on and the last check backdated, checked 3 s after launch, downloaded and staged 0.1.1, and installed it within 3 s of quitting; the result was 0.1.1, accepted by Gatekeeper as Notarized Developer ID. `generate_appcast` also published an 11 KB delta, but Sparkle downloaded the full DMG; why isn't known yet. The domain's first lookups returned NXDOMAIN before the deploy created its record, and the local resolver kept that for Cloudflare's 30-minute negative TTL, so don't query a new domain before its first deploy.

### 6.8 Diagnostics

With no telemetry, bug reports depend on what users can send. **Copy Diagnostics** (in the right-click menu and the settings panel) copies a plain-text report to the clipboard: freeside and macOS versions, Mac model, the settings (naming no volume), the volume → device map with protocols, formats, BSD names and exact byte counts, the last 20 eject failures with their dissent statuses, and the last blocker scan's duration, process count and counts of holders and images. It contains no file paths: not from blocker scans, and not mount paths. `FREESIDE_DIAGNOSTICS=1` prints it and quits. It sends nothing; the user pastes it into a GitHub issue.

## 7. Technical design

### 7.1 Stack

- **Swift 6.4**, strict concurrency, Swift 6 language mode
- **SwiftUI** for all views; **AppKit** only for `NSStatusItem` / `NSPopover`
- **Observation** (`@Observable`) for the model
- **DiskArbitration**, **IOKit**, and **libproc** for data
- Deployment target **macOS 27.0**, **arm64 only**
- No third-party dependencies other than **Sparkle**

### 7.2 Project layout

```
freeside/
├── project.yml              # XcodeGen spec → Freeside.xcodeproj (generated, git-ignored)
├── Packages/
│   └── FreesideKit/         # Unit-tested with `swift test`
│       ├── Sources/FreesideKit/
│       │   ├── VolumeStore.swift     # DA session, mount events, volume list, space
│       │   ├── DeviceMap.swift       # volume → physical device, incl. APFS containers
│       │   ├── DriveMonitor.swift    # IOBlockStorageDriver statistics, rates, timer policy
│       │   ├── BlockerScanner.swift  # user-only libproc scan, disk-image rows
│       │   ├── Ejector.swift         # unmount, eject, force, retry on exit
│       │   ├── MenuBarModel.swift    # styles, transfer detection, low space, compact format
│       │   ├── Notifications.swift   # low-space crossings, finished writes
│       │   ├── Diagnostics.swift     # the Copy Diagnostics report
│       │   ├── RingBuffer.swift      # from flatline (see §12)
│       │   └── Format.swift          # from flatline
│       └── Tests/FreesideKitTests/
├── App/
│   ├── FreesideApp.swift
│   ├── Preferences.swift
│   ├── Notifier.swift       # UNUserNotificationCenter
│   ├── Updater.swift        # Sparkle, as in flatline, plus the footer's update indicator
│   ├── MenuBar/             # StatusItemController, MenuBarRenderer
│   ├── Popover/             # PopoverView, Cards, BlockersView, SettingsView, TraceView (from flatline)
│   └── Resources/
├── scripts/                 # release.sh, bump-version.sh, deploy-site.sh (adapted from flatline)
├── site/                    # freeside.banast.as: index.html, appcast.xml, _headers, screenshots
├── wrangler.jsonc           # the site's static-assets Worker
├── CHANGELOG.md
├── PRD.md
└── README.md
```

`BlockerScanner` tests open a file on a disk image created in the test (`hdiutil`), then check that the test process shows up with the right path and reason. They also check that freeside's own process never appears after it has listed volumes, refreshed space and loaded icons, and that an image mounted from the test image shows up as a disk-image row. `Ejector` tests use a disk image with several APFS volumes to check that ejecting the device unmounts all of them. Test images are attached with `diskutil image attach` (`hdiutil attach -nobrowse` is deprecated). APFS allows about one volume per 512 MiB of container, so a multi-volume test image needs to be a sparse image of a few GB.

### 7.3 Doing nothing when nothing happens

- **Volume list**: DiskArbitration callbacks only. No timer.
- **I/O tick**: a 1 s timer with 10 % leeway, running only while an external device is attached **and** either the popover is open or the menu bar is showing activity. Otherwise a 5 s check reads each device's counters once to detect a transfer starting. With no external devices, there is no timer.
- **Space**: every 30 s while shown (in the popover, or in the menu bar by the `space` style), plus on mount and during writes. Network volume reads run off the main actor with a timeout (§6.1).
- **Blocker scan**: only after a failed eject, on "Who's using this?", and every 2 s while the Blockers panel is open. It runs off the main actor. Measured in M3 with ~530 processes: 20–30 ms when something holds the drive; 170–185 ms when nothing does, because the mapped-file pass runs then (§6.1).
- While the screen is locked or the display is asleep, the 1 s tick stops. If a transfer is running, or a write hasn't yet been seen to end, the 5 s check keeps going so **Transfer finished** (§6.5) still fires when the user has walked away; otherwise it stops too, and counters are read once on wake. DiskArbitration callbacks keep working.
- **Timers with no external drives**: only the 30 s space refresh when the menu bar shows space for the boot or a network volume, and Sparkle's scheduled update check (daily by default). Nothing else.

### 7.4 Menu bar rendering

Same approach as flatline (its PRD §7.4): draw into one image per tick, put it in a `CALayer` inside the status button rather than `button.image`, use the menu bar's label color, and skip the redraw when nothing visible changed. The canvas and per-glyph text drawing are copied from flatline. The drive glyph is the SF Symbol rasterized once per appearance and scale. With no timer in `icon` style, appearance and backing-scale changes trigger their own redraws. `FREESIDE_SNAPSHOT=<file.png>` writes each rendered image, and the same image for the other menu bar appearance beside it (`-light` or `-dark`), for checking without a screen capture and for the README. The light rendering was first checked this way in M9. `FREESIDE_POPOVER=1` opens the popover at launch (`=internal` also expands the internal disk); a popover opened by a development hook stays open until closed in code, because an app launched from a shell can't activate itself and a transient popover would close at the first change of key window.

### 7.5 Security and distribution

- Hardened runtime on. Not sandboxed: inspecting other processes' open files needs it.
- Signed with **Developer ID Application (team `F87BNUZAVJ`)**, notarized with `notarytool`, ticket stapled.
- `scripts/release.sh` (from flatline) runs the FreesideKit tests, archives, exports for Developer ID, checks the signature (Developer ID, team, hardened runtime, secure timestamp, arm64 only), notarizes and staples the app, builds an APFS DMG with an Applications link, signs, notarizes and staples it, and checks both with Gatekeeper. `--skip-notarize` stops short of Apple. Notary credentials come from flatline's keychain profile, which holds the same team's credentials (`NOTARY_PROFILE` picks another). `scripts/bump-version.sh` sets the version and raises the build number. First run (M7, 2026-10-28): 0.1.0 (1), 760 KB, both submissions accepted, the app inside the mounted DMG accepted as "Notarized Developer ID". The app has no icon yet; one is needed before 1.0.
- Bundle ID `as.banast.freeside`. `LSUIElement = YES` (no Dock icon).
- freeside only quits or signals a process after the user clicks a button for that process. It never kills anything on its own.
- The only network request is Sparkle checking the appcast. No telemetry or analytics.

## 8. Performance budgets

Measured on an M-series Mac, popover closed:

| Metric | Budget |
|---|---|
| Average CPU, no external drives | ≈ 0 (no timers other than those listed in §7.3) |
| Idle wake-ups, no external drives, `icon` style | 0, apart from Sparkle's scheduled check |
| Average CPU, drive attached, idle | < 0.05 % of one core |
| Average CPU, during a transfer, 1 s tick | < 0.1 % of one core |
| Resident memory | < 50 MB after a week of use, with the popover opened (raised from 30 MB on 2026-11-04; see the memory note below) |
| Blocker scan | < 100 ms with 600 processes; never on the main thread. The mapped-file pass, which runs only when nothing else holds the drive, takes about 180 ms and is outside this budget (§6.1). |
| Popover open → first frame | < 100 ms (raised from 50 ms on 2026-11-04; see the note below) |

Checked before each release with Instruments and with a tick profiler: run the binary with `FREESIDE_PROFILE=1`, as with flatline. It prints average CPU per tick phase (counters, a11y, layout, render) every 60 ticks, and each popover opening's time to first frame; `FREESIDE_POPOVER=cycle` opens and closes the popover ten times (`cycle=<n>`, n times).

**Measured in M9 (2026-10-28, Mac mini M2 Pro, Release build, three USB drives):**

| Metric | Result | Notes |
|---|---|---|
| Average CPU, 1 s tick (Activity style) | 0.13 % | Over 5 min, with a steady ~5 MB/s write to an external drive from another app |
| Average CPU, Icon style | 0.12 % | The same 5 min; the external write kept it on the 1 s tick too, so the idle case (5 s check, budget 0.05 %) is still to measure with the drives quiet |
| Resident memory | 14–16 MB at launch; 48 MB after 7 days | `top`'s memory footprint. No leak; see the note below |
| Blocker scan | 27 ms, 666 processes | `scanCost` test; mapped-file pass 204 ms |
| Popover open → first frame | 58–80 ms warm, 117–157 ms the first time; 64–77 ms warm on 2026-11-04 | Load average 9–11, then about 4. See the note below |
| No external drives | not measured | Needs every external drive unplugged; skipped for 1.0 (2026-11-04). The code starts no timer without an external device (§7.3) |

The first measurement was 0.57 % and 1.8 %. The causes, all fixed: every sample that saw any write (the internal disk writes a little all the time) re-read that volume's space with `volumeAvailableCapacityForImportantUsageKey`, which makes macOS work out purgeable space (~11 ms of CPU on the boot volume, ~3 ms on an external APFS drive, plus work in `cache_delete`); each space change re-mapped every volume to its drive through IOKit; an unchanged space value still woke every observer; and the status item watched the whole drive list, so it redrew ~3.7 times per tick. Now space is re-read only for a drive writing over 1 MB/s, with plain capacity keys (0.2 ms / 9 µs) and Finder's figure estimated from the last full read; the full read follows a write only while space is on screen; while it isn't, a writing drive's space is followed every 5 s; `remap` runs only when the volumes themselves change; and the status item watches a `hasExternal` flag. Each card's ⋯ menu is a plain button that builds an `NSMenu` when clicked: a SwiftUI `Menu` cost ~4 ms per card on every opening.

**Memory after a week (2026-11-04).** The installed 0.2.0 had a 48 MB footprint after 6 days 17 hours of use (flatline, which shares the menu bar code: 44.5 MB after 8½ days). `leaks` found 15 KB. The growth is in system frameworks, and both parts level off:

- **First popover opening: about +16 MB, once.** SwiftUI, Metal and font machinery loading for the first time, plus freed malloc pages that stay with the process. Footprint after 10, 40, 80 and 160 openings (`FREESIDE_POPOVER=cycle=<n>`, Release build): 30, 31, 32, 33 MB; memory in use after 160 openings (9.6 MB) was lower than after 40 (13.0 MB). `malloc_zone_pressure_relief` after closing returned nothing, because the free memory is spread across pages still in use.
- **ColorSync tables: up to about 11 MB.** 272 KB conversion tables, 21 at launch and 78 after the week. AppKit builds one set when a window works out its colour gamut (`NSWindow _setColorSpace` → `colorGamut`), and Core Graphics another when it colour-matches an image, for each new pair of colour spaces; a display profile changing over the day adds pairs. Both caches have limits: 45 and 90 tables however many colour spaces were used (tested up to 400), about 3.4 MB and 7.5 MB of footprint.

So steady-state memory is about 30–45 MB, almost all of it system frameworks. The original 30 MB budget was set before the popover existed; it is now 50 MB, since getting under 30 MB would mean replacing the SwiftUI popover with AppKit.

**Popover opening (2026-11-04).** Each opening takes about 60 ms of main-thread work: building the popover's window and hosting view (~11 ms, most of it the `ScrollView` sizing its content), AppKit's layout and commit (~9 ms), and text layout (~8 ms). Three changes were tried, timed with `FREESIDE_PROFILE=1 FREESIDE_POPOVER=cycle=<n>` and CPU time per opening (wall-clock was noisy, load average 4–39):

- Keeping the last content height between openings, to skip a layout pass: no change (108 ms CPU per opening, open and close, before and after).
- Keeping the popover and its window between openings, with the content dropped while closed so a closed popover observes nothing: first frame 25–35 ms, 74–82 ms CPU per opening, closed CPU unchanged. But the hidden window keeps its backing store, 3–11 MB depending on the menu bar style, which would take a week's footprint over the 50 MB budget. Shrinking the window on close freed 4 MB but brought the opening back to ~54 ms.
- Keeping only the hosting controller, with a new popover each time: ~60 ms.

About 70 ms from click to popover isn't noticeably slow, and memory matters more for an app that's always running, so the budget is 100 ms and the popover is still built per opening. The kept-window version is the change to make if opening speed matters more later.

## 9. Accuracy acceptance criteria

| Metric | Reference | Tolerance |
|---|---|---|
| Available space | Finder Get Info "Available" for local volumes; `df` for network volumes | Exact at Finder's displayed precision. On SMB shares Finder reported 1.5 GB and 13.7 GB more than `df`, `statfs`, `getattrlist` and the URL keys, which all agree; Finder's figure didn't change on refresh, so it's probably cached, but that isn't confirmed (M1, 2026-10-28). |
| Total capacity | Finder Get Info | Exact |
| Read / write rates | `iostat -d -w 1 diskN` | ± 5 % over a sustained 30 s copy, after converting units: iostat's "MB" is MiB (1,048,576 bytes), about 4.9 % larger than a decimal MB. Measured in M2 on a USB SSD at about 820 MB/s: +0.59 % over 24.6 GB; a disk image on that drive +0.54 %, with the combined external rate equal to the drive alone (2026-10-28). |
| Blocker list | `lsof +f -- /Volumes/X`, run as the same user | Same set of PIDs, plus a row for each disk image mounted from the volume, minus `diskimages-helper` holding that image's file. freeside itself never appears. Matched on a test image with a working directory, an open file and an attached image (M3, 2026-10-28). |
| Eject | Finder | Succeeds whenever Finder's eject succeeds |
| Mount / unmount | — | Shown in the popover within 1 s |

### 9.1 Test hardware

Every row above is checked on each of these before 1.0:

| Kind | Why |
|---|---|
| USB-C SSD, APFS, several volumes | The common case; APFS container mapping |
| DMG and sparsebundle stored on an external drive | Image grouping, double counting, image-as-blocker |
| SMB share, including one whose server goes away | Space only, timeouts, stale values |

Not available for 1.0 and checked after it, from user reports or when the hardware is to hand (2026-11-04): Thunderbolt hardware RAID and AppleRAID sets (multi-device mapping and ejecting; covered so far by tests that stripe two disk images into an AppleRAID set), a built-in SD slot, a USB card reader with and without a card, a FAT32 stick and a spinning HFS+ drive.

## 10. Accessibility and localization

- VoiceOver labels on the status item and on every popover value; usage bars also have their numbers as text
- The popover respects Reduce Motion and Increase Contrast
- Color is never the only signal: low space has a `!` mark and a text label
- English only for 1.0, with all strings in a String Catalog

## 11. Milestones

| # | Milestone | Done when |
|---|---|---|
| M0 | Scaffold | XcodeGen project builds an empty menu bar app; `swift test` runs |
| M1 | Volumes | DA session, volume list and space match §9; SD slot classified as external (on a MacBook Pro); network reads time out |
| M2 | I/O | Volume → device mapping works for APFS, HFS+, exFAT, AppleRAID and disk images; image I/O not counted twice; rates match §9 |
| M3 | Eject + blockers | Eject (including APFS containers and Eject All with failures), blocker scan with disk-image rows, Quit / Terminate / Retry / Force Eject, messages for other dissent statuses; scan cost measured |
| M4 | Menu bar | All styles, transfer auto-switch, fixed width |
| M5 | Popover | Device cards with traces, volume rows, Blockers panel |
| M6 | Settings, notifications, diagnostics | All §6.6 settings persist; both notifications work, Transfer finished with the display asleep; Copy Diagnostics works |
| M7 | Distribution | `scripts/release.sh` produces a signed, notarized, stapled DMG |
| M8 | Updates + site | Sparkle wired up; site deployed with appcast; an update tested end to end |
| M9 | 1.0 | §8 budgets verified; §9 criteria verified on the §9.1 hardware; README screenshots; tagged release |

**M9 progress (2026-11-04):** the tick profiler is in, and the first §8 measurements found and fixed a CPU problem (§8). App icon, README and site screenshots are done. A week of use averaged 0.04 % CPU; memory and popover budgets were revised after measurement (§8). §9.1 is narrowed to the hardware at hand; the USB SSD, HFS+, disk image and sparsebundle checks pass, including ejecting the HFS+ T9 from the popover and plugging it back in. SMB server powered off with the share mounted (2026-11-04): the installed app's main thread stayed idle in every sample, a fresh read timed out instead of hanging, macOS went on returning the share's cached figures for about a minute, then unmounted it and freeside dropped it from the list. A VoiceOver pass is deferred to after 1.0 (2026-11-04); the menu bar item and the popover's controls have accessibility labels. 1.0.0 released, deployed and tagged on 2026-11-04.

## 12. Decisions

| Question | Decision |
|---|---|
| Name | **freeside** (2026-10-25) |
| Signing | Same Developer ID team as flatline (`F87BNUZAVJ`), notarized with `notarytool` (2026-10-25) |
| Hosting | **Cloudflare Pages** at freeside.banast.as, same as flatline (2026-10-25) |
| License | **MIT** (2026-10-25) |
| Menu bar colors | **Monochrome**, for the same reason as flatline (2026-10-25) |
| Shared code with flatline | **Copy** `RingBuffer`, `Format`, the menu bar rendering approach and the release scripts (about 110 lines of Swift plus scripts). A shared package isn't worth versioning across repos for that much code (2026-10-28) |

## 13. Open questions

1. **Catching Finder's failed ejects**: DiskArbitration's unmount approval callback sees every unmount request, including Finder's. freeside could notice when a volume is still mounted a couple of seconds after a request and offer its Blockers panel. Useful, but it reacts to other apps' actions. A registered approval callback also puts freeside in the path of every unmount on the system, so a hang or crash in it could delay other apps' ejects; only observing (watching for a disappeared callback that never arrives) would be safer, if DiskArbitration exposes enough to do it. Worth it for 1.0?
2. **Spotlight as the holder**: when Spotlight is likely the cause, link to System Settings → Spotlight so the user can exclude the drive? Turning indexing off directly (`mdutil -i off`) needs admin rights.
3. **Per-process disk I/O**: `proc_pid_rusage` gives disk bytes for the user's own processes, so the device card could show "Lightroom writing 180 MB/s". Add after 1.0?
4. **Offload with verification**: copying cards with checksums is the natural next step, but it's a different app. Keep it out of freeside.
5. **Repo visibility**: private until 1.0, or public from the start?

## 14. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Reading capacity triggers the removable or network volume privacy prompt | A permission prompt from an app that only shows numbers | Checked in the spike (§15): capacity reads, `statfs` and icons do not prompt. Re-check on each macOS beta. |
| DiskArbitration ejects differently from Finder (APFS containers, other apps' dissent) | Ejects that work in Finder fail in freeside | §6.2 handling; compared against Finder on the §9.1 hardware |
| A future macOS restricts libproc file-descriptor info, even for the user's own processes | The blocker scan loses file paths or PIDs | Degrade to the PID list, or to "something is holding this drive" with Force Eject. Test each macOS beta. |
| `PROC_PIDREGIONPATHINFO2` is private and could change | Mapped files (an app running from the drive is still found by its executable path) stop showing | The pass stops at the first failed call and reports nothing; a test covers a mapped file with no descriptor. Test each macOS beta. |
| IOKit `Statistics` keys change or are missing for some devices | Rates disappear or are wrong | Show "—" rather than 0 (§6.1); covered by the §9.1 hardware |
| A hung network share blocks a thread | Stale UI, or worse, a stuck main actor | Off-main reads with a timeout (§6.1) |

## 15. Appendix: spike results (2026-10-28)

Throwaway tests run before M0 on a Mac mini (Mac14,12), macOS 27.2, with two USB drives, a USB removable drive, two SMB shares, about 780 processes, and APFS test images. The code is not kept.

| Question | Result | Changed in the PRD |
|---|---|---|
| Do capacity reads trigger the removable or network volume privacy prompt? | No. Capacity resource keys, `statfs` and `NSWorkspace.icon(forFile:)` returned at once for every volume, from a fresh ad-hoc signed app. Listing a volume's contents from the same app did trigger the prompt. | §6.1: freeside never reads inside a volume |
| What do the URL keys say about external drives? | Fixed USB drives: internal false, ejectable false, removable false. A removable USB drive: ejectable and removable true. SMB: important-usage capacity 0. | §6.1: "external" from DiskArbitration, not URL keys; treat 0 as missing |
| Does a libproc scan find holders without root? | Yes. An open file and a working directory on a test image were both found, the same PIDs as `lsof +f`. | — |
| How fast is it? | `proc_listpidspath`: 105–186 ms. A scan of only the user's processes, matching by device ID: 9–15 ms. | §6.1: use the user-only scan |
| Does unmounting the whole physical disk unmount its APFS volumes? | No. It reports success, the APFS volumes stay mounted, and the eject then fails as busy. Unmounting the synthesized container first, then ejecting the physical disk, works. | §6.2: eject order |
| What does "busy" look like? | Dissent status `0x0000C010`, `unix_err(EBUSY)`, not `kDAReturnBusy`. | §6.2 |
| What happens when one APFS volume is busy? | The container unmount fails, but the other volume has already been unmounted. | §6.2: half-unmounted devices |
| Built-in SD slot | Not tested: the Mac mini has none. | Still open for M1 |
