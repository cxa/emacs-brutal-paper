# Changelog

## [Unreleased]

- Add `brutal-paper-window-style`, a public plist of a window's paper, Canvas,
  ink, title colours and title geometry, for packages drawing matching chrome.
- Add `brutal-paper-window-footer-image`, the built-in footer for a window.
- Document buffer-local `brutal-paper-mode-line-format` values as supported.
- Truncate long window titles with an ellipsis so they end before the right-side
  metadata and compact menu in narrow windows.
- Add `brutal-paper-window-title-badge-function`, letting a buffer draw a picture
  in its title's order badge in place of the window number.
- Add `brutal-paper-window-title-show-order`, to show every window number again
  while selecting windows by number.
- Add `brutal-paper-show-window-title-position` and
  `brutal-paper-show-window-title-status` to hide the title's line position or
  buffer state, with their separators.
- Add `brutal-paper-show-window-title-mode`, to hide the title's mode name.
- Add `brutal-paper-window-title-position-function`, replacing a buffer's line
  position with its own metadata, such as a preview's dimensions; it keeps its
  room before a long buffer name in narrow windows.
- Add `brutal-paper-window-number-string`, a window's number badge alone, for a
  buffer-local `brutal-paper-tab-line-format` of its own.

## [0.1.2] - 2026-08-27

- Add user-defined parent- and sub-tab status badges with theme-aware faces
  and built-in dots, check, cross, and dot icons.
- Animate running-state dots in a fixed-width marker without full-frame
  redraws.
- Center workspace order labels inside their badges.
- Cover status badges in the E2E fixture and slow presentation changes to ten
  seconds.

## [0.1.1] - 2026-08-26

- Preserve graphical Emacs 31.1 support with SVG structural images.
- On Emacs 32+, reuse Canvas image objects for structural fills, spacing, and
  footer shadows; repaint their ARGB32 buffers with `canvas-refresh`.
- Keep Emacs 32's native inter-row baseline from closing the selected parent
  tab's opening.

## [0.1.0] - 2026-08-26

- Initial public release for graphical Emacs 31.1 and later.
- Adaptive paper-and-canvas chrome layered over the user's colour theme.
- Reversible global `brutal-paper-mode` lifecycle.
- Workspace tabs and consumer-defined sub-tabs.
- Per-window titles, gutters, hard shadows, and styled echo/minibuffer areas.
- Configurable colours, typography, spacing, logo visibility, and mode-line
  content.
- Automated ERT and graphical E2E coverage.
