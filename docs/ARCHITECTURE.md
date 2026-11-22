# Architecture

```
UI (SwiftUI)  ──►  AppModel ──►  ConfigStore (rules, autosave)
                      │
                      └──►  EngineController ──►  EventTapMonitor (own thread, CGEventTap)
                                                      │ MouseInput
                                                      ▼
                                              MouseEventProcessor  (pure state machine)
                                                      │ EventOutput
                                                      ▼
                                              SystemEventOutput ──► ActionExecutor / EventPoster
```

| Layer | Files | Responsibility |
|---|---|---|
| Model | `Model/*` | `Rule = Trigger(button, modifiers, interaction) → Action`; `RuleSet` is the read-only lookup used on the event path; `AppConfig` is what is saved. |
| Engine core | `MouseEventProcessor`, `DragScrollAccumulator`, `EngineTypes` | Decides pass-through vs. consume, click/double-click/hold/drag/scroll recognition, drag-scroll maths. No system calls: `EventOutput` and `Scheduler` are protocols, so it is unit-tested with fakes. |
| Engine system | `EventTapMonitor`, `EngineController`, `SystemEventOutput`, `EventPoster`, `ActionExecutor` | Event tap on a dedicated thread (event-driven, no polling), synthetic events tagged with a marker so the tap ignores them, slow actions on a background queue. |
| Persistence | `ConfigStore` | Debounced atomic save, previous file kept as `config.backup.json`, damaged file moved to `config.damaged.json` and backup restored, lossy rule decoding, import/export. Stored in `~/Library/Application Support/Mouse Studio/`. |
| App | `AppModel`, `PermissionManager`, `LoginItem` | Starts/stops the monitor from settings + permission; rebuilds it after wake; surfaces problems to the user. |

## Extending

- **New action:** add an `Action` case (+ title/symbol/`isAllowed`), one branch in `ActionExecutor.run`, one menu item in `ActionMenu`.
- **New continuous action** (like Drag Scroll): add the case and handle it in `MouseEventProcessor.drag` / `wheelScrolled`.
- **New gesture:** add an `Interaction` case, a field in `RuleSet.PressRules`, and its recognition in the processor.
- **Rule priority:** one rule per exact trigger; adding the same trigger replaces the action; on load, duplicates keep the earlier rule.

## Trackpad-style behaviour

- **Momentum:** on release the processor measures the content velocity over the last 100 ms (zero if the pointer
  paused ≥ 60 ms first) and keeps posting scroll events with the *momentum* phases at 120 Hz, decaying exponentially.
  Any new press or wheel input stops it.
- **Mouse wheel:** `WheelScroller` turns each notch into distance (100 pt per notch × speed, optionally reversed per
  axis) that is eased out at 120 Hz (`EasedDistance` + `FrameLoop`) and posted as continuous pixel scroll events
  with **no gesture phase** (with phases, apps rubber-band at page edges and appear to hold the page). New notches
  blend into the running glide; reversing cancels what was left. The system's own wheel acceleration is removed at the event tap
  (scrolling uses the amount macOS reports: the first click of a burst is ~0.1 line and later ones up to ~14, so early clicks are gentle and later ones travel further. Zoom uses only the direction, one fixed step per click, because 0.1 line is below what Chrome reacts to and 14 lines would be a 65% jump),  the optional Acceleration setting is the
  only speed-dependent part (up to 4× by recent notch rate, default off).
- **Keyboard modifiers on the wheel:** `WheelSettings` assigns keys to four jobs (sideways ⇧, zoom ⌘, swift ⌃ ×3,
  precise ⌥ ×0.3; defaults as in brackets, each removable/reassignable). A job consumes its keys; unassigned keys are
  passed on with the posted scroll events. Zoom opens a pinch with a zero-size `began` and lingers 200 ms so quick
  clicks form one gesture; while the button is held the pinch stays open (one primer per hold, not per notch) and closes on release.
- **Drag vs. twitch:** on a button that has both Drag and Click-and-Scroll, a drag that does not look
  deliberate (≥400 pt/s over the last 0.1 s) starts "soft": its speed ramps from 0 to full over the first 24 pt, so a thumb
  twitch barely moves the page and a slow real drag still starts smoothly (a hard 24 pt gate made slow drags stall, then jump). A recorded trace showed 5–6 pt jerks (quick but brief) starting Drag Scroll, which then ran for
  ~1 s until the wheel turned, scrolling the page while the user was zooming. Buttons without click-and-scroll keep the
  4 pt threshold. The trace records when a drag starts and when the wheel ends it.
- **Click and scroll:** while the button is down every wheel turn is handled (also after the hand has started a
  drag, which is ended). Direction uses the physical wheel direction (`isDirectionInvertedFromDevice`), so "away
  from you" zooms in / raises the volume whatever the system scroll setting is.
- **Frame pacing:** everything that posts scrolling or zoom steps (`FrameLoop`, glide) is driven by the display
  refresh (`CVDisplayLink` on the display under the pointer, waking the tap run loop through a run-loop source), so
  exactly one step reaches each screen frame. A free-running 120 Hz timer drifted against a 60 Hz display and
  produced uneven frames. The link stays alive 0.5 s after the last use. The app also holds a latency-critical
  activity (no App Nap) while the monitor runs.
- **Drag Scroll pacing:** pointer events (125–1000 Hz, uneven) only add to a pending distance; scroll events are posted
  by a 120 Hz `FrameLoop` on a fixed time grid (zero timer tolerance), so cadence does not follow the mouse rate.
  Release flushes what was gathered, then ends the gesture and starts the glide.
- **Settings plumbing:** `EngineConfig(AppConfig)` is the single place that copies saved settings to the event path;
  a test guards that every setting reaches it.
- **Zoom:** `PinchZoom` eases click-and-scroll into magnify gesture events (CGEvent type 29, sub-type 8), so apps see
  a real pinch. **Chromium (Chrome, Edge, Brave, Arc, Electron) ignores a pinch until it has grown ~1.5× (or
  shrunk to 1/1.5)**, so small mouse-wheel steps never zoomed unless scrolled very fast. For those targets (detected
  from the window under the pointer: `ChromiumApps`) each gesture opens with one primer step just short of that line
  (+0.493 in, −0.329 out): it is swallowed without changing the page and later steps count at once. The primer must
  land in a narrow window measured against Chrome (in: 0.49–0.4975, out: −0.325…−0.332; below it a single click is swallowed,
  above it the page jumps), and it must reach the app in a frame of its own: Chromium merges steps that arrive together,
  so primer + first real step in one frame crosses the line and jumps, so the first real step waits 60 ms after the primer (`PinchZoom.primerGap`). Near the minimum zoom, zooming out can snap to 1.0. Reversing the wheel starts a new,
  re-primed gesture. Re-measure if Chromium changes.
- **Diagnostics:** `EventTrace` keeps the last 400 button/wheel/reset events with the engine's decision in memory;
  General → "Copy Recent Mouse Events" copies it with versions, settings and rules (no positions, keys or content).
- **Spaces & Mission Control:** `DockSwipeSimulator` posts the same "dock swipe" gesture a Trackpad sends, with
  progress following the pointer (625 pt = a full swipe at speed 100%, adjustable), so the system animates, commits or springs back itself.
  This uses private macOS 27 internals (an `IOHIDEvent` stored inside a CGEvent). It is guarded (OS check, memory
  size check, read-back check); if anything fails it disables itself and the action becomes a one-shot
  (`supportsInteractiveSwipe == false`). **Re-test after every macOS update.**

## Known limits (macOS)

- Mouse-move events cannot be suppressed from an event tap, so the pointer is frozen with
  `CGAssociateMouseAndMouseCursorPosition` during Drag Scroll. It is released on every exit path.
- "Previous App" posts ⌘Tab (quick switch); a held app-switcher is not possible from synthetic events.
- Show Desktop posts F11, Mission Control/Launchpad open the system apps; they follow the user's macOS shortcut settings.
- Zoom posts ⌘= / ⌘−, which most apps honour; it is not a Trackpad pinch.

## Wheel zoom
Every wheel event is one click of `WheelSettings.zoomStep` (5% by default, adjustable), so zoom follows the total number of
clicks: a quick flick of a real wheel is 5-8 events (recorded traces) and zooms that many steps. A flick that starts after
a pause of `zoomBurstGap` (90 ms), or turns the other way, opens a fresh pinch (except for Chromium, which needs one long
pinch); apps add up what a pinch asks for, so this keeps whatever went past their zoom limit small.

Chrome's primer (+0.493 / -0.329) must only go to Chromium. `ChromiumApps.appUnderPointer` takes the topmost window under the
pointer on layers 0-19, floating panels and menu-bar (accessory) apps included. Skipping them once made the Chromium window
behind a floating image (PasteClip) the target, and the picture got the primer: +49% or -33% for one click.
