# Technical review (22 Nov 2026)

Scope: whole app (engine, persistence, UI, packaging). Method: code reading plus measurements on macOS 27.2 (60 Hz display).

## Measured
| Item | Result |
|---|---|
| Idle CPU | 0.0% (3 samples, menu-bar only) |
| Memory (RSS) | ~78 MB |
| App size | 3.1 MB; ~5.0k lines of code, ~1.2k lines of tests (89 tests) |
| Scroll/zoom frame cadence | ~17 ms at 60 Hz (display-link paced) |
| Not measured | Energy impact, event-tap latency under load, behaviour after a crash while the pointer is frozen |

## Findings
| # | Severity | Finding | Status |
|---|---|---|---|
| 1 | High | Ad-hoc signed, no hardened runtime, not notarized: Gatekeeper blocks it on other Macs; the Accessibility grant is tied to the ad-hoc identity requirement | Open: needs Developer ID + notarization for distribution |
| 2 | High | Relies on undocumented behaviour: pinch via CGEvent fields 110/113/132, Spaces swipe via IOHIDEvent (dlsym), Chromium primer constants, window-under-pointer heuristics. Guarded (OS check, read-back, fallbacks) but can break on any macOS update | Open: add a start-up self-test and a switch to turn the private features off |
| 3 | Medium | Imported configuration could contain `file:` links that launch local items | Fixed: `file:` links are refused (scripts were already imported switched off) |
| 4 | Medium | Settings file (may hold script commands) was readable by other local users | Fixed: directory 0700, file 0600 |
| 5 | Medium | `.latencyCritical` activity is held for as long as the engine runs, so a menu-bar app is never allowed to nap | Open: hold it only while a gesture or scroll is active; measure energy before/after |
| 6 | Medium | Window lookup (CGWindowList) ran on the event thread for every pinch | Fixed: cached for 250 ms / 24 pt; strict, so unknown targets get a plain pinch |
| 7 | Medium | Script action has no timeout, discards output and exit code | Open |
| 8 | Medium | If the app crashes while the pointer is frozen (Drag Scroll with "freeze pointer", Spaces swipe) the pointer may stay frozen | Unverified; add a re-associate call at launch |
| 9 | Low | Diagnostics now include the name of the app a zoom went to | Fixed: privacy text updated |
| 10 | Low | No auto-update; English only; no CI; no tests for UI, event tap, Chromium detection, Dock swipe; no `os_log` | Open |

## Verified good
Event tap on its own thread; tap-disabled and wake recovery; config saved atomically with backup and damaged-file recovery; lossy rule decoding; import disables scripts and asks before enabling; no network code; diagnostics hold no pointer positions or keys; idle CPU 0%.

## Follow-up (same day)
| # | Change |
|---|---|
| 2 | Pinch event self-test at start-up; Settings → Behavior switch; zoom falls back to ⌘+ / ⌘− when the pinch can't be used |
| 5 | The "don't nap" activity is held only while the mouse is in use and for 3 s after (energy not measured) |
| 7 | Scripts stop after 30 s; a failing script reports its exit code and the last lines of stderr |
| 8 | The pointer is re-associated at start-up and stop (the crash case itself is still unverified) |
| 1 | Still open: Developer ID signing and notarization need the owner's Apple Developer account |
