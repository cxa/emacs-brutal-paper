# Changelog

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
