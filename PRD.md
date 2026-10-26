# freeside: Product Requirements

| | |
|---|---|
| **Status** | Draft v0.1: not started |
| **Owner** | Bill Anastas |
| **Last updated** | 2026-10-25 |
| **Repo** | banastas/freeside (not created yet) |
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
4. **Negligible footprint.** Event-driven when nothing is happening. With no external drives attached, freeside runs no timers at all (see §8).
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
| Mounted volumes | `FileManager.mountedVolumeURLs(includingResourceValuesForKeys:options: .skipHiddenVolumes)` | Rebuilt only on mount, unmount and rename events. Never polled. |
| Mount / unmount / rename events | DiskArbitration `DARegisterDiskAppearedCallback`, `DARegisterDiskDisappearedCallback`, `DARegisterDiskDescriptionChangedCallback`, on a `DASession` set to the main queue | `NSWorkspace` mount notifications as a fallback |
| Name, format, icon | `volumeLocalizedNameKey`, `volumeLocalizedFormatDescriptionKey`, `NSWorkspace.icon(forFile:)` | |
| Total | `volumeTotalCapacityKey` | |
| **Available** | `volumeAvailableCapacityForImportantUsageKey` | The number Finder shows. On APFS it includes purgeable space. |
| Available (strict) | `volumeAvailableCapacityKey` | Shown in the popover only when it differs from Available by more than 1 GB |
| Kind | `volumeIsInternalKey`, `volumeIsEjectableKey`, `volumeIsLocalKey`; DA `kDADiskDescriptionDeviceProtocolKey` (USB, Thunderbolt, PCI-Express, SATA) | Shown as e.g. "USB · APFS" |
| Disk images | DA `kDADiskDescriptionDeviceModelKey` = "Disk Image" | Grouped separately |

The default list is external volumes, disk images, and the boot volume ("Macintosh HD"). Everything under `/System/Volumes`, Preboot, Recovery, VM and Time Machine local snapshots stay hidden.

Free space is refreshed on mount, every 30 s while it is visible, and on every I/O tick for a device that is writing. It only changes when something writes.

**Permissions check (M1):** reading capacity must not trigger the "access files on a removable volume" privacy prompt. If the URL resource keys trigger it, fall back to `statfs` (`f_bavail × f_bsize`) and accept that purgeable space can't be reported.

#### Drive I/O

| Value | Source | Notes |
|---|---|---|
| Read / write bytes per second | IOKit `IOBlockStorageDriver` → `Statistics` dictionary (`Bytes (Read)`, `Bytes (Write)`), differenced between ticks | The same counters `iostat` reads |
| Volume → device | `DADiskCreateFromVolumePath` → BSD name → `IOMedia` → walk up to its `IOBlockStorageDriver`. For APFS, follow the synthesized container to its physical store. | I/O is per physical device. Volumes on one device share a rate, so the popover groups them under the device. |
| Session totals | Sum since the device was attached | |

Device statistics are read only for devices with a visible volume. Network volumes have no block device and show space only.

#### Eject blockers

| Value | Source | Notes |
|---|---|---|
| Processes using a volume | libproc `proc_listpidspath(PROC_ALL_PIDS, 0, mountPath, PROC_LISTPIDSPATH_PATH_IS_VOLUME \| PROC_LISTPIDSPATH_EXCLUDE_EVTONLY, …)` | The same mechanism as `lsof +f`. Excluding event-only vnodes skips FSEvents watchers, which don't block unmount. |
| Which files | Per PID: `proc_pidinfo(PROC_PIDLISTFDS)` → `proc_pidfdinfo(PROC_PIDFDVNODEPATHINFO)` for open files; `proc_pidinfo(PROC_PIDVNODEPATHINFO)` for the working directory; `PROC_PIDREGIONPATHINFO` for memory-mapped files | Shown as "open file", "working directory", or "mapped file" (for example an app running from the drive) |
| Who it is | `NSRunningApplication(processIdentifier:)`. Otherwise walk parent PIDs (`PROC_PIDTBSDINFO`) to the owning app, so a shell shows as Terminal. | Rows show the app's icon and name, not just a PID |

**Limit:** without root, freeside can only inspect the current user's processes. Root-owned holders (Spotlight's `mds`, Time Machine's `backupd`) are invisible to it. If the scan finds no user processes but the eject still fails, freeside says a system process is holding the drive, names the likely ones, and offers Force Eject.

The scan runs only on demand (§7.3), never on the idle tick.

### 6.2 Ejecting

- Each device has an **Eject** button, and the header has **Eject All** for external devices. Ejecting a device unmounts all of its volumes, as Finder does: DiskArbitration `DADiskUnmount` on the whole disk with `kDADiskUnmountOptionWhole`, then `DADiskEject`.
- If the unmount fails as busy (`kDAReturnBusy` from the dissenter), freeside runs the blocker scan and opens the **Blockers** panel:
  - One row per process: icon, name, PID, reason, and the first path (expand to see all).
  - **Quit** for apps, using `NSRunningApplication.terminate()`, so the app can save and ask about unsaved work.
  - **Terminate** for other processes (`SIGTERM`), after a confirmation. `SIGKILL` needs a second confirmation.
  - **Retry**. freeside also retries on its own when the last listed process exits (`DispatchSource.makeProcessSource(eventMask: .exit)`).
  - **Force Eject** (`kDADiskUnmountOptionForce`), with a warning that open files may be lost or damaged.
- **Who's using this?** is available from any volume's context menu without ejecting.

### 6.3 Menu bar

- A single `NSStatusItem`, monochrome in the menu bar's label color, fixed width.
- **Display styles**:
  - `icon`: a drive glyph
  - `space`: free space on one pinned volume, label stacked above value (`RAID` / `1.2T`)
  - `activity`: combined read/write rate across external devices, stacked (`R 412M` / `W 380M`), with an optional trace that goes flat when idle
  - `space+activity`
- **Show activity during transfers** (on by default): in `icon` or `space` style, the item switches to `activity` while a transfer runs (over 1 MB/s for 3 s) and switches back 10 s after it ends. The item's width is reserved for both, so nothing moves.
- When any visible volume is below the low-space threshold, the glyph gets a `!` mark. No color.
- Click opens the popover. Right-click or Control-click opens a small menu: Eject All, Open, Settings, Check for Updates, Quit.
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

### 6.5 Notifications (opt-in)

- **Low space**: a volume crosses the low-space threshold. Once per crossing, with hysteresis so it doesn't repeat.
- **Transfer finished**: write activity on a device drops to near zero after a sustained transfer of at least 1 GB. Useful when you walk away from a card offload.

Both are off by default. macOS already warns when a drive is unplugged without ejecting, so freeside doesn't.

### 6.6 Settings

Shown in the popover (an inline settings panel, as in flatline), stored in `UserDefaults`:

| Setting | Options | Default |
|---|---|---|
| Volumes shown | External, Disk images, Internal, Network (multi-select) | External, Disk images, Internal |
| Menu bar style | icon, space, activity, space+activity | icon |
| Pinned volume (for `space`) | any visible volume | first external |
| Show activity during transfers | on / off | on |
| Space units | decimal (GB, like Finder), binary (GiB) | decimal |
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
│       │   ├── IOSampler.swift       # IOBlockStorageDriver statistics
│       │   ├── BlockerScanner.swift  # proc_listpidspath + per-PID detail
│       │   ├── Ejector.swift         # unmount, eject, force, retry on exit
│       │   ├── RingBuffer.swift      # from flatline (see §13)
│       │   └── Format.swift          # from flatline
│       └── Tests/FreesideKitTests/
├── App/
│   ├── FreesideApp.swift
│   ├── StatusItemController.swift
│   ├── MenuBarRenderer.swift
│   ├── Popover/…
│   ├── Settings/…
│   └── Resources/
├── scripts/                 # release.sh, bump-version.sh (adapted from flatline)
├── site/                    # freeside.banast.as
├── CHANGELOG.md
├── PRD.md
└── README.md
```

`BlockerScanner` tests open a file on a disk image created in the test (`hdiutil`), then check that the test process shows up with the right path and reason.

### 7.3 Doing nothing when nothing happens

- **Volume list**: DiskArbitration callbacks only. No timer.
- **I/O tick**: a 1 s timer with 10 % leeway, running only while an external device is attached **and** either the popover is open or the menu bar is showing activity. Otherwise a 5 s check reads each device's counters once to detect a transfer starting. With no external devices, there is no timer.
- **Space**: every 30 s while shown, plus on mount and during writes.
- **Blocker scan**: only after a failed eject, on "Who's using this?", and every 2 s while the Blockers panel is open. It runs off the main actor. Measure its cost in M3; the target is under 100 ms with 600 processes running.
- While the screen is locked or the display is asleep, the I/O tick stops. DiskArbitration callbacks keep working.

### 7.4 Menu bar rendering

Same approach as flatline (its PRD §7.4): draw into one image per tick, put it in a `CALayer` inside the status button rather than `button.image`, use the menu bar's label color, and skip the redraw when nothing visible changed.

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
| Average CPU, no external drives | ≈ 0 (no timers) |
| Idle wake-ups, no external drives | 0 |
| Average CPU, drive attached, idle | < 0.05 % of one core |
| Average CPU, during a transfer, 1 s tick | < 0.1 % of one core |
| Resident memory | < 30 MB |
| Blocker scan | < 100 ms with 600 processes; never on the main thread |
| Popover open → first frame | < 50 ms |

Checked before each release with Instruments and with a tick profiler: run the binary with `FREESIDE_PROFILE=1`, as with flatline.

## 9. Accuracy acceptance criteria

| Metric | Reference | Tolerance |
|---|---|---|
| Available space | Finder Get Info "Available" | Exact at Finder's displayed precision |
| Total capacity | Finder Get Info | Exact |
| Read / write rates | `iostat -d -w 1 diskN` | ± 5 % over a sustained 30 s copy |
| Blocker list | `lsof +f -- /Volumes/X`, run as the same user | Same set of PIDs |
| Eject | Finder | Succeeds whenever Finder's eject succeeds |
| Mount / unmount | — | Shown in the popover within 1 s |

## 10. Accessibility and localization

- VoiceOver labels on the status item and on every popover value; usage bars also have their numbers as text
- The popover respects Reduce Motion and Increase Contrast
- Color is never the only signal: low space has a `!` mark and a text label
- English only for 1.0, with all strings in a String Catalog

## 11. Milestones

| # | Milestone | Done when |
|---|---|---|
| M0 | Scaffold | XcodeGen project builds an empty menu bar app; `swift test` runs |
| M1 | Volumes | DA session, volume list and space match §9; privacy-prompt check done |
| M2 | I/O | Volume → device mapping works for APFS, HFS+, exFAT and disk images; rates match §9 |
| M3 | Eject + blockers | Eject, blocker scan, Quit / Terminate / Retry / Force Eject; scan cost measured |
| M4 | Menu bar | All styles, transfer auto-switch, fixed width |
| M5 | Popover | Device cards with traces, volume rows, Blockers panel |
| M6 | Settings + notifications | All §6.6 settings persist; both notifications work |
| M7 | Distribution | `scripts/release.sh` produces a signed, notarized, stapled DMG |
| M8 | Updates + site | Sparkle wired up; site deployed with appcast; an update tested end to end |
| M9 | 1.0 | §8 budgets and §9 criteria verified; README screenshots; tagged release |

## 12. Decisions

| Question | Decision (2026-10-25) |
|---|---|
| Name | **freeside** |
| Signing | Same Developer ID team as flatline (`F87BNUZAVJ`), notarized with `notarytool` |
| Hosting | **Cloudflare Pages** at freeside.banast.as, same as flatline |
| License | **MIT** |
| Menu bar colors | **Monochrome**, for the same reason as flatline |

## 13. Open questions

1. **Shared code with flatline**: copy `RingBuffer`, `Format`, the menu bar renderer and the release scripts now, or extract a shared Swift package (working name `sprawl`, after the trilogy) that flatline, freeside and straylight all depend on? Copying is faster; a package keeps the three in step.
2. **Catching Finder's failed ejects**: DiskArbitration's unmount approval callback sees every unmount request, including Finder's. freeside could notice when a volume is still mounted a couple of seconds after a request and offer its Blockers panel. Useful, but it reacts to other apps' actions. Worth it for 1.0?
3. **Spotlight as the holder**: when Spotlight is likely the cause, link to System Settings → Spotlight so the user can exclude the drive? Turning indexing off directly (`mdutil -i off`) needs admin rights.
4. **Per-process disk I/O**: `proc_pid_rusage` gives disk bytes for the user's own processes, so the device card could show "Lightroom writing 180 MB/s". Add after 1.0?
5. **Offload with verification**: copying cards with checksums is the natural next step, but it's a different app. Keep it out of freeside.
6. **Repo visibility**: private until 1.0, or public from the start?
