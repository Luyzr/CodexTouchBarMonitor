# Physical Touch Bar test — 2026-09-18

Version: 1.1.0 working-tree build (not a published release).

## Confirmed failure
The user tested the initial 1.1.0 demo on the local Touch Bar Mac.
Only the task entry appeared; the persistent network/quota tile disappeared.
DashboardController registered a second system-tray item, reproducing the
previous hardware finding that only the latest registration is visible.

## Test candidate fix
Only AppDelegate registers the persistent compact tile. DashboardController
attaches task controls to its own window Touch Bar and no longer registers or
removes a system-tray item. Open it through CTB → Task Dashboard. The tile's
click continues to open Codex. Independent cross-app task access remains an
unresolved product requirement; this fallback is not full PRD acceptance.

All source edits, builds and automated tests are performed on build host.
The local machine receives packaged binaries for runtime/hardware tests only.
Physical retest of persistence, approval controls, Chinese IME and focus is pending.

Candidate automated verification: 71 core + 47 integration + 21 AppKit assertions
passed on build host; release build and ad-hoc signature verification passed.
Candidate archive SHA256: ee46f3209c8bb5ab10952d43cc66e73e5a94c2b87132c2a52ea076602b3602b1.
