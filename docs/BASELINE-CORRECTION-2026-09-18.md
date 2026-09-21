# PRD/TDD baseline correction — 2026-09-18

Authority: PRD-v1.0-retrieved.md, TDD-v1.0.md, and explicit user Touch Bar refinements in this conversation. Later implementation/release notes are not new requirements.

Accepted persistent layout: one compact two-row Control Strip item; latency above,
Codex icon plus weekly remaining percentage below; no 7D label; tap opens Codex.

## Corrections
- Use live mode for hardware acceptance. Demo intentionally disables both monitors.
- Keep a single system-tray registration; a second item hid the persistent tile on real hardware.
- Withdraw telemetry/plan/context/agent metrics and pause/resume/stop controls from task detail. PRD section 62 specifies task status/activity/duration/Open; section 63 defers Stop.
- Remove theme, sound and haptic settings introduced outside the baseline settings list (section 79).
- Remove the unsupported Skip request shortcut. Preserve explicit options, Other, Send and Cancel.
- Session approval is an explicit action on the shown request; do not add an unrequested desktop confirmation to the Touch Bar decision flow.
- Tasks back navigation returns to the task/decision selector, not another detail screen.
- Label the desktop window as diagnostics. It does not implement the required background Touch Bar interaction.

## Remaining blockers, not accepted features
1. Dynamic area must coexist with another application's native controls and the persistent item. Neither registering a second tray item nor requiring this app's foreground window meets that requirement. No full-bar modal replacement has been introduced.
2. Local default daemon socket is absent. The independent quota fallback works, but cannot discover tasks owned by another Codex server. Task discovery/approval acceptance needs a verified connection to that server.
3. Chinese IME, focus retention and physical decision interaction remain unaccepted until (1) and (2) are resolved.

## This session's evidence
- User confirmed persistent tile survives Safari switching after second registration was removed.
- Live local preview on restored run showed network 458ms and weekly remaining 51%; these are observations, not fixed display values.
- All source modifications/builds/tests remain on build host; local runs use copied app artifacts.

- User confirmed both actual values appear on the physical Touch Bar in live mode.
- Correction build: 71 core + 47 integration + 17 AppKit assertions passed on build host; release build succeeded.

## Subsequent user-approved correction
The physical placement-0 probe retained network/quota but replaced Safari's app controls.
The user explicitly accepted temporary task/decision/input presentation with one-tap return
to native controls. This supersedes the earlier simultaneous-coexistence requirement.
Implementation uses placement 0 only; the persistent system-tray item is never replaced.
Desktop IPC framing and version-11 snapshot/patch reception were verified against the local
running Codex task. The desktop fallback uses events, not recurring history polling.
