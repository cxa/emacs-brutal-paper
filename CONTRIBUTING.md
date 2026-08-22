# Contributing

Contributions are welcome. Please keep changes focused and include an ERT
regression test for bug fixes or behavior changes.

Brutal Paper is a global UI enhancement, not a colour theme. Keep
`brutal-paper-mode` as the single lifecycle entry point, preserve the user's
existing Emacs state, and make every enabled side effect reversible on disable.
Consumer integrations must use the documented public API rather than private
`brutal-paper--` implementation details.

Brutal Paper supports graphical Emacs 31.1 and newer. Avoid assigning the
user's default font or font size, prefer built-in Emacs features, and preserve
compatibility across light and dark colour themes.

Before opening a pull request, run the complete automated checks:

```sh
make check
```

For visual or geometry changes, also inspect the graphical scenarios:

```sh
make e2e
```
