# freeside: Product Requirements

| | |
|---|---|
| **Status** | Draft v0.3: building (M4 done; M1's SD slot check pending) |
| **Owner** | Bill Anastas |
| **Last updated** | 2026-10-28 |
| **Repo** | [banastas/freeside](https://github.com/banastas/freeside) |
| **Site / updates** | https://freeside.banast.as |
| **Siblings** | [flatline](https://github.com/banastas/flatline) (CPU, memory, network), straylight (network quality) |

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
| Disk images mounted from the volume | Each attached image's backing-file path (`image-path`, bytes, on the image's `IOHDIXHDDriveOutKernel`; verified in M3), checked against the volume's mount path | A mounted image blocks the eject, and its file is held open by the user's `diskimages-helper`. It gets its own row ("Project.sparsebundle is mounted from this drive") with **Eject image**, and the helper's open-file use of that file is dropped from the process rows: terminating the helper would damage the image. Disk-image drives are named after their file, since every image's device model is "Disk Image". |

A device scan covers every mounted volume on the device, not just the one the user clicked.

**freeside must never be a holder.** It keeps no file descriptors, working directory or mapped files on a watched volume, and reads icons and resource values without leaving anything open. Its own PID is not filtered out of results, so if it ever does hold a volume the bug is visible; a test checks that it never appears (§7.2).

**Limit:** without root, freeside can only inspect the current user's processes. Root-owned holders (Spotlight's `mds`, Time Machine's `backupd`) are invisible to it. If the scan finds no user processes but the eject still fails, freeside says a system process is holding the drive, names the likely ones, and offers Force Eject.

The scan runs only on demand (§7.3), never on the idle tick.

### 6.2 Ejecting

- Each device has an **Eject** button, and the header has **Eject All** for external devices. Ejecting a device unmounts all of its volumes, as Finder does, in this order:
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
- **Show activity during transfers** (on by default): in `icon` or `space` style, the item switches to `activity` while a transfer runs (over 1 MB/s for 3 s) and switches back 10 s after it ends. The item's width is reserved for both, so nothing moves: with the trace on, `icon` reserves about 68 pt. As soon as a 5 s check sees more than 1 MB/s, sampling goes to every second to confirm it, so a transfer shows within about 3–8 s. Any I/O over the threshold counts, including Spotlight reading a large file just copied (M4).
- When any visible volume is below the low-space threshold, the glyph gets a `!` mark (`externaldrive.badge.exclamationmark`). No color. In `space` style, which has no glyph, the caption gets a `!` when the pinned volume is low (`RAID!`).
- Click opens the popover. Right-click or Control-click opens a small menu: Eject All, Open, Settings, Copy Diagnostics, Check for Updates, Quit. Until the settings panel (M6), the menu bar settings are a submenu here; Copy Diagnostics and Check for Updates arrive in M6 and M8.
- Optional: hide the item when no external drives are attached.
- VoiceOver reads a summary such as "2 external drives. RAID, 1.2 terabytes free, writing 380 megabytes per second."

### 6.4 Popover

A single scrolling panel about 340 pt wide, built with SwiftUI.

1. **Header**: number of external drives and **Eject All**.
2. **One card per physical device**: model, interface (USB, Thunderbolt, internal), read and write rates with a 60-second trace (read above the baseline, write below, mirrored like flatline's network trace), session totals, and an Eject button. Under it, each volume on that device: name, format, a used/total bar, free space.
3. **Disk images**, grouped.
4. **Network volumes**, space only.
5. **Internal disk**, collapsed by default.
6. **Blockers panel**, inline, when an eject fails or "Who's using this?" is open.
7. **Footer**: settings gear, update indicator, Quit.

Popover views exist only while the popover is open.

**Empty state:** with no external drives, the header reads "No external drives" and the popover shows the remaining sections (disk images, network volumes, internal disk) as usual.

**Errors** appear inline on the card they belong to, never as modal alerts: an eject refused for a reason other than busy (§6.2), a network volume that timed out (stale value), a device with no I/O statistics, a failed update check (in the footer).

### 6.5 Notifications (opt-in)

- **Low space**: a volume crosses the low-space threshold. Once per crossing, with hysteresis so it doesn't repeat.
- **Transfer finished**: write activity on a device drops to near zero after a sustained transfer of at least 1 GB. Useful when you walk away from a card offload, so it must fire while the display is asleep (§7.3).

Both are off by default. Turning either on asks for notification permission (`UNUserNotificationCenter`); if it's denied, the setting says so and links to System Settings → Notifications. macOS already warns when a drive is unplugged without ejecting, so freeside doesn't.

### 6.6 Settings

Shown in the popover (an inline settings panel, as in flatline), stored in `UserDefaults`:

| Setting | Options | Default |
|---|---|---|
| Volumes shown | External, Disk images, Internal, Network (multi-select) | External, Disk images, Internal |
| Menu bar style | icon, space, activity, space+activity | icon |
| Pinned volume (for `space`) | any visible volume | first external, else the boot volume |
| Show activity during transfers | on / off | on |
| Activity trace (the graph beside the rates) | on / off | on |
| Units (space and rates) | decimal (GB, MB/s, like Finder), binary (GiB, MiB/s) | decimal |
| Low-space threshold | 5 %, 10 %, 20 %, or a fixed amount in GB | 10 % |
| Notifications | Low space, Transfer finished | off |
| Hide when no external drives | on / off | off |
| Accent color | phosphor green, cyan, magenta, amber, system | phosphor green |
| Launch at login | on / off (`SMAppService.mainApp`) | off, with a prompt on first run |
| Automatic updates | check automatically / download automatically | check automatically, daily |

### 6.7 Updates and website

Same setup as flatline:

- **Sparkle 2** via Swift Package Manager. Appcast at `https://freeside.banast.as/appcast.xml`, EdDSA-signed updates, notarized DMGs under `/releases/`, appcast generated by the release script with notes from `CHANGELOG.md`.
- A small static site in `site/`: landing page, screenshot, download button, requirements, release notes.

### 6.8 Diagnostics

With no telemetry, bug reports depend on what users can send. **Copy Diagnostics** (in the right-click menu and the settings panel) copies a plain-text report to the clipboard: freeside and macOS versions, Mac model, the volume → device map with protocols and formats, recent DiskArbitration errors and dissent statuses, and the last blocker scan's duration and process count. It contains no file paths from blocker scans. It sends nothing; the user pastes it into a GitHub issue.

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
│       │   ├── RingBuffer.swift      # from flatline (see §12)
│       │   └── Format.swift          # from flatline
│       └── Tests/FreesideKitTests/
├── App/
│   ├── FreesideApp.swift
│   ├── Preferences.swift
│   ├── MenuBar/             # StatusItemController, MenuBarRenderer
│   ├── Blockers/…           # Blockers panel; moves into the popover in M5
│   ├── Popover/…
│   ├── Settings/…
│   └── Resources/
├── scripts/                 # release.sh, bump-version.sh (adapted from flatline)
├── site/                    # freeside.banast.as
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
- While the screen is locked or the display is asleep, the 1 s tick stops. If a transfer is running, the 5 s check keeps going so **Transfer finished** (§6.5) still fires when the user has walked away; otherwise it stops too, and counters are read once on wake. DiskArbitration callbacks keep working.
- **Timers with no external drives**: only the 30 s space refresh when the menu bar shows space for the boot or a network volume, and Sparkle's scheduled update check (daily by default). Nothing else.

### 7.4 Menu bar rendering

Same approach as flatline (its PRD §7.4): draw into one image per tick, put it in a `CALayer` inside the status button rather than `button.image`, use the menu bar's label color, and skip the redraw when nothing visible changed. The canvas and per-glyph text drawing are copied from flatline. The drive glyph is the SF Symbol rasterized once per appearance and scale. With no timer in `icon` style, appearance and backing-scale changes trigger their own redraws. `FREESIDE_SNAPSHOT=<file.png>` writes each rendered image, for checking without a screen capture.

### 7.5 Security and distribution

- Hardened runtime on. Not sandboxed: inspecting other processes' open files needs it.
- Signed with **Developer ID Application (team `F87BNUZAVJ`)**, notarized with `notarytool`, ticket stapled.
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
| Resident memory | < 30 MB |
| Blocker scan | < 100 ms with 600 processes; never on the main thread. The mapped-file pass, which runs only when nothing else holds the drive, takes about 180 ms and is outside this budget (§6.1). |
| Popover open → first frame | < 50 ms |

Checked before each release with Instruments and with a tick profiler: run the binary with `FREESIDE_PROFILE=1`, as with flatline.

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
| Thunderbolt enclosure, hardware RAID | One device, high rates |
| AppleRAID set (two drives) | Multi-device mapping |
| Built-in SD card slot, exFAT card | Internal flag on removable media |
| USB card reader, empty and with a card | Device with no media |
| USB stick, FAT32; spinning drive, HFS+ | Older formats, slow devices |
| DMG and sparsebundle stored on an external drive | Image grouping, double counting, image-as-blocker |
| SMB share, including one whose server goes away | Space only, timeouts, stale values |

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

## 12. Decisions

| Question | Decision |
|---|---|
| Name | **freeside** (2026-10-25) |
| Signing | Same Developer ID team as flatline (`F87BNUZAVJ`), notarized with `notarytool` (2026-10-25) |
| Hosting | **Cloudflare Pages** at freeside.banast.as, same as flatline (2026-10-25) |
| License | **MIT** (2026-10-25) |
| Menu bar colors | **Monochrome**, for the same reason as flatline (2026-10-25) |
| Shared code with flatline | **Copy** `RingBuffer`, `Format`, the menu bar rendering approach and the release scripts (about 110 lines of Swift plus scripts). A shared package (working name `sprawl`) isn't worth versioning across three repos for that much code; revisit when straylight is built (2026-10-28) |

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
