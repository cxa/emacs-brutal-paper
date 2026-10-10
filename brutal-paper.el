;;; brutal-paper.el --- Paper-like window chrome -*- lexical-binding: t; -*-

;; Author: CHEN Xian-an <xianan.chen@gmail.com>
;; Maintainer: CHEN Xian-an <xianan.chen@gmail.com>
;; Version: 0.1.2
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Package-Requires: ((emacs "31.1"))
;; Keywords: faces, convenience
;; URL: https://github.com/cxa/emacs-brutal-paper

;;; Commentary:

;; Brutal Paper is a global structural UI enhancement.  It supplies a workspace
;; tab bar, a per-window identity row, a paper-and-shadow footer, and the Canvas
;; gaps between windows without replacing the user's colour theme.  Load the
;; colour theme first, then enable the mode:
;;
;;   (load-theme 'modus-operandi t)
;;   (brutal-paper-mode 1)
;;
;; The editing `default' face is deliberately never assigned a font, height,
;; or colour here.  Structural colours are read from the active theme, while
;; every geometry value is a user option.  This makes the enhancement useful
;; with Modus, Alabaster, a custom theme, or Emacs's unthemed defaults.

;;; History:

;; See CHANGELOG.md.

;;; Code:

(require 'color)
(require 'cl-lib)
(require 'face-remap)
(require 'seq)
(require 'svg)
(require 'tab-bar)
(require 'tab-line)
(require 'wid-edit)

(declare-function isearch-update "isearch" ())
(declare-function canvas-refresh "image" (image &optional reload-data))

(defconst brutal-paper--directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing Brutal Paper.")

(defconst brutal-paper--default-logo-artwork
  (expand-file-name "assets/brutal-paper.svg" brutal-paper--directory)
  "Bundled SVG artwork used by the standalone workspace row.")

(defgroup brutal-paper nil
  "Paper-like window spacing and structural chrome."
  :group 'faces
  :prefix "brutal-paper-")

;;;###autoload
(define-minor-mode brutal-paper-mode
  "Toggle Brutal Paper's structural UI enhancement.
The mode requires a graphical frame.  Enabling captures every native mode,
variable, face, frame, window, and buffer value it changes; disabling restores
that state.  The active colour theme remains independent and can be changed
while this mode is enabled."
  :global t
  :group 'brutal-paper
  :lighter nil
  (if brutal-paper-mode
      (condition-case error-data
          (brutal-paper--enable)
        (error
         (setq brutal-paper-mode nil)
         (ignore-errors (brutal-paper--disable))
         (signal (car error-data) (cdr error-data))))
    (brutal-paper--disable)))

(define-widget 'brutal-paper-color 'choice
  "A colour used in every appearance or a light/dark colour pair."
  :tag "Colour"
  :args '((color :tag "Single colour")
          (list :tag "Light / dark colours"
                (const :format "" :light)
                (color :tag "Light")
                (const :format "" :dark)
                (color :tag "Dark"))))

(defun brutal-paper--set-visual-option (symbol value)
  "Set visual option SYMBOL to VALUE and refresh Brutal Paper chrome."
  (set-default symbol value)
  (if (and brutal-paper-mode (fboundp 'brutal-paper-apply))
      (brutal-paper-apply)
    (when (fboundp 'brutal-paper--clear-image-caches)
      (brutal-paper--clear-image-caches)))
  (force-mode-line-update t))

(defun brutal-paper--set-line-format-option (symbol value)
  "Set complete line-format option SYMBOL to VALUE in live paper buffers."
  (set-default symbol value)
  (when (and brutal-paper-mode
             (fboundp 'brutal-paper--install-all-buffer-chrome))
    (brutal-paper--install-all-buffer-chrome))
  (force-mode-line-update t))

(defmacro brutal-paper--defvisual (name default type doc)
  "Define visual option NAME with DEFAULT, TYPE, and DOC."
  `(defcustom ,name ,default ,doc
     :type ,type
     :set #'brutal-paper--set-visual-option
     :group 'brutal-paper))

(defmacro brutal-paper--defface (name doc &optional attributes)
  "Define paper face NAME with DOC and optional ATTRIBUTES."
  `(defface ,name '((t ,(or attributes '(:inherit default))))
     ,doc :group 'brutal-paper))

(brutal-paper--defvisual brutal-paper-show-logo t 'boolean
  "Whether the standalone workspace row should show a brand mark.")

(brutal-paper--defvisual brutal-paper-tab-statuses
  '((running :icon dots :face warning :label "...")
    (success :icon check :face success :label "✓")
    (error :icon cross :face error :label "✗"))
  '(repeat
    (list :tag "Tab status"
          (symbol :tag "Name")
          (const :format "" :icon)
          (choice :tag "Icon"
                  (const :tag "Animated dots" dots)
                  (const :tag "Check" check)
                  (const :tag "Cross" cross)
                  (const :tag "Dot" dot))
          (const :format "" :face)
          (face :tag "Colour face")
          (const :format "" :label)
          (string :tag "Text fallback")))
  "Presentations available to a consumer tab model.
Each entry is (STATUS :icon ICON :face FACE :label LABEL).  STATUS is accepted
by the public `:status' item property.  ICON is `dots', `check', `cross', or
`dot'; FACE supplies its colour and LABEL is used when SVG is unavailable.")

(brutal-paper--defvisual brutal-paper-tab-model-function nil
  '(choice (const :tag "Native Emacs tabs" nil) function)
  "Optional consumer function supplying parent tabs and sub-tabs.
The function receives the frame being rendered and returns a plist with a
`:tabs' list and an optional `:sub-tabs' list.  Every item is a plist with:

  `:id'        a stable identity used for cached rendering;
  `:name'      the primary label string;
  `:subtitle'  an optional quieter label string;
  `:current'   non-nil for the selected item;
  `:select'    a command called when an inactive item is chosen;
  `:status'    optional key from `brutal-paper-tab-statuses';
  `:help'      optional help text.

The function should be side-effect-free and fast enough for redisplay.
Call `brutal-paper-refresh' after its data changes.  Nil adapts Emacs's native
physical tabs and does not display a sub-tab row.")

(brutal-paper--defvisual brutal-paper-tab-bar-background nil
  '(choice (const :tag "Follow Paper background" nil)
           brutal-paper-color function)
  "Background of the complete parent tab-bar row.
Nil follows the Paper background.  A function receives the current public tab
item and returns a colour specification or nil.")

(brutal-paper--defvisual brutal-paper-logo-file nil
  '(choice (const :tag "Bundled Brutal Paper logo" nil)
                 (file :must-match t))
  "Custom SVG logo displayed in the standalone workspace row.
Nil uses the SVG bundled with Brutal Paper.")

(defconst brutal-paper--logo-height 22
  "Preferred logo height, capped by the inactive tab height.")

(brutal-paper--defvisual brutal-paper-logo-horizontal-padding 10 'natnum
  "Leading padding before the workspace-row logo, in pixels.")

(brutal-paper--defvisual brutal-paper-logo-tab-gap 4 'natnum
  "Trailing gap between the workspace-row logo and first tab, in pixels.")

(brutal-paper--defvisual brutal-paper-logo-vertical-offset -1 'number
  "Vertical correction applied to the workspace-row logo in pixels.")

(brutal-paper--defvisual brutal-paper-unfocused-logo-saturation 0 'number
  "Colour saturation of the logo on unfocused frames.
Zero is grayscale and one preserves the original artwork.")

(brutal-paper--defvisual brutal-paper-window-gap 10 'natnum
  "Requested Canvas gutter width between Paper surfaces, in pixels.
When outer window margins are enabled, Emacs can realize them only as whole
font columns.  Brutal Paper quantizes this value once and uses the resulting
pixel width for left, middle, right, and tab-to-Paper gutters alike.")

(brutal-paper--defvisual brutal-paper-fringe-width 12 'natnum
  "Width in pixels of paper fringes and minibuffer body padding.")

(brutal-paper--defvisual brutal-paper-minibuffer-vertical-padding-ratio 0.5 'number
  "Minibuffer Paper padding as a fraction of the default font pixelsize.
The same inset is used above the prompt and below the completion body.
This vertical inset is independent of `brutal-paper-fringe-width', which
controls horizontal geometry.")

(brutal-paper--defvisual brutal-paper-minibuffer-right-padding 'auto
  '(choice (const :tag "Match the left Paper inset" auto)
                 natnum)
  "Text inset before the minibuffer's right Paper edge, in columns.
The value `auto' derives the nearest whole-column inset from
`brutal-paper-fringe-width' and the realized default font.  This inset is
applied by completion adapters at the text layout layer; it never reserves a
native window margin, whose Canvas face would split the Paper edge.")

(brutal-paper--defvisual brutal-paper-bottom-divider-width 0 'natnum
  "Width in pixels of the bottom divider beneath paper windows.")

(brutal-paper--defvisual brutal-paper-window-divider-mode t 'boolean
  "Whether Brutal Paper should enable Emacs's window-divider mode.")

(brutal-paper--defvisual brutal-paper-canvas-background nil
  '(choice (const :tag "Follow active theme" nil)
                 brutal-paper-color)
  "Explicit colour specification for paper gaps.
Nil follows the active theme.  A colour string applies everywhere; a plist
`(:light LIGHT :dark DARK)' follows the frame's realized appearance.")

(brutal-paper--defvisual brutal-paper-canvas-color-function nil
  '(choice (const :tag "Follow selected physical tab" nil)
                 function)
  "Optional function used to resolve the structural Canvas colour.
The function receives a frame and should return a colour string or nil.
`brutal-paper-canvas-background' takes precedence when it is non-nil.")

(brutal-paper--defvisual brutal-paper-canvas-mix 1.0
  '(restricted-sexp :match-alternatives (numberp))
  "Amount of the selected tab colour mixed into Canvas gaps.
One preserves the current solid tab colour; zero uses the paper background.")

(brutal-paper--defvisual brutal-paper-adapt-to-active-theme t 'boolean
  "Whether structural colours should be read from the active theme.")

(brutal-paper--defvisual brutal-paper-accent-color nil
  '(choice (const :tag "Use Brutal Paper blue" nil)
                 brutal-paper-color)
  "Explicit accent for selected window-order cells.
Nil uses Brutal Paper's default `selected-window' blue.")

(brutal-paper--defvisual brutal-paper-tab-colors '((:light "#57E561" :dark "#00402A")
    (:light "#FED413" :dark "#7B716B")
    (:light "#4DD1FB" :dark "#162A66")
    (:light "#FFA55B" :dark "#561248")
    (:light "#F0E9DE" :dark "#1A1B24")) '(repeat brutal-paper-color)
  "Colour specifications rotated across workspace tabs and order cells.
Each item may be a single colour string or `(:light LIGHT :dark DARK)'.")

(brutal-paper--defvisual brutal-paper-window-background-fallback
  '(:light "#ffffff" :dark "#000000") 'brutal-paper-color
  "Editing-surface colour used when the active theme supplies none.")

(brutal-paper--defvisual brutal-paper-foreground-color-fallback
  '(:light "#000000" :dark "#ffffff") 'brutal-paper-color
  "Editing-ink colour used when the active theme supplies none.")

(brutal-paper--defvisual brutal-paper-default-accent-color "#007ACC" 'brutal-paper-color
  "Accent used when `brutal-paper-accent-color' is nil.")

(brutal-paper--defvisual brutal-paper-light-ink-color "#ffffff" 'brutal-paper-color
  "Light ink selected for readable text and dark-theme shadows.")

(brutal-paper--defvisual brutal-paper-dark-ink-color "#000000" 'brutal-paper-color
  "Dark ink selected for readable text and light-theme shadows.")

(brutal-paper--defvisual brutal-paper-window-title-active-background
  '(:light "#e0e0e0" :dark "#303030") 'brutal-paper-color
  "Background of the selected window's title block.")

(brutal-paper--defvisual brutal-paper-window-title-inactive-background
  '(:light "#f0f0f0" :dark "#242424") 'brutal-paper-color
  "Background of an inactive window's title block.")

(brutal-paper--defvisual brutal-paper-inactive-tab-color-mix 0.72 'number
  "Amount of tab colour mixed into an inactive tab's paper surface.")

(brutal-paper--defvisual brutal-paper-tab-qualifier-color-mix 0.28 'number
  "Amount of foreground mixed into workspace-tab qualifier text.")

(brutal-paper--defvisual brutal-paper-tab-outline-color-mix 0.58 'number
  "Amount of tab border colour mixed into the selected-tab outline.")

(brutal-paper--defvisual brutal-paper-tab-paper-min-contrast 1.2 'number
  "Minimum contrast between tab surfaces and the surrounding Paper.
Colours below this ratio are moved toward dark or light ink by the smallest
amount that reaches the ratio.  Set this to 1.0 to preserve configured tab
colours exactly.")

(brutal-paper--defvisual brutal-paper-window-muted-ink-mix 0.32 'number
  "Amount of paper colour mixed into inactive window metadata ink.")

(brutal-paper--defvisual brutal-paper-chrome-muted-background-mix 0.55 'number
  "Amount of Canvas colour mixed into muted chrome backgrounds.")

(brutal-paper--defvisual brutal-paper-chrome-muted-foreground-mix 0.45 'number
  "Amount of paper colour mixed into muted chrome foregrounds.")

(defcustom brutal-paper-hide-tool-bar t
  "Whether enabling Brutal Paper should hide the graphical tool bar."
  :type 'boolean
  :group 'brutal-paper)

(defcustom brutal-paper-hide-scroll-bars t
  "Whether Brutal Paper should keep graphical scroll bars disabled.
While the mode is enabled, non-nil also prevents the public vertical and
horizontal scroll-bar mode functions from enabling them.  Nil preserves the
native modes present at enable time and allows later changes."
  :type 'boolean
  :group 'brutal-paper)

(defcustom brutal-paper-rounded-frame-chrome t
  "Whether Emacs Plus frames should use rounded native chrome."
  :type 'boolean
  :group 'brutal-paper)

(brutal-paper--defvisual brutal-paper-shadow-color nil
  '(choice (const :tag "Derive from Canvas" nil) brutal-paper-color)
  "Explicit hard-shadow colour, or nil to derive one from the Canvas.")

(brutal-paper--defvisual brutal-paper-shadow-mix '(:light 0.38 :dark 0.16) '(choice
          (number :tag "Same amount")
          (list :tag "Light/dark pair"
                (const :light) number
                (const :dark) number))
  "Amount of contrast ink mixed into Canvas for hard shadows.
A number applies to every appearance.  `(:light LIGHT :dark DARK)' allows a
strong traditional dark shadow on light surfaces and a quieter light shadow
on dark surfaces.")

(brutal-paper--defvisual brutal-paper-shadow-depth 4 'natnum
  "Depth in pixels of tab and mode-line hard shadows.")

(brutal-paper--defvisual brutal-paper-outline-width 1 'natnum
  "Width in pixels of the outline around active paper tabs.")

(brutal-paper--defvisual brutal-paper-current-tab-font 'bold
  '(choice (const :tag "Follow default face" nil)
                 (string :tag "Font family")
                 (face :tag "Face"))
  "Font used by selected parent-tab and sub-tab text.
A string names a font family, a face supplies family, weight, and slant, and
nil follows the `default' face.  The default `bold' face emphasizes the current
tab without fixing a font family.  Font size continues to use the dedicated
tab size options because SVG uses pixels while Emacs faces may use relative
height.")

(brutal-paper--defvisual brutal-paper-inactive-tab-font nil
  '(choice (const :tag "Follow default face" nil)
                 (string :tag "Font family")
                 (face :tag "Face"))
  "Font used by non-selected parent-tab and sub-tab text.
A string names a font family, a face supplies family, weight, and slant, and
nil follows the `default' face.  Font size continues to use the dedicated tab
size options.")

(brutal-paper--defvisual brutal-paper-current-sub-tab-font :tab
  '(choice (const :tag "Follow the current parent-tab font" :tab)
                 (const :tag "Follow default face" nil)
                 (string :tag "Font family")
                 (face :tag "Face"))
  "Font used by selected sub-tab text.
The keyword `:tab' uses `brutal-paper-current-tab-font'.  A string names a
font family, a face supplies family, weight, and slant, and nil follows the
`default' face.  Font size continues to use the dedicated sub-tab size
options.")

(brutal-paper--defvisual brutal-paper-inactive-sub-tab-font :tab
  '(choice (const :tag "Follow the inactive parent-tab font" :tab)
                 (const :tag "Follow default face" nil)
                 (string :tag "Font family")
                 (face :tag "Face"))
  "Font used by non-selected sub-tab text.
The keyword `:tab' uses `brutal-paper-inactive-tab-font'.  A string names a
font family, a face supplies family, weight, and slant, and nil follows the
`default' face.  Font size continues to use the dedicated sub-tab size
options.")

(brutal-paper--defvisual brutal-paper-current-title-font nil
  '(choice (const :tag "Follow default face" nil)
                 (string :tag "Font family")
                 (face :tag "Face"))
  "Font used by the selected window's title and metadata text.
A string names a font family, a face supplies family, weight, and slant, and
nil follows the `default' face.  Font size continues to use the dedicated
window title and metadata size options.")

(brutal-paper--defvisual brutal-paper-inactive-title-font nil
  '(choice (const :tag "Follow default face" nil)
                 (string :tag "Font family")
                 (face :tag "Face"))
  "Font used by non-selected windows' title and metadata text.
A string names a font family, a face supplies family, weight, and slant, and
nil follows the `default' face.  Font size continues to use the dedicated
window title and metadata size options.")

(defcustom brutal-paper-enable-tab-bar t
  "Whether enabling Brutal Paper should show the frame tab bar."
  :type 'boolean
  :group 'brutal-paper)

(defcustom brutal-paper-enable-tab-line t
  "Whether enabling Brutal Paper should show each window's status tab line."
  :type 'boolean
  :group 'brutal-paper)

(defcustom brutal-paper-enable-echo-area t
  "Whether inactive messages should use the current Canvas surface."
  :type 'boolean
  :group 'brutal-paper)

(defcustom brutal-paper-enable-window-margins t
  "Whether Brutal Paper should own paper fringes and outer Canvas margins.
Set this to nil when another package manages the same window-local geometry."
  :type 'boolean
  :group 'brutal-paper)

(brutal-paper--defvisual brutal-paper-enable-window-shadow t 'boolean
  "Whether Brutal Paper should draw the current window's lower hard shadow.
The shadow is rendered inside the mode line.  No right-side strip is drawn,
so every supported Emacs release keeps the complete window edge native.")

(defcustom brutal-paper-tab-line-format
  '((:eval (brutal-paper--tab-line)))
  "Format used for each paper window's identity and status row."
  :type 'sexp
  :set #'brutal-paper--set-line-format-option
  :group 'brutal-paper)

(defcustom brutal-paper-mode-line-format
  '((:eval (brutal-paper--mode-line)))
  "Complete `mode-line-format' used beneath every paper window.
The default renders Brutal Paper's blank footer and lower hard shadow.  Any
valid mode-line construct is accepted and replaces that footer completely.
Erase the customization to restore the built-in footer image and shadow.
Changes made through Customize are installed in live buffers immediately.
Disabling Brutal Paper still restores the mode-line value captured before
enable."
  :type 'sexp
  :set #'brutal-paper--set-line-format-option
  :group 'brutal-paper)

(brutal-paper--defface brutal-paper-canvas
  "Face used by Brutal Paper's structural Canvas.")
(brutal-paper--defface brutal-paper-shadow
  "Face reserved for Brutal Paper's optional structural shadow.")
(brutal-paper--defface brutal-paper-tab-bar
  "Canvas face spanning the frame's workspace tab row.")
(brutal-paper--defface brutal-paper-tab-current
  "Selected workspace tab face.")
(brutal-paper--defface brutal-paper-tab-inactive
  "Inactive workspace tab face.")
(brutal-paper--defface brutal-paper-tab-hover
  "Neutral Paper hover face that prevents native raised tab frames."
  (:inherit default :box nil :underline nil :overline nil))
(brutal-paper--defface brutal-paper-sub-tab-hover
  "Neutral Canvas hover face that prevents native raised tab frames."
  (:inherit default :box nil :underline nil :overline nil))
(brutal-paper--defface brutal-paper-window-line
  "Paper surface behind a window's identity row.")
(brutal-paper--defface brutal-paper-window-order-active
  "Order cell of the selected window.")
(brutal-paper--defface brutal-paper-window-order-inactive
  "Order cell of an inactive window.")
(brutal-paper--defface brutal-paper-window-title-active
  "Buffer title in the selected window.")
(brutal-paper--defface brutal-paper-window-title-inactive
  "Buffer title in an inactive window.")
(brutal-paper--defface brutal-paper-window-meta-active
  "Right-side metadata in the selected window.")
(brutal-paper--defface brutal-paper-window-meta-inactive
  "Right-side metadata in an inactive window.")
(brutal-paper--defface brutal-paper-footer-active
  "Paper-and-shadow footer of the selected window.")
(brutal-paper--defface brutal-paper-footer-inactive
  "Paper-and-shadow footer of an inactive window.")

(defvar brutal-paper--applying nil)
(defvar brutal-paper--modes-active nil)
(defvar brutal-paper--saved-tab-bar-mode nil)
(defvar brutal-paper--saved-global-tab-line-mode nil)
(defvar brutal-paper--saved-tool-bar-mode nil)
(defvar brutal-paper--saved-scroll-bar-mode nil)
(defvar brutal-paper--saved-horizontal-scroll-bar-mode nil)
(defvar brutal-paper--allow-scroll-bar-mode-change nil
  "Non-nil while Brutal Paper is deliberately restoring scroll-bar state.")
(defvar brutal-paper--saved-window-divider-mode nil)
(defvar brutal-paper--saved-window-divider-default-right-width nil)
(defvar brutal-paper--saved-window-divider-default-bottom-width nil)
(defvar brutal-paper--saved-frame-chrome
  (make-hash-table :test #'eq :weakness 'key))
(defvar brutal-paper--saved-window-edges
  (make-hash-table :test #'eq :weakness 'key))
(defvar brutal-paper--saved-face-attributes nil
  "Face attributes captured by the current enable session.")
(defvar brutal-paper--saved-variable-values nil
  "Global variable values captured by the current enable session.")
(defconst brutal-paper--managed-variable-values
  '((tab-bar-border 0)
    (tab-bar-separator "")
    (tab-bar-close-button-show nil)
    (tab-bar-new-button-show nil)
    (tab-bar-auto-width nil)
    (tab-bar-format
     (brutal-paper--tab-bar-format-logo
      brutal-paper--tab-bar-format-tabs
      brutal-paper--tab-bar-format-fill
      brutal-paper--tab-bar-format-sub-tabs))
    (tab-bar-tab-face-function brutal-paper--tab-face)
    (tab-bar-tab-name-format-function brutal-paper--tab-name-format))
  "Native variables owned while `brutal-paper-mode' is enabled.")
(defconst brutal-paper--mutated-face-attributes
  '(:inherit :foreground :background :box :height :weight
    :underline :overline)
  "Face attributes Brutal Paper may change while enabled.")
(defconst brutal-paper--mutated-faces
  '(internal-border vertical-border window-divider
    window-divider-first-pixel window-divider-last-pixel margin fringe
    mode-line mode-line-active mode-line-inactive tab-bar tab-line
    brutal-paper-canvas brutal-paper-shadow brutal-paper-tab-bar
    brutal-paper-tab-current brutal-paper-tab-inactive brutal-paper-tab-hover
    brutal-paper-sub-tab-hover
    brutal-paper-window-line brutal-paper-window-order-active
    brutal-paper-window-order-inactive brutal-paper-window-title-active
    brutal-paper-window-title-inactive brutal-paper-window-meta-active
    brutal-paper-window-meta-inactive brutal-paper-footer-active
    brutal-paper-footer-inactive)
  "Faces changed directly while Brutal Paper is enabled.")
(defvar brutal-paper--normalizing-window-edges nil)
(defvar brutal-paper--tab-image-cache (make-hash-table :test #'equal))
(defvar brutal-paper--tab-fill-image-cache (make-hash-table :test #'equal))
(defvar brutal-paper--sub-tab-image-cache (make-hash-table :test #'equal))
(defvar brutal-paper--sub-tab-fill-image-cache (make-hash-table :test #'equal))
(defvar brutal-paper--svg-font-metrics-cache (make-hash-table :test #'equal))
(defvar brutal-paper--tab-model-cache
  (make-hash-table :test #'eq :weakness 'key))
(defvar brutal-paper--tab-line-image-cache (make-hash-table :test #'equal))
(defvar brutal-paper--mode-line-image-cache (make-hash-table :test #'equal))
(defvar brutal-paper--canvas-image-cache
  (make-hash-table :test #'equal :weakness 'value)
  "Reusable canvas image specs indexed by geometry, not paint colours.")
(defvar brutal-paper--canvas-image-signatures
  (make-hash-table :test #'eq :weakness 'key)
  "Last paint signature for each reusable canvas image spec.")
(defvar brutal-paper--logo-aspect-ratio-cache
  (make-hash-table :test #'equal))
(defvar brutal-paper--focus-refresh-timer nil
  "Timer coalescing workspace-row refreshes after focus changes.")
(defvar brutal-paper--tab-status-timer nil
  "Timer advancing animated tab-status markers.")
(defvar brutal-paper--tab-status-phase 1
  "Number of visible dots in the current animated tab-status frame.")
(defvar brutal-paper--echo-area-refresh-timer nil
  "Timer coalescing echo-area work requested from unsafe hooks.")
(defvar brutal-paper--pending-echo-area-frames nil
  "Frames whose echo areas need refreshing outside redisplay.")
(defvar brutal-paper--refreshing-echo-area nil
  "Non-nil while a deferred echo-area refresh is running.")
(defvar-local brutal-paper--buffer-chrome-installed nil)
(defvar-local brutal-paper--saved-local-tab-line nil)
(defvar-local brutal-paper--saved-local-mode-line nil)
(defvar-local brutal-paper--saved-local-tab-line-mode nil)
(defvar-local brutal-paper--echo-area-remap-cookie nil)
(defvar-local brutal-paper--echo-area-remap-color nil)
(defvar-local brutal-paper--inactive-echo-bottom-gap-overlay nil)
(defvar-local brutal-paper--minibuffer-input-inset-state nil)
(defvar-local brutal-paper--active-minibuffer-top-padding-overlay nil)
(defvar-local brutal-paper--active-minibuffer-bottom-padding-overlay nil)
(defvar-local brutal-paper--minibuffer-fringe-remap-cookie nil)
(defvar-local brutal-paper--native-minibuffer-canvas-remap-cookie nil)
(defvar-local brutal-paper--native-minibuffer-paper-overlay nil)
(defconst brutal-paper--unset-minibuffer-cursor-state
  :brutal-paper-unset-minibuffer-cursor-state)
(defvar-local brutal-paper--saved-minibuffer-cursor-state
  brutal-paper--unset-minibuffer-cursor-state)
(setq-default brutal-paper--saved-minibuffer-cursor-state
              brutal-paper--unset-minibuffer-cursor-state)
(defvar brutal-paper--resizing-echo-area-window nil)

(defconst brutal-paper--echo-area-buffer-names
  '(" *Echo Area 0*" " *Echo Area 1*")
  "Internal buffers Emacs alternates for echo-area messages.")

(defun brutal-paper--top-level-frame-p (frame)
  "Return non-nil when FRAME is a normal top-level frame.
Popup and child frames own their dimensions and must not inherit paper gutters."
  (and (frame-live-p frame)
       (not (and (framep frame)
                 (or (frame-parent frame)
                     (frame-parameter frame 'tooltip))))))

(defun brutal-paper--graphical-environment-p (&optional frame)
  "Return non-nil when FRAME is a graphical Emacs frame."
  (display-graphic-p (or frame (selected-frame))))

(defun brutal-paper--require-graphical-environment (&optional frame)
  "Signal a user error unless FRAME is graphical."
  (unless (brutal-paper--graphical-environment-p frame)
    (user-error "Brutal Paper requires a graphical Emacs frame")))

(defun brutal-paper--frame-character-pixel-width (&optional frame)
  "Return one native margin column width on FRAME, in pixels."
  (max 1
       (or (ignore-errors (frame-char-width (or frame (selected-frame))))
           (ignore-errors (window-font-width nil 'default))
           1)))

(defun brutal-paper--outer-edge-margin-columns (&optional frame)
  "Return native columns nearest `brutal-paper-window-gap' on FRAME."
  (if (or (not brutal-paper-enable-window-margins)
          (zerop brutal-paper-window-gap))
      0
    (max 1
         (round
          (/ (float brutal-paper-window-gap)
             (brutal-paper--frame-character-pixel-width frame))))))

(defun brutal-paper--effective-window-gap (&optional frame)
  "Return the one realized Canvas gutter width used throughout FRAME.
Native outer margins are whole font columns.  Quantize the requested pixel
gap once, then reuse that realizable width for dividers and tab-row spacing."
  (if brutal-paper-enable-window-margins
      (* (brutal-paper--outer-edge-margin-columns frame)
         (brutal-paper--frame-character-pixel-width frame))
    (max 0 brutal-paper-window-gap)))

(defun brutal-paper--face-color (face attribute &optional frame)
  "Return FACE ATTRIBUTE as a concrete colour on FRAME, if available."
  (when (facep face)
    (let ((value (face-attribute face attribute frame t)))
      (unless (member value
                      '(unspecified unspecified-fg unspecified-bg
                        "unspecified" "unspecified-fg" "unspecified-bg"))
        (brutal-paper--canonical-color value frame)))))

(defun brutal-paper--hex-rgb (colour)
  "Return hash-form COLOUR as RGB floats, or nil when it is not valid.
Emacs accepts one through four hexadecimal digits per component."
  (when (and (stringp colour)
             (string-match "\\`#\\([[:xdigit:]]+\\)\\'" colour))
    (let* ((digits (match-string 1 colour))
           (length (length digits))
           (component-width (/ length 3)))
      (when (and (zerop (% length 3))
                 (<= 1 component-width 4))
        (let ((maximum (1- (ash 1 (* 4 component-width)))))
          (cl-loop for offset from 0 below length by component-width
                   collect
                   (/ (string-to-number
                       (substring digits offset (+ offset component-width))
                       16)
                      (float maximum))))))))

(defun brutal-paper--rgb (colour &optional frame)
  "Return COLOUR as RGB floats on FRAME, or nil when it cannot be resolved."
  (or (brutal-paper--hex-rgb colour)
      (when (stringp colour)
        (condition-case nil
            (when-let* ((values (color-values colour frame)))
              (mapcar (lambda (value) (/ value 65535.0)) values))
          (error nil)))))

(defun brutal-paper--canonical-color (colour &optional frame)
  "Return Emacs COLOUR in a portable six-digit form for FRAME.
Named colours and every RGB syntax understood by Emacs are resolved by the
frame before they enter an SVG attribute.  Return nil when FRAME cannot
display COLOUR, allowing callers to use their existing safe fallback."
  (when-let* ((rgb (brutal-paper--rgb colour frame)))
    (apply #'color-rgb-to-hex (append rgb '(2)))))

(defun brutal-paper--argb32 (colour &optional frame)
  "Return opaque ARGB32 for COLOUR on FRAME."
  (if-let* ((rgb (brutal-paper--rgb colour frame)))
      (logior #xff000000
              (ash (round (* 255 (nth 0 rgb))) 16)
              (ash (round (* 255 (nth 1 rgb))) 8)
              (round (* 255 (nth 2 rgb))))
    (error "Cannot resolve canvas colour: %S" colour)))

(defun brutal-paper--paint-canvas
    (data width height background rectangles &optional frame)
  "Paint DATA at WIDTH by HEIGHT with BACKGROUND and RECTANGLES on FRAME.
Each rectangle is (X Y WIDTH HEIGHT COLOUR)."
  (unless (= (length data) (* width height))
    (error "Canvas data size does not match %dx%d" width height))
  (fillarray data (brutal-paper--argb32 background frame))
  (dolist (rectangle rectangles)
    (pcase-let ((`(,x ,y ,rectangle-width ,rectangle-height ,colour)
                 rectangle))
      (let* ((pixel (brutal-paper--argb32 colour frame))
             (pixels (make-vector rectangle-width pixel)))
        (dotimes (row rectangle-height)
          (cl-replace data pixels
                      :start1 (+ x (* (+ y row) width)))))))
  data)

(defun brutal-paper--canvas-image
    (key width height background rectangles &rest properties)
  "Return structural image KEY painted at WIDTH by HEIGHT.
BACKGROUND and RECTANGLES describe its pixels.  PROPERTIES are image
properties.  Emacs 32 reuses and refreshes a Canvas; older Emacs uses SVG."
  (cond
   ((image-type-available-p 'canvas)
    (let* ((cache-key (list key width height properties))
           (signature (list background rectangles))
           (image (gethash cache-key brutal-paper--canvas-image-cache)))
      (if image
          (unless
              (equal signature
                     (gethash image brutal-paper--canvas-image-signatures))
            (let ((data (image-property image :data)))
              (brutal-paper--paint-canvas
               data width height background rectangles)
              (canvas-refresh image 'reload-data))
            (puthash image signature brutal-paper--canvas-image-signatures))
        (let ((data (make-vector (* width height) 0)))
          (brutal-paper--paint-canvas
           data width height background rectangles)
          (setq image
                (apply #'create-image data 'canvas t
                       :id (gensym "brutal-paper-canvas-")
                       :data-width width :data-height height
                       properties))
          (puthash cache-key image brutal-paper--canvas-image-cache)
          (puthash image signature brutal-paper--canvas-image-signatures)))
      image))
   ((image-type-available-p 'svg)
    (let ((svg (svg-create width height)))
      (svg-rectangle svg 0 0 width height :fill background)
      (dolist (rectangle rectangles)
        (pcase-let ((`(,x ,y ,rectangle-width ,rectangle-height ,colour)
                     rectangle))
          (svg-rectangle svg x y rectangle-width rectangle-height
                         :fill colour)))
      (apply #'svg-image svg properties)))))

(defun brutal-paper--mix (background foreground amount)
  "Mix AMOUNT of FOREGROUND into BACKGROUND and return a hex colour."
  (let ((amount (max 0.0 (min 1.0 amount))))
    (when-let* ((background-rgb (brutal-paper--rgb background))
                (foreground-rgb (brutal-paper--rgb foreground)))
      (apply #'color-rgb-to-hex
             (append
              (cl-mapcar (lambda (bg fg)
                           (+ (* bg (- 1 amount)) (* fg amount)))
                         background-rgb foreground-rgb)
              '(2))))))

(defun brutal-paper--relative-luminance (colour &optional frame)
  "Return the WCAG relative luminance of COLOUR on FRAME."
  (when-let* ((rgb (brutal-paper--rgb colour frame)))
    (cl-labels ((linearize
                 (channel)
                 (if (<= channel 0.04045)
                     (/ channel 12.92)
                   (expt (/ (+ channel 0.055) 1.055) 2.4))))
      (+ (* 0.2126 (linearize (nth 0 rgb)))
         (* 0.7152 (linearize (nth 1 rgb)))
         (* 0.0722 (linearize (nth 2 rgb)))))))

(defun brutal-paper--contrast-ratio (first second &optional frame)
  "Return the WCAG contrast ratio between FIRST and SECOND on FRAME."
  (when-let* ((first-luminance
               (brutal-paper--relative-luminance first frame))
              (second-luminance
               (brutal-paper--relative-luminance second frame)))
    (/ (+ (max first-luminance second-luminance) 0.05)
       (+ (min first-luminance second-luminance) 0.05))))

(defun brutal-paper--contrast-mix-candidate
    (colour paper target minimum &optional frame)
  "Mix COLOUR toward TARGET until it reaches MINIMUM against PAPER on FRAME."
  (when (and (>= (or (brutal-paper--contrast-ratio target paper frame) 1.0)
                 minimum)
             (brutal-paper--rgb colour frame)
             (brutal-paper--rgb target frame))
    (let ((low 0.0)
          (high 1.0)
          candidate)
      (dotimes (_ 12)
        (let* ((amount (/ (+ low high) 2.0))
               (mixed (brutal-paper--mix colour target amount))
               (ratio (brutal-paper--contrast-ratio mixed paper frame)))
          (if (and ratio (>= ratio minimum))
              (setq candidate (cons amount mixed)
                    high amount)
            (setq low amount))))
      candidate)))

(defun brutal-paper--ensure-tab-paper-contrast
    (colour paper &optional frame)
  "Return COLOUR adjusted to remain visible against PAPER on FRAME."
  (let ((minimum (max 1.0 (min 21.0 brutal-paper-tab-paper-min-contrast))))
    (if (or (null colour)
            (null paper)
            (>= (or (brutal-paper--contrast-ratio colour paper frame)
                    minimum)
                minimum))
        colour
      (let* ((dark
              (brutal-paper--resolve-color
               brutal-paper-dark-ink-color frame))
             (light
              (brutal-paper--resolve-color
               brutal-paper-light-ink-color frame))
             (candidates
              (delq nil
                    (list
                     (brutal-paper--contrast-mix-candidate
                      colour paper dark minimum frame)
                     (brutal-paper--contrast-mix-candidate
                      colour paper light minimum frame))))
             (best
              (car (sort candidates
                         (lambda (first second)
                           (< (car first) (car second)))))))
        (or (cdr best) colour)))))

(defun brutal-paper--dark-appearance-p (&optional frame)
  "Return non-nil when FRAME realizes a dark editing appearance."
  (let* ((frame (or frame (selected-frame)))
         (real-frame (and (framep frame) frame))
         (background
          (or (brutal-paper--face-color 'default :background real-frame)
              (and real-frame
                   (frame-parameter real-frame 'background-color))))
         (rgb (brutal-paper--rgb background real-frame))
         (mode (or (and real-frame
                        (frame-parameter real-frame 'background-mode))
                   frame-background-mode)))
    (if rgb
        (color-dark-p rgb)
      (eq mode 'dark))))

(defun brutal-paper--resolve-color (colour &optional frame)
  "Resolve COLOUR for FRAME.
COLOUR is either one colour string or `(:light LIGHT :dark DARK)'."
  (brutal-paper--canonical-color
   (cond
    ((stringp colour) colour)
    ((listp colour)
     (plist-get colour
                (if (brutal-paper--dark-appearance-p frame) :dark :light))))
   frame))

(defun brutal-paper--opposite-color (colour &optional frame)
  "Return COLOUR's opposite-appearance member on FRAME, when paired."
  (when (listp colour)
    (brutal-paper--canonical-color
     (plist-get colour
                (if (brutal-paper--dark-appearance-p frame) :light :dark))
     frame)))

(defun brutal-paper--window-background (&optional frame)
  "Return the active editing surface on FRAME."
  (or (and brutal-paper-adapt-to-active-theme
           (brutal-paper--face-color 'default :background frame))
      (brutal-paper--resolve-color
       brutal-paper-window-background-fallback frame)))

(defun brutal-paper--current-tab-index (&optional frame)
  "Return FRAME's zero-based current tab index."
  (let ((frame (or frame (selected-frame))))
    (or
     (when (functionp brutal-paper-tab-model-function)
       (cl-position-if
        (lambda (item) (plist-get item :current))
        (brutal-paper--tab-model-items :tabs frame)))
     (let ((tabs (condition-case nil
                     (with-selected-frame frame (tab-bar-tabs))
                   (error nil))))
       (cl-position-if (lambda (tab) (eq (car-safe tab) 'current-tab)) tabs))
     0)))

(defun brutal-paper--configured-tab-color (index)
  "Return the configured colour specification for zero-based tab INDEX."
  (when brutal-paper-tab-colors
    (nth (mod index (length brutal-paper-tab-colors))
         brutal-paper-tab-colors)))

(defun brutal-paper--tab-base-color (index &optional frame)
  "Return the appearance-matched base colour for tab INDEX on FRAME."
  (let ((frame (or frame (selected-frame))))
    (brutal-paper--ensure-tab-paper-contrast
     (brutal-paper--resolve-color
      (brutal-paper--configured-tab-color index) frame)
     (brutal-paper--window-background frame)
     frame)))

(defun brutal-paper--tab-marker-color (index &optional frame)
  "Return the compact badge colour for tab INDEX on FRAME."
  (let* ((configured (brutal-paper--configured-tab-color index))
         (base (brutal-paper--resolve-color configured frame)))
    (or (brutal-paper--opposite-color configured frame)
        (brutal-paper--readable-ink base frame))))

(defun brutal-paper-canvas-color (&optional frame)
  "Return the structural gap colour for FRAME.
Derive a restrained same-theme colour from the active theme's default
background.  An explicit user colour wins, followed by an embedding
  configuration's `brutal-paper-canvas-color-function'."
  (let ((frame (or frame (selected-frame))))
    (or (brutal-paper--resolve-color brutal-paper-canvas-background frame)
        (and (functionp brutal-paper-canvas-color-function)
             (brutal-paper--resolve-color
              (funcall brutal-paper-canvas-color-function frame) frame))
        (let* ((paper (brutal-paper--window-background frame))
               (tab-color
                (brutal-paper--tab-base-color
                 (brutal-paper--current-tab-index frame) frame))
               (mix (max 0.0 (min 1.0 brutal-paper-canvas-mix))))
          (or (and tab-color
                   (if (= mix 1.0)
                       tab-color
                     (or (brutal-paper--mix paper tab-color mix)
                         tab-color)))
              paper)))))

(defun brutal-paper--foreground-color (&optional frame)
  "Return the active theme's editing ink on FRAME."
  (or (and brutal-paper-adapt-to-active-theme
           (brutal-paper--face-color 'default :foreground frame))
      (brutal-paper--resolve-color
       brutal-paper-foreground-color-fallback frame)))

(defun brutal-paper--accent (&optional frame)
  "Return the selected-theme accent used on FRAME."
  (or (brutal-paper--resolve-color brutal-paper-accent-color frame)
      (brutal-paper--resolve-color brutal-paper-default-accent-color frame)
      (brutal-paper--foreground-color frame)))

(defun brutal-paper--tab-color (index &optional frame)
  "Return the rotating paper colour for zero-based INDEX on FRAME."
  (or (brutal-paper--tab-base-color index frame)
      (brutal-paper--accent frame)))

(defun brutal-paper--shadow-mix-amount (&optional frame)
  "Return the appearance-matched hard-shadow mix amount on FRAME."
  (let ((amount
         (if (numberp brutal-paper-shadow-mix)
             brutal-paper-shadow-mix
           (plist-get
            brutal-paper-shadow-mix
            (if (brutal-paper--dark-appearance-p frame) :dark :light)))))
    (max 0.0 (min 1.0 (if (numberp amount) amount 0.0)))))

(defun brutal-paper--shadow-contrast-score
    (colour paper canvas &optional frame)
  "Return COLOUR's weakest contrast against PAPER and CANVAS on FRAME."
  (min (or (brutal-paper--contrast-ratio colour paper frame) 1.0)
       (or (brutal-paper--contrast-ratio colour canvas frame) 1.0)))

(defun brutal-paper-hard-shadow (&optional frame)
  "Return the hard-shadow ink used on FRAME."
  (let* ((frame (or frame (selected-frame)))
         (canvas (brutal-paper-canvas-color frame))
         (paper (brutal-paper--window-background frame))
         (amount (brutal-paper--shadow-mix-amount frame))
         (dark (brutal-paper--resolve-color brutal-paper-dark-ink-color frame))
         (light
          (brutal-paper--resolve-color brutal-paper-light-ink-color frame))
         (dark-candidate (and dark (brutal-paper--mix canvas dark amount)))
         (light-candidate
          (and light (brutal-paper--mix canvas light amount))))
    (or (brutal-paper--resolve-color brutal-paper-shadow-color frame)
        (cond
         ((null dark-candidate) light-candidate)
         ((null light-candidate) dark-candidate)
         ((> (brutal-paper--shadow-contrast-score
              light-candidate paper canvas frame)
             (brutal-paper--shadow-contrast-score
              dark-candidate paper canvas frame))
          light-candidate)
         (t dark-candidate))
        canvas)))

(defun brutal-paper--readable-ink (background &optional frame)
  "Return black or white ink readable on BACKGROUND for FRAME."
  (let ((rgb (brutal-paper--rgb background frame)))
    (if (and rgb (color-dark-p rgb))
        (brutal-paper--resolve-color brutal-paper-light-ink-color frame)
      (brutal-paper--resolve-color brutal-paper-dark-ink-color frame))))

(brutal-paper--defvisual brutal-paper-tab-font-size 12 'natnum
  "Workspace-tab title font size in SVG pixels.")

(brutal-paper--defvisual brutal-paper-tab-subtitle-font-size 8 'natnum
  "Workspace-tab qualifier font size in SVG pixels.")

(brutal-paper--defvisual brutal-paper-tab-order-font-size 12 'natnum
  "Workspace-tab order badge font size in SVG pixels.")

(brutal-paper--defvisual brutal-paper-tab-left-padding 12 'natnum
  "Leading padding before workspace-tab content in pixels.")

(brutal-paper--defvisual brutal-paper-tab-right-padding 18 'natnum
  "Trailing padding after workspace-tab content in pixels.
The default compensates for the visual weight of the folder shoulder.")

(brutal-paper--defvisual brutal-paper-tab-order-gap 6 'natnum
  "Gap between a workspace tab's order badge and title in pixels.")

(brutal-paper--defvisual brutal-paper-tab-qualifier-gap 2 'natnum
  "Gap between a workspace tab's title and qualifier in pixels.")

(brutal-paper--defvisual brutal-paper-tab-gap 6 'natnum
  "Horizontal gap reserved after each workspace tab in pixels.")

(brutal-paper--defvisual brutal-paper-tab-corner-radius 4 'natnum
  "Corner radius of folder-style workspace tabs in pixels.")

(brutal-paper--defvisual brutal-paper-tab-shoulder-drop 5 'natnum
  "Vertical drop of the folder-tab shoulder in pixels.")

(brutal-paper--defvisual brutal-paper-tab-shoulder-flat-width 6 'natnum
  "Flat width at the right shoulder of a folder tab in pixels.")

(brutal-paper--defvisual brutal-paper-tab-slant-width 9 'natnum
  "Horizontal run of the folder-tab shoulder slant in pixels.")

(brutal-paper--defvisual brutal-paper-tab-row-height 41 'natnum
  "Workspace-tab row height before the bottom Canvas gap in pixels.")

(brutal-paper--defvisual brutal-paper-tab-junction-width 1 'natnum
  "Thickness of the horizontal rule along the parent-tab row.")

(brutal-paper--defvisual brutal-paper-tab-current-top 9 'number
  "Top coordinate of a selected workspace tab in pixels.")

(brutal-paper--defvisual brutal-paper-tab-inactive-top 13 'number
  "Top coordinate of an inactive workspace tab in pixels.")

(brutal-paper--defvisual brutal-paper-tab-order-badge-font-scale 0.875 'number
  "Font-size multiplier used to determine the order badge diameter.")

(brutal-paper--defvisual brutal-paper-tab-order-badge-padding 2 'natnum
  "Extra diameter around workspace-tab order badge text in pixels.")

(brutal-paper--defvisual brutal-paper-tab-order-badge-x-offset 0 'number
  "Extra font-size-relative horizontal correction for order badge text.")

(brutal-paper--defvisual brutal-paper-sub-tab-row-height 24 'natnum
  "Sub-tab content-row height before the bottom Canvas gap, in pixels.")

(brutal-paper--defvisual brutal-paper-sub-tab-font-size 12 'natnum
  "Sub-tab primary-label font size in SVG pixels.")

(brutal-paper--defvisual brutal-paper-sub-tab-subtitle-font-size 10 'natnum
  "Sub-tab subtitle font size in SVG pixels.")

(brutal-paper--defvisual brutal-paper-sub-tab-subtitle-color-mix 0.72 'number
  "Readable-ink strength of sub-tab subtitles.")

(brutal-paper--defvisual brutal-paper-sub-tab-horizontal-padding 10 'natnum
  "Horizontal padding around sub-tab content, in pixels.")

(brutal-paper--defvisual brutal-paper-sub-tab-order-gap 6 'natnum
  "Gap between a sub-tab order number and its name, in pixels.")

(brutal-paper--defvisual brutal-paper-sub-tab-subtitle-gap 6 'natnum
  "Gap between a sub-tab name and subtitle, in pixels.")

(brutal-paper--defvisual brutal-paper-sub-tab-pill-inset 2 'natnum
  "Inset around the selected sub-tab pill, in pixels.")

(brutal-paper--defvisual brutal-paper-sub-tab-separator-height 8 'natnum
  "Height of separators between adjacent sub-tabs, in pixels.")

(brutal-paper--defvisual brutal-paper-sub-tab-separator-color-mix 0.12 'number
  "Readable-ink strength of separators between adjacent sub-tabs.")

(brutal-paper--defvisual brutal-paper-svg-text-width-factor 0.62 'number
  "Fallback average glyph width as a fraction of SVG font size.")

(brutal-paper--defvisual brutal-paper-svg-text-fallback-baseline-ratio 0.22 'number
  "Fallback centered-text baseline shift as a fraction of font size.
Brutal Paper normally derives the shift from the selected font's line height,
ascender, descender, and realized size.  This value is used only when the font
backend cannot provide those metrics.")

(brutal-paper--defvisual brutal-paper-svg-text-optical-bias-ratio 0.25 'number
  "Share of a font's extra line-box height used to lower SVG text.
The extra height is the resolved line height minus the realized font size, so
the adjustment scales with each font rather than adding a fixed pixel offset.
Zero selects geometric centering.")

(brutal-paper--defvisual brutal-paper-window-title-height 45 'natnum
  "Height of each window identity row in pixels.")

(brutal-paper--defvisual brutal-paper-show-window-title-metadata t 'boolean
  "Whether window titles show right-side position, status, mode, and menu data.
This option may be made buffer-local for helper buffers that only need their
window order and buffer title.")

(brutal-paper--defvisual brutal-paper-window-title-block-height 27 'natnum
  "Height of the window title block in pixels.")

(brutal-paper--defvisual brutal-paper-window-title-top 12 'number
  "Top coordinate of the window title block in pixels.")

(brutal-paper--defvisual brutal-paper-window-title-font-size 16 'natnum
  "Window order and buffer-title font size in SVG pixels.")

(brutal-paper--defvisual brutal-paper-window-title-order-gap 8 'natnum
  "Gap between a window's order cell and buffer title in pixels.")

(brutal-paper--defvisual brutal-paper-window-title-padding 8 'natnum
  "Trailing padding of the window title block in pixels.")

(brutal-paper--defvisual brutal-paper-window-title-max-columns 36 'natnum
  "Maximum displayed buffer-title width in character columns.")

(brutal-paper--defvisual brutal-paper-window-meta-font-size 12 'natnum
  "Window metadata font size in SVG pixels.")

(brutal-paper--defvisual brutal-paper-window-meta-horizontal-padding 8 'natnum
  "Total horizontal padding around variable-width metadata in pixels.")

(brutal-paper--defvisual brutal-paper-window-status-width 24 'natnum
  "Width of the window status cell in pixels.")

(brutal-paper--defvisual brutal-paper-window-meta-separator-width 13 'natnum
  "Width reserved for each metadata separator in pixels.")

(brutal-paper--defvisual brutal-paper-window-menu-width 18 'natnum
  "Width of the window menu cell in pixels.")

(brutal-paper--defvisual brutal-paper-window-menu-line-length 10 'natnum
  "Length of each line in the window menu glyph in pixels.")

(brutal-paper--defvisual brutal-paper-window-menu-line-gap 4 'natnum
  "Vertical gap between lines in the window menu glyph in pixels.")

(brutal-paper--defvisual brutal-paper-window-icon-stroke-width 1.5 'number
  "Stroke width of the window menu glyph in pixels.")

(brutal-paper--defvisual brutal-paper-window-separator-stroke-width 1 'number
  "Stroke width of window metadata separators in pixels.")

(brutal-paper--defvisual brutal-paper-window-separator-height 8 'natnum
  "Height of window metadata separators in pixels.")

(brutal-paper--defvisual brutal-paper-window-footer-surface-height 12 'natnum
  "Paper surface height of each window footer in pixels.")

(brutal-paper--defvisual brutal-paper-window-footer-gap-height 12 'natnum
  "Canvas gap height of each window footer in pixels.")
(defun brutal-paper--svg-font-family (family)
  "Return FAMILY quoted for an SVG presentation attribute."
  (format "'%s'" (replace-regexp-in-string "'" "\\\\'" family nil t)))

(defun brutal-paper--font-spec (font &optional frame)
  "Return SVG font attributes from FONT on FRAME.
FONT may be a family name, a face symbol, or nil to follow `default'."
  (let* ((source (if (and (symbolp font) (facep font)) font 'default))
         (family
          (if (stringp font)
              font
            (face-attribute source :family frame 'default)))
         (weight
          (if (stringp font)
              'normal
            (face-attribute source :weight frame 'default)))
         (slant
          (if (stringp font)
              'normal
            (face-attribute source :slant frame 'default))))
    (list :family
          (if (and (stringp family) (not (string-empty-p family)))
              family
            "monospace")
          :weight (if (symbolp weight) weight 'normal)
          :slant (if (symbolp slant) slant 'normal))))

(defun brutal-paper--tab-font-spec (current &optional frame)
  "Return the tab font spec selected by CURRENT on FRAME."
  (brutal-paper--font-spec
   (if current
       brutal-paper-current-tab-font
     brutal-paper-inactive-tab-font)
   frame))

(defun brutal-paper--sub-tab-font-spec (current &optional frame)
  "Return the sub-tab font spec selected by CURRENT on FRAME."
  (let ((source (if current
                    brutal-paper-current-sub-tab-font
                  brutal-paper-inactive-sub-tab-font)))
    (if (eq source :tab)
        (brutal-paper--tab-font-spec current frame)
      (brutal-paper--font-spec source frame))))

(defun brutal-paper--title-font-spec (current &optional frame)
  "Return the window-title font spec selected by CURRENT on FRAME."
  (brutal-paper--font-spec
   (if current
       brutal-paper-current-title-font
     brutal-paper-inactive-title-font)
   frame))

(defun brutal-paper--svg-font-line-metrics (size font &optional frame)
  "Return line metrics for SIZE and FONT on FRAME.
The result is a plist containing `:size', `:height', `:ascent', and
`:descent'.  Return nil when the graphical font backend cannot resolve them."
  (let* ((frame (or frame (selected-frame)))
         (family (plist-get font :family))
         (weight (plist-get font :weight))
         (slant (plist-get font :slant))
         (key (list size family weight slant frame))
         (cached (gethash key brutal-paper--svg-font-metrics-cache 'miss)))
    (if (not (eq cached 'miss))
        (unless (eq cached 'unavailable) cached)
      (let ((metrics
             (condition-case nil
                 (when-let* (((display-graphic-p frame))
                             (entity
                              (find-font
                               (font-spec :family family :size size
                                          :weight weight :slant slant)
                               frame))
                             (opened (open-font entity size frame))
                             (name (font-xlfd-name opened))
                             (info (font-info name frame))
                             ((>= (length info) 10))
                             (actual-size (aref info 2))
                             (height (aref info 3))
                             (ascent (aref info 8))
                             (descent (aref info 9))
                             ((and (numberp actual-size) (> actual-size 0)
                                   (numberp height) (> height 0)
                                   (numberp ascent) (numberp descent))))
                   (list :size actual-size :height height
                         :ascent ascent :descent descent))
               (error nil))))
        (puthash key (or metrics 'unavailable)
                 brutal-paper--svg-font-metrics-cache)
        metrics))))

(defun brutal-paper--svg-font-glyph-metrics
    (text size font &optional frame)
  "Return realized ink metrics for TEXT at SIZE and FONT on FRAME.
The result contains `:size', `:ascent', and `:descent'.  Return nil when the
graphical font backend cannot resolve every required value."
  (let* ((frame (or frame (selected-frame)))
         (family (plist-get font :family))
         (weight (plist-get font :weight))
         (slant (plist-get font :slant))
         (key (list 'glyph text size family weight slant frame))
         (cached (gethash key brutal-paper--svg-font-metrics-cache 'miss)))
    (if (not (eq cached 'miss))
        (unless (eq cached 'unavailable) cached)
      (let ((metrics
             (condition-case nil
                 (when-let* (((display-graphic-p frame))
                             (line-metrics
                              (brutal-paper--svg-font-line-metrics
                               size font frame))
                             (entity
                              (find-font
                               (font-spec :family family :size size
                                          :weight weight :slant slant)
                               frame))
                             (opened (open-font entity size frame))
                             (glyphs
                              (font-get-glyphs
                               opened 0 (length text) text)))
                   (let ((ascent 0)
                         (descent 0)
                         found)
                     (dotimes (index (length glyphs))
                       (when-let* ((glyph (aref glyphs index))
                                   ((>= (length glyph) 9))
                                   (glyph-ascent (aref glyph 7))
                                   (glyph-descent (aref glyph 8))
                                   ((and (numberp glyph-ascent)
                                         (numberp glyph-descent))))
                         (setq found t
                               ascent (max ascent glyph-ascent)
                               descent (max descent glyph-descent))))
                     (when found
                       (list :size (plist-get line-metrics :size)
                             :ascent ascent :descent descent))))
               (error nil))))
        (puthash key (or metrics 'unavailable)
                 brutal-paper--svg-font-metrics-cache)
        metrics))))

(defun brutal-paper--svg-centered-text-y (center size font &optional frame)
  "Return a font-derived, optically balanced SVG baseline around CENTER.
SIZE and FONT select line height, ascender, descender, and realized font size
on FRAME.  Every string with the same font and size therefore shares one
baseline, independently of its particular glyphs."
  (+ center
     (if-let* ((metrics
                (brutal-paper--svg-font-line-metrics size font frame)))
         (let* ((actual-size (plist-get metrics :size))
                (height (plist-get metrics :height))
                (ascent (plist-get metrics :ascent))
                (descent (plist-get metrics :descent))
                (leading (max 0 (- height ascent descent)))
                (optical-bias
                 (* (max 0 (- height actual-size))
                    brutal-paper-svg-text-optical-bias-ratio))
                (baseline-from-top
                 (+ (/ leading 2.0) ascent optical-bias)))
           (* (/ (float size) actual-size)
              (- baseline-from-top (/ height 2.0))))
       (* size brutal-paper-svg-text-fallback-baseline-ratio))))

(defun brutal-paper--svg-centered-visible-text-y
    (center text size font &optional frame)
  "Return the SVG baseline that centers TEXT's realized ink around CENTER."
  (if-let* ((metrics
             (brutal-paper--svg-font-glyph-metrics
              text size font frame)))
      (+ center
         (* (/ (float size) (plist-get metrics :size))
            (/ (- (plist-get metrics :ascent)
                  (plist-get metrics :descent))
               2.0)))
    (brutal-paper--svg-centered-text-y center size font frame)))

(defun brutal-paper--svg-centered-glyph-text-y
    (center text size font &optional frame)
  "Return the SVG baseline that centers compact TEXT around CENTER."
  (brutal-paper--svg-centered-visible-text-y
   center text size font frame))

(defun brutal-paper--svg-text-width
    (text size family &optional weight slant)
  "Return TEXT's clipping-safe SVG width at SIZE in FAMILY, WEIGHT, and SLANT."
  (let* ((sample (propertize text 'face
                             `(:family ,family :height ,(* size 10)
                               :weight ,(or weight 'normal)
                               :slant ,(or slant 'normal))))
         (measured (and (display-graphic-p)
                        (let ((face-remapping-alist nil))
                          (string-pixel-width sample)))))
    (ceiling
     (or measured
         (* (string-width text) size brutal-paper-svg-text-width-factor)))))

(defun brutal-paper--tab-name-parts (name)
  "Return a project and optional qualifier parsed from tab NAME."
  (if (string-match "\\`\\[\\([^]]+\\)\\](\\(.+\\))\\'" name)
      (list (match-string 1 name) (match-string 2 name))
    (list name nil)))

(defun brutal-paper--native-tab-model (&optional frame)
  "Return the default public tab model for FRAME's physical tabs."
  (let ((frame (or frame (selected-frame))))
    (with-selected-frame frame
      (let ((index 0))
        (list
         :tabs
         (mapcar
          (lambda (tab)
            (setq index (1+ index))
            (pcase-let* ((name (or (alist-get 'name tab) ""))
                         (`(,title ,subtitle)
                          (brutal-paper--tab-name-parts name))
                         (target index))
              (list :id target
                    :name title
                    :subtitle subtitle
                    :current (eq (car tab) 'current-tab)
                    :select (lambda ()
                              (interactive)
                              (tab-bar-select-tab target))
                    :help (format "Select tab %s" name))))
          (tab-bar-tabs frame)))))))

(defun brutal-paper--tab-status-spec (status)
  "Return the configured presentation for STATUS, or nil."
  (when-let* ((spec (cdr (assq status brutal-paper-tab-statuses)))
              ((memq (plist-get spec :icon) '(dots check cross dot))))
    spec))

(defun brutal-paper--tab-status-label (status)
  "Return STATUS's fixed-width textual fallback."
  (when-let* ((spec (brutal-paper--tab-status-spec status)))
    (if (eq (plist-get spec :icon) 'dots)
        (format "%-3s" (make-string brutal-paper--tab-status-phase ?.))
      (or (plist-get spec :label) ""))))

(defun brutal-paper--tab-status-cache-phase (status)
  "Return the animation cache phase used by STATUS."
  (and (eq (plist-get (brutal-paper--tab-status-spec status) :icon) 'dots)
       brutal-paper--tab-status-phase))

(defun brutal-paper--valid-tab-item-p (item)
  "Return non-nil when ITEM satisfies the public tab-model interface."
  (and (listp item)
       (plist-member item :id)
       (stringp (plist-get item :name))
       (or (null (plist-get item :subtitle))
           (stringp (plist-get item :subtitle)))
       (or (null (plist-get item :status))
           (brutal-paper--tab-status-spec (plist-get item :status)))
       (or (plist-get item :current)
           (functionp (plist-get item :select)))))

(defun brutal-paper--valid-tab-model-p (model)
  "Return non-nil when MODEL satisfies the public tab-model interface."
  (and (listp model)
       (listp (plist-get model :tabs))
       (cl-every #'brutal-paper--valid-tab-item-p
                 (plist-get model :tabs))
       (or (not (plist-member model :sub-tabs))
           (and (listp (plist-get model :sub-tabs))
                (cl-every #'brutal-paper--valid-tab-item-p
                          (plist-get model :sub-tabs))))))

(defun brutal-paper--consumer-tab-model (&optional frame)
  "Return the validated consumer model for FRAME, or the native model."
  (let ((frame (or frame (selected-frame))))
    (if (not (functionp brutal-paper-tab-model-function))
        (brutal-paper--native-tab-model frame)
      (or (gethash frame brutal-paper--tab-model-cache)
          (let ((model
                 (condition-case nil
                     (funcall brutal-paper-tab-model-function frame)
                   (error nil))))
            (if (brutal-paper--valid-tab-model-p model)
                (puthash frame model brutal-paper--tab-model-cache)
              (brutal-paper--native-tab-model frame)))))))

(defun brutal-paper--tab-model-items (kind &optional frame)
  "Return KIND items from FRAME's current tab model."
  (plist-get (brutal-paper--consumer-tab-model frame) kind))

(defun brutal-paper--tab-bar-background (&optional frame)
  "Return the configured parent tab-bar background on FRAME."
  (let* ((frame (or frame (selected-frame)))
         (value
          (if (functionp brutal-paper-tab-bar-background)
              (funcall
               brutal-paper-tab-bar-background
               (seq-find (lambda (item) (plist-get item :current))
                         (brutal-paper--tab-model-items :tabs frame)))
            brutal-paper-tab-bar-background)))
    (or (brutal-paper--resolve-color value frame)
        (brutal-paper--window-background frame))))

(defun brutal-paper--sub-tabs-visible-p (&optional frame)
  "Return non-nil when FRAME's consumer model has a real sub-tab row."
  (and (functionp brutal-paper-tab-model-function)
       (> (length (brutal-paper--tab-model-items :sub-tabs frame)) 1)))

(defun brutal-paper--native-tab-bar-background (&optional frame)
  "Return the background beneath FRAME's native tab-bar rows."
  (if (brutal-paper--sub-tabs-visible-p frame)
      (brutal-paper-canvas-color frame)
    (brutal-paper--tab-bar-background frame)))

(defun brutal-paper--main-tab-row-gap (&optional frame)
  "Return the bottom gap carried by FRAME's parent-tab row."
  (if (brutal-paper--sub-tabs-visible-p frame)
      0
    (brutal-paper--effective-window-gap frame)))

(defun brutal-paper--tab-item-name (item)
  "Return ITEM encoded for the existing parent-tab renderer."
  (let ((name (plist-get item :name))
        (subtitle (plist-get item :subtitle)))
    (if (and subtitle (not (string-empty-p subtitle)))
        (format "[%s](%s)" name subtitle)
      name)))

(defun brutal-paper--tab-item-as-native-tab (item)
  "Return ITEM in the minimal native shape consumed by the tab renderer."
  (list (if (plist-get item :current) 'current-tab 'tab)
        (cons 'name (brutal-paper--tab-item-name item))
        (cons 'brutal-paper-status (plist-get item :status))))

(defun brutal-paper--tab-color-spec (index current &optional frame)
  "Return colour roles for tab INDEX and CURRENT state on FRAME."
  (let* ((frame (or frame (selected-frame)))
         (paper (brutal-paper--window-background frame))
         (base (brutal-paper--tab-base-color index frame))
         (surface
          (brutal-paper--ensure-tab-paper-contrast
           (if current
               base
             (or (brutal-paper--mix
                  paper base brutal-paper-inactive-tab-color-mix)
                 base))
           paper frame))
         (badge (brutal-paper--tab-marker-color index frame))
         (foreground (brutal-paper--readable-ink surface frame))
         (badge-foreground (brutal-paper--readable-ink badge frame)))
    (list :background surface
          :foreground foreground
          :qualifier (or (brutal-paper--mix
                          surface foreground
                          brutal-paper-tab-qualifier-color-mix)
                         foreground)
          :badge badge
          :badge-foreground badge-foreground
          :border badge)))

(defun brutal-paper--tab-outline-color (spec)
  "Return the outline colour encoded by tab colour SPEC."
  (or (brutal-paper--mix
       (plist-get spec :background)
       (plist-get spec :border)
       brutal-paper-tab-outline-color-mix)
      (plist-get spec :border)))

(defun brutal-paper--current-tab-color-spec (&optional frame)
  "Return the selected parent tab's colour roles on FRAME."
  (let ((frame (or frame (selected-frame))))
    (brutal-paper--tab-color-spec
     (brutal-paper--current-tab-index frame) t frame)))

(defun brutal-paper--paint-tab-row (svg width height &optional gap)
  "Paint SVG at WIDTH by HEIGHT with its bottom Canvas GAP."
  (let* ((gap (if (numberp gap) gap (brutal-paper--main-tab-row-gap)))
         (background (brutal-paper--tab-bar-background))
         (canvas (brutal-paper-canvas-color)))
    (svg-rectangle svg 0 0 width height :fill background)
    (when (> gap 0)
      (svg-rectangle svg 0 (- height gap) width gap :fill canvas)))
  svg)

(defun brutal-paper--tab-junction-color (&optional frame)
  "Return the selected parent tab's outline colour on FRAME."
  (brutal-paper--tab-outline-color
   (brutal-paper--current-tab-color-spec frame)))

(defun brutal-paper--paint-tab-junction
    (svg start-x end-x &optional frame)
  "Paint the parent-row rule on SVG from START-X to END-X.
The selected tab passes its right edge as START-X, keeping its bottom open.
Resolve its colour from FRAME."
  (when (and (> brutal-paper-tab-junction-width 0)
             (> end-x start-x))
    (let ((height (min brutal-paper-tab-junction-width
                       brutal-paper-tab-row-height)))
      ;; A stroked line on the SVG boundary is antialiased into the surface
      ;; underneath it, so differently coloured tabs appear to lose the
      ;; junction.  A pixel-aligned fill stays opaque and touches the sub-row.
      (svg-rectangle svg
                     start-x (- brutal-paper-tab-row-height height)
                     (- end-x start-x) height
                     :class "brutal-paper-tab-junction"
                     :fill (brutal-paper--tab-junction-color frame))))
  svg)

(defun brutal-paper--tab-shape-commands (right top bottom inset close)
  "Return the folder path ending at RIGHT between TOP and BOTTOM.
INSET moves both horizontal edges inward.  CLOSE closes the returned path."
  (let* ((x0 inset)
         (x1 (- right inset))
         (run (- bottom top))
         (drop (min brutal-paper-tab-shoulder-drop (1- run)))
         (shoulder-y (+ top drop))
         (radius (min brutal-paper-tab-corner-radius
                      (/ run 2.0) (/ (- x1 x0) 4.0)))
         (slope-end (- x1 radius brutal-paper-tab-shoulder-flat-width))
         (slope-start (- slope-end brutal-paper-tab-slant-width))
         (transition-radius
          (min radius (/ brutal-paper-tab-slant-width 2.0) (/ drop 2.0)))
         (diagonal-length
          (sqrt (+ (* brutal-paper-tab-slant-width
                      brutal-paper-tab-slant-width)
                   (* drop drop))))
         (diagonal-radius-x
          (* transition-radius
             (/ brutal-paper-tab-slant-width diagonal-length)))
         (diagonal-radius-y (* transition-radius (/ drop diagonal-length))))
    (append
     `((moveto ((,x0 . ,bottom)))
       (lineto ((,x0 . ,(+ top radius))))
       (quadratic-bezier-curveto ((,x0 ,top ,(+ x0 radius) ,top)))
       (lineto ((,(- slope-start transition-radius) . ,top)))
       (quadratic-bezier-curveto
        ((,slope-start ,top
          ,(+ slope-start diagonal-radius-x)
          ,(+ top diagonal-radius-y))))
       (lineto ((,slope-end . ,shoulder-y)))
       (lineto ((,(- x1 radius) . ,shoulder-y)))
       (quadratic-bezier-curveto
        ((,x1 ,shoulder-y ,x1 ,(+ shoulder-y radius))))
       (lineto ((,x1 . ,bottom))))
     (when close '((closepath))))))

(defun brutal-paper--tab-content-center-y ()
  "Return the shared center, compensating for the selected tab's raised top."
  (+ (/ (+ brutal-paper-tab-current-top brutal-paper-tab-row-height) 2.0)
     (/ (- brutal-paper-tab-inactive-top brutal-paper-tab-current-top) 2.0)))

(defun brutal-paper--tab-order-diameter (order font)
  "Return the badge diameter for ORDER rendered with FONT."
  (ceiling
   (max (+ (* brutal-paper-tab-order-font-size
              brutal-paper-tab-order-badge-font-scale)
           brutal-paper-tab-order-badge-padding)
        (+ (brutal-paper--svg-text-width
            order brutal-paper-tab-order-font-size
            (plist-get font :family)
            (plist-get font :weight)
            (plist-get font :slant))
           brutal-paper-tab-order-badge-padding))))

(defun brutal-paper--paint-tab-status
    (svg status x y radius fallback &optional frame)
  "Paint STATUS at the upper-right of the X, Y order badge in SVG."
  (when-let* ((spec (brutal-paper--tab-status-spec status)))
    (let* ((icon (plist-get spec :icon))
           (color
            (or (brutal-paper--face-color
                 (plist-get spec :face) :foreground frame)
                fallback))
           (marker-radius (max 3.0 (min 4.0 (/ radius 2.0))))
           (marker-offset (* radius 0.7))
           (marker-x (+ x marker-offset))
           (marker-y (- y marker-offset))
           (ink (brutal-paper--readable-ink color frame))
           (icon-radius (* marker-radius 0.45))
           (stroke-width (max 1.25 (/ marker-radius 2.5))))
      (svg-circle svg marker-x marker-y marker-radius
                  :fill color :stroke ink :stroke-width 1
                  :class "brutal-paper-tab-status-marker"
                  :data-status (symbol-name status))
      (pcase icon
        ('dots
         (dolist (dot-x (seq-take (list (- marker-x icon-radius)
                                        marker-x
                                        (+ marker-x icon-radius))
                                  brutal-paper--tab-status-phase))
           (svg-circle svg dot-x marker-y (/ marker-radius 7.0)
                       :fill ink :class "brutal-paper-tab-status-icon"
                       :data-status (symbol-name status))))
        ('check
         (svg-polyline
          svg
          (list (cons (- marker-x icon-radius) marker-y)
                (cons (- marker-x (* icon-radius 0.2))
                      (+ marker-y (* icon-radius 0.8)))
                (cons (+ marker-x (* icon-radius 1.2))
                      (- marker-y icon-radius)))
          :fill "none" :stroke ink :stroke-width stroke-width
          :stroke-linecap "round" :stroke-linejoin "round"
          :class "brutal-paper-tab-status-icon"
          :data-status (symbol-name status)))
        ('cross
         (dolist (diagonal '((-1 -1 1 1) (-1 1 1 -1)))
           (svg-line
            svg
            (+ marker-x (* (nth 0 diagonal) icon-radius))
            (+ marker-y (* (nth 1 diagonal) icon-radius))
            (+ marker-x (* (nth 2 diagonal) icon-radius))
            (+ marker-y (* (nth 3 diagonal) icon-radius))
            :stroke ink :stroke-width stroke-width :stroke-linecap "round"
            :class "brutal-paper-tab-status-icon"
            :data-status (symbol-name status))))
        ('dot
         (svg-circle svg marker-x marker-y icon-radius
                     :fill ink :class "brutal-paper-tab-status-icon"
                     :data-status (symbol-name status))))))
  svg)

(defun brutal-paper--parent-tab-widths (tab index)
  "Return (MINIMUM NATURAL) SVG widths for TAB at one-based INDEX."
  (pcase-let* ((current (eq (car tab) 'current-tab))
               (`(,project ,qualifier)
                (brutal-paper--tab-name-parts
                 (or (alist-get 'name tab) "")))
               (font (brutal-paper--tab-font-spec current))
               (family (plist-get font :family))
               (weight (plist-get font :weight))
               (slant (plist-get font :slant))
               (order-diameter
                (brutal-paper--tab-order-diameter
                 (number-to-string index) font))
               (project-width
                (brutal-paper--svg-text-width
                 project brutal-paper-tab-font-size family weight slant))
               (qualifier-width
                (if qualifier
                    (+ brutal-paper-tab-qualifier-gap
                       (brutal-paper--svg-text-width
                        (format "<%s>" qualifier)
                        brutal-paper-tab-subtitle-font-size
                        family weight slant))
                  0))
               (minimum
                (+ brutal-paper-tab-left-padding order-diameter
                   brutal-paper-tab-right-padding brutal-paper-tab-gap))
               (natural
                (+ minimum
                   (if (string-empty-p project)
                       0
                     (+ brutal-paper-tab-order-gap
                        project-width qualifier-width)))))
    (list minimum natural)))

(defun brutal-paper--tab-svg (tab index &optional target-width)
  "Return the folder-style SVG for TAB at INDEX within TARGET-WIDTH.
Nil TARGET-WIDTH preserves the title's natural width."
  (pcase-let* ((current (eq (car tab) 'current-tab))
               (status (alist-get 'brutal-paper-status tab))
               (`(,project ,qualifier)
                (brutal-paper--tab-name-parts
                 (or (alist-get 'name tab) "")))
               (order (number-to-string index))
               (font (brutal-paper--tab-font-spec current))
               (font-family (plist-get font :family))
               (font-weight (plist-get font :weight))
               (font-slant (plist-get font :slant))
               (order-diameter
                (brutal-paper--tab-order-diameter order font))
               (project-width
                (brutal-paper--svg-text-width
                 project brutal-paper-tab-font-size
                 font-family font-weight font-slant))
               (qualifier-text (and qualifier (format "<%s>" qualifier)))
               (qualifier-width
                (if qualifier-text
                    (brutal-paper--svg-text-width
                     qualifier-text brutal-paper-tab-subtitle-font-size
                     font-family font-weight font-slant)
                  0))
               (`(,minimum-width ,natural-width)
                (brutal-paper--parent-tab-widths tab index))
               (width
                (if target-width
                    (max minimum-width
                         (min natural-width (max 1 target-width)))
                  natural-width))
               (title-capacity
                (max 0 (- width minimum-width brutal-paper-tab-order-gap)))
               (full-title-width
                (+ project-width
                   (if qualifier-text
                       (+ brutal-paper-tab-qualifier-gap qualifier-width)
                     0)))
               (rendered-project
                (cond
                 ((string-empty-p project) "")
                 ((<= full-title-width title-capacity) project)
                 (t (brutal-paper--fit-svg-text
                     project brutal-paper-tab-font-size font
                     title-capacity))))
               (rendered-project-width
                (if (string-empty-p rendered-project)
                    0
                  (brutal-paper--svg-text-width
                   rendered-project brutal-paper-tab-font-size
                   font-family font-weight font-slant)))
               (rendered-qualifier
                (and qualifier-text
                     (equal rendered-project project)
                     (<= full-title-width title-capacity)
                     qualifier-text))
               (row-gap (brutal-paper--main-tab-row-gap))
               (height (+ brutal-paper-tab-row-height row-gap))
               (tab-bottom brutal-paper-tab-row-height)
               (right (- width brutal-paper-tab-gap))
               (top (if current brutal-paper-tab-current-top
                      brutal-paper-tab-inactive-top))
               (spec (brutal-paper--tab-color-spec (1- index) current))
               (surface (plist-get spec :background))
               (shadow (brutal-paper--tab-outline-color spec))
               (svg (svg-create width height :overflow "hidden")))
    (brutal-paper--paint-tab-row svg width height row-gap)
    (svg-path svg
              (brutal-paper--tab-shape-commands right top tab-bottom 0 t)
              :fill surface)
    (when current
      (svg-path svg
                (brutal-paper--tab-shape-commands
                 right
                 (+ top (/ brutal-paper-outline-width 2.0))
                 (- tab-bottom (/ brutal-paper-outline-width 2.0))
                 (/ brutal-paper-outline-width 2.0)
                 nil)
                :fill "none" :stroke shadow
                :stroke-width brutal-paper-outline-width
                :stroke-linejoin "round"))
    (brutal-paper--paint-tab-junction
     svg (if current right 0) width)
    (let* ((content-x brutal-paper-tab-left-padding)
           (order-center-x (+ content-x (/ order-diameter 2.0)))
           (content-center-y (brutal-paper--tab-content-center-y))
           (order-center-y content-center-y)
           (project-x (+ content-x order-diameter
                         (if (string-empty-p rendered-project)
                             0
                           brutal-paper-tab-order-gap))))
      (svg-circle svg order-center-x order-center-y
                  (/ order-diameter 2.0)
                  :fill (plist-get spec :badge))
      (brutal-paper--paint-tab-status
       svg status order-center-x order-center-y
       (+ (/ order-diameter 2.0) 2)
       (plist-get spec :border))
      (svg-text svg order
                :x (+ order-center-x
                      (* brutal-paper-tab-order-font-size
                         brutal-paper-tab-order-badge-x-offset))
                :y order-center-y
                :dominant-baseline "middle"
                :font-family
                (brutal-paper--svg-font-family font-family)
                :font-size brutal-paper-tab-order-font-size
                :font-weight (symbol-name font-weight)
                :font-style (symbol-name font-slant)
                :text-anchor "middle"
                :fill (plist-get spec :badge-foreground))
      (unless (string-empty-p rendered-project)
        (svg-text svg rendered-project
                  :x project-x
                  :y content-center-y
                  :dominant-baseline "middle"
                  :font-family
                  (brutal-paper--svg-font-family font-family)
                  :font-size brutal-paper-tab-font-size
                  :font-weight (symbol-name font-weight)
                  :font-style (symbol-name font-slant)
                  :fill (plist-get spec :foreground)))
      (when rendered-qualifier
        (svg-text svg rendered-qualifier
                  :x (+ project-x rendered-project-width
                        brutal-paper-tab-qualifier-gap)
                  :y content-center-y
                  :dominant-baseline "middle"
                  :font-family
                  (brutal-paper--svg-font-family font-family)
                  :font-size brutal-paper-tab-subtitle-font-size
                  :font-weight (symbol-name font-weight)
                  :font-style (symbol-name font-slant)
                  :fill (plist-get spec :qualifier))))
    svg))

(defun brutal-paper--tab-image (tab index &optional target-width)
  "Return a cached folder-style image for TAB at INDEX and TARGET-WIDTH."
  (when (and (display-images-p) (image-type-available-p 'svg))
    (let* ((current (eq (car tab) 'current-tab))
           (key (list tab index target-width
                      (brutal-paper--tab-status-cache-phase
                       (alist-get 'brutal-paper-status tab))
                      (brutal-paper--tab-font-spec current)
                      (brutal-paper--main-tab-row-gap)
                      brutal-paper-tab-junction-width
                      (brutal-paper--tab-junction-color)
                      (brutal-paper--tab-bar-background)
                      (brutal-paper-canvas-color))))
      (or (gethash key brutal-paper--tab-image-cache)
          (puthash key
                   (svg-image (brutal-paper--tab-svg tab index target-width)
                              :ascent 'center)
                   brutal-paper--tab-image-cache)))))

(defun brutal-paper--static-tab-cell
    (display &optional identity mouse-face)
  "Return a non-interactive tab-bar cell showing DISPLAY.
IDENTITY changes the underlying menu label without affecting its display.
MOUSE-FACE defaults to the neutral parent-row hover face."
  (propertize (or identity " ") 'face 'tab-bar
              'mouse-face (or mouse-face 'brutal-paper-tab-hover)
              'display display 'local-map nil 'keymap nil
              'front-sticky nil 'rear-nonsticky t))

(defun brutal-paper--tab-cell-identity (role &rest parts)
  "Return a stable ASCII menu identity for ROLE and PARTS."
  (concat
   "bp-"
   (mapconcat
    (lambda (part) (format "%s" part))
    (cons role parts)
    "-")))

(defun brutal-paper--add-logo-grayscale-filter (svg)
  "Add the unfocused-logo grayscale filter to SVG."
  (let ((saturation
         (number-to-string
          (max 0 (min 1 brutal-paper-unfocused-logo-saturation)))))
    (dom-append-child
     svg
     (dom-node
      'defs nil
      (dom-node
       'filter
       '((id . "brutal-paper-logo-grayscale")
         (color-interpolation-filters . "sRGB"))
       (dom-node
        'feColorMatrix
        `((type . "saturate") (values . ,saturation)))))))
  svg)

(defun brutal-paper--frame-focused-p (&optional frame)
  "Return non-nil unless FRAME is explicitly known to be unfocused."
  (not (null (frame-focus-state (or frame (selected-frame))))))

(defconst brutal-paper--svg-number-regexp
  "[+-]?\\(?:[0-9]+\\(?:\\.[0-9]*\\)?\\|\\.[0-9]+\\)\\(?:[eE][+-]?[0-9]+\\)?"
  "Regular expression matching an SVG number.")

(defun brutal-paper--svg-attribute-value (attributes name)
  "Return NAME's quoted value from SVG root ATTRIBUTES."
  (let ((case-fold-search t))
    (when (string-match
           (concat "[[:space:]]" (regexp-quote name)
                   "[[:space:]]*=[[:space:]]*[\"']"
                   "\\([^\"']+\\)[\"']")
           attributes)
      (match-string 1 attributes))))

(defun brutal-paper--svg-dimension-number (value)
  "Return the positive leading SVG number in dimension VALUE."
  (when (and value
             (string-match
              (concat "\\`[[:space:]]*\\("
                      brutal-paper--svg-number-regexp "\\)")
              value))
    (let ((number (string-to-number (match-string 1 value))))
      (and (> number 0) number))))

(defun brutal-paper--read-svg-aspect-ratio (file)
  "Return FILE's intrinsic SVG aspect ratio, or nil when unavailable."
  (condition-case nil
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (let ((case-fold-search t))
          (when (re-search-forward
                 "<svg\\(?:[[:space:]][^>]*\\)?>" nil t)
            (let* ((attributes (match-string 0))
                   (view-box
                    (brutal-paper--svg-attribute-value
                     attributes "viewBox"))
                   (parts (and view-box
                               (split-string view-box "[[:space:],]+" t)))
                   (view-box-numbers
                    (and (= (length parts) 4)
                         (cl-loop
                          for part in parts
                          when (string-match-p
                                (concat "\\`" brutal-paper--svg-number-regexp
                                        "\\'")
                                part)
                          collect (string-to-number part))))
                   (view-box-width (nth 2 view-box-numbers))
                   (view-box-height (nth 3 view-box-numbers))
                   (width
                    (brutal-paper--svg-dimension-number
                     (brutal-paper--svg-attribute-value attributes "width")))
                   (height
                    (brutal-paper--svg-dimension-number
                     (brutal-paper--svg-attribute-value attributes "height"))))
              (cond
               ((and view-box-width view-box-height
                     (> view-box-width 0) (> view-box-height 0))
                (/ (float view-box-width) view-box-height))
               ((and width height) (/ (float width) height)))))))
    (error nil)))

(defun brutal-paper--logo-intrinsic-aspect-ratio (file)
  "Return FILE's cached intrinsic SVG aspect ratio."
  (let* ((attributes (and (file-readable-p file) (file-attributes file)))
         (signature
          (and attributes
               (list (file-attribute-size attributes)
                     (file-attribute-modification-time attributes))))
         (cached (gethash file brutal-paper--logo-aspect-ratio-cache)))
    (if (and cached (equal (car cached) signature))
        (cadr cached)
      (let ((ratio (and signature
                        (brutal-paper--read-svg-aspect-ratio file))))
        (puthash file (list signature ratio)
                 brutal-paper--logo-aspect-ratio-cache)
        ratio))))

(defun brutal-paper--logo-artwork-layout (file)
  "Return inactive-tab-height, ratio-preserving layout for logo FILE."
  (let* ((inactive-height
          (max 1 (- brutal-paper-tab-row-height
                    brutal-paper-tab-inactive-top)))
         (art-height (min brutal-paper--logo-height inactive-height))
         (ratio (max 0.1
                     (or (brutal-paper--logo-intrinsic-aspect-ratio file) 1.0)))
         (art-width (max 1 (round (* art-height ratio)))))
    (list :cell-width art-width
          :art-width art-width
          :art-height art-height
          :art-x 0)))

(defun brutal-paper--parent-row-leading-width (&optional frame)
  "Return pixels occupied before the first parent tab on FRAME."
  (let ((frame (or frame (selected-frame))))
    (if brutal-paper-show-logo
        (let* ((artwork (or brutal-paper-logo-file
                            brutal-paper--default-logo-artwork))
               (layout (brutal-paper--logo-artwork-layout artwork)))
          (+ (plist-get layout :cell-width)
             (max 0 brutal-paper-logo-horizontal-padding)
             (max 0 brutal-paper-logo-tab-gap)))
      (max 0 (brutal-paper--frame-paper-left-offset frame)))))

(defun brutal-paper--logo-image (&optional frame)
  "Return the Brutal Paper logo cell image for FRAME's workspace row."
  (when (and brutal-paper-show-logo
             (display-images-p)
             (image-type-available-p 'svg))
    (let* ((frame (or frame (selected-frame)))
           (focused (brutal-paper--frame-focused-p frame))
           (artwork (or brutal-paper-logo-file
                        brutal-paper--default-logo-artwork))
           (layout (brutal-paper--logo-artwork-layout artwork))
           (art-height (plist-get layout :art-height))
           (art-width (plist-get layout :art-width))
           (art-x (+ (max 0 brutal-paper-logo-horizontal-padding)
                     (plist-get layout :art-x)))
           (width (+ (plist-get layout :cell-width)
                     (max 0 brutal-paper-logo-horizontal-padding)
                     (max 0 brutal-paper-logo-tab-gap)))
           (gap (brutal-paper--main-tab-row-gap frame))
           (height (+ brutal-paper-tab-row-height gap))
           (svg (svg-create width height))
           (art-y (+ brutal-paper-tab-inactive-top
                     (/ (- brutal-paper-tab-row-height
                           brutal-paper-tab-inactive-top art-height)
                        2.0)
                     brutal-paper-logo-vertical-offset)))
      (brutal-paper--paint-tab-row svg width height gap)
      (when (file-readable-p artwork)
        (unless focused
          (brutal-paper--add-logo-grayscale-filter svg))
        (apply #'svg-embed svg artwork "image/svg+xml" nil
               (append
                (list :x art-x
                      :y art-y :width art-width :height art-height)
                (unless focused
                  '(:filter "url(#brutal-paper-logo-grayscale)")))))
      (brutal-paper--paint-tab-junction svg 0 width frame)
      (svg-image svg :ascent 'center))))

(defun brutal-paper--frame-paper-left-offset (&optional frame)
  "Return the left Canvas inset before FRAME's first paper surface."
  (condition-case nil
      (let* ((frame (or frame (selected-frame)))
             (root-edges
              (window-pixel-edges (frame-root-window frame)))
             (window
              (seq-find
               (lambda (candidate)
                 (= (nth 0 (window-pixel-edges candidate))
                    (nth 0 root-edges)))
               (window-list frame 'no-minibuffer))))
        (if window
            (car (brutal-paper--window-edge-widths window))
          0))
    (error 0)))

(defun brutal-paper--hidden-logo-spacer-image (&optional frame)
  "Return a row spacer aligning the first tab with FRAME's paper edge."
  (when (display-images-p)
    (let* ((frame (or frame (selected-frame)))
           (width (brutal-paper--frame-paper-left-offset frame))
           (gap (brutal-paper--main-tab-row-gap frame))
           (height (+ brutal-paper-tab-row-height gap))
           (background (brutal-paper--tab-bar-background frame))
           (canvas (brutal-paper-canvas-color frame))
           (junction-height
            (min brutal-paper-tab-junction-width
                 brutal-paper-tab-row-height)))
      (when (> width 0)
        (brutal-paper--canvas-image
         (list 'hidden-logo frame)
         width height background
         (append
          (when (> gap 0)
            (list (list 0 brutal-paper-tab-row-height width gap canvas)))
          (when (> junction-height 0)
            (list
             (list 0 (- brutal-paper-tab-row-height junction-height)
                   width junction-height
                   (brutal-paper--tab-junction-color frame)))))
         :ascent 'center)))))

(defun brutal-paper--tab-bar-format-logo ()
  "Return the brand or paper-edge spacer preceding workspace tabs."
  (let* ((frame (selected-frame))
         (focused (brutal-paper--frame-focused-p frame)))
    (if brutal-paper-show-logo
        (when-let* ((image (brutal-paper--logo-image frame)))
          (brutal-paper--static-tab-cell
           image (brutal-paper--tab-cell-identity
                  'logo (if focused 'focused 'unfocused))))
      (when-let* ((spacer (brutal-paper--hidden-logo-spacer-image frame)))
        (brutal-paper--static-tab-cell
         spacer (brutal-paper--tab-cell-identity 'hidden-logo))))))

(defun brutal-paper--tab-menu-item (item index label kind)
  "Return one menu ITEM at INDEX displaying LABEL for row KIND."
  (let* ((current (plist-get item :current))
         (action (if current
                    #'ignore
                  (or (plist-get item :select) #'ignore))))
    (list (intern (format "brutal-paper-%s-%d" kind index))
          'menu-item label action
          :help (or (plist-get item :help) (plist-get item :name)))))

(defun brutal-paper--tab-bar-format-tabs ()
  "Render parent tabs from the current public tab model."
  (let* ((frame (selected-frame))
         (items (brutal-paper--tab-model-items :tabs frame))
         (layout (brutal-paper--parent-tab-layout items frame)))
    (cl-loop
     for entry in layout
     for item = (plist-get entry :item)
     for index = (plist-get entry :index)
     for width = (plist-get entry :width)
     for tab = (brutal-paper--tab-item-as-native-tab item)
     for label = (brutal-paper--tab-name-format tab index width)
     collect (brutal-paper--tab-menu-item item index label 'tab))))

(defun brutal-paper--fit-svg-text (text size font maximum-width)
  "Fit TEXT in MAXIMUM-WIDTH SVG pixels using SIZE and FONT."
  (let* ((family (plist-get font :family))
         (weight (plist-get font :weight))
         (slant (plist-get font :slant))
         (measure
          (lambda (value)
            (brutal-paper--svg-text-width
             value size family weight slant))))
    (cond
     ((<= (funcall measure text) maximum-width) text)
     ((<= maximum-width 0) "")
     (t
      (let* ((ellipsis "…")
             (ellipsis-width (funcall measure ellipsis))
             (low 0)
             (high (length text))
             (best ""))
        (when (<= ellipsis-width maximum-width)
          (while (<= low high)
            (let* ((middle (/ (+ low high) 2))
                   (candidate
                    (concat (substring text 0 middle) ellipsis)))
              (if (<= (funcall measure candidate) maximum-width)
                  (setq best candidate low (1+ middle))
                (setq high (1- middle))))))
        best)))))

(defun brutal-paper--sub-tab-widths (item index)
  "Return (MINIMUM NATURAL) widths for sub-tab ITEM at INDEX."
  (let* ((font (brutal-paper--sub-tab-font-spec
                (plist-get item :current)))
         (family (plist-get font :family))
         (weight (plist-get font :weight))
         (slant (plist-get font :slant))
         (order-width
          (brutal-paper--svg-text-width
           (number-to-string index) brutal-paper-sub-tab-font-size
           family weight slant))
         (ellipsis-width
          (brutal-paper--svg-text-width
           "…" brutal-paper-sub-tab-font-size family weight slant))
         (name-width
          (brutal-paper--svg-text-width
           (plist-get item :name) brutal-paper-sub-tab-font-size
           family weight slant))
         (subtitle (plist-get item :subtitle))
         (subtitle-width
          (if (and subtitle (not (string-empty-p subtitle)))
              (+ brutal-paper-sub-tab-subtitle-gap
                 (brutal-paper--svg-text-width
                  subtitle brutal-paper-sub-tab-subtitle-font-size
                  family weight slant))
            0))
         (fixed (+ (* 2 brutal-paper-sub-tab-horizontal-padding)
                   order-width brutal-paper-sub-tab-order-gap)))
    (list (+ fixed ellipsis-width)
          (+ fixed name-width subtitle-width))))

(defun brutal-paper--shrink-widths-to-fit (widths minimums available)
  "Shrink WIDTHS toward MINIMUMS until they fit AVAILABLE pixels."
  (let ((widths (copy-sequence widths)))
    (if (<= (apply #'+ minimums) available)
        (let ((excess (- (apply #'+ widths) available)))
          (while (> excess 0)
            (let* ((reducible
                    (cl-loop for width in widths
                             for minimum in minimums
                             for index from 0
                             when (> width minimum) collect index))
                   (share (if reducible
                              (max 1 (ceiling (/ (float excess)
                                                 (length reducible))))
                            0)))
              (if (null reducible)
                  (setq excess 0)
                (dolist (index reducible)
                  (let* ((width (nth index widths))
                         (minimum (nth index minimums))
                         (amount (min share (- width minimum) excess)))
                    (setf (nth index widths) (- width amount))
                    (setq excess (- excess amount)))))))
          widths)
      (let* ((count (max 1 (length widths)))
             (base (max 1 (/ available count)))
             (remainder (max 0 (- available (* base count)))))
        (cl-loop for _ in widths
                 for index from 0
                 collect (+ base (if (< index remainder) 1 0)))))))

(defun brutal-paper--visible-parent-tab-entries (entries available)
  "Return a contiguous subset of ENTRIES fitting AVAILABLE pixels.
The current tab is always retained, even when one badge exceeds AVAILABLE."
  (if (or (null entries)
          (<= (apply #'+ (mapcar (lambda (entry) (nth 2 entry)) entries))
              available))
      entries
    (let* ((count (length entries))
           (current
            (or (cl-position-if
                 (lambda (entry) (plist-get (car entry) :current))
                 entries)
                0))
           (prefix-widths (make-vector (1+ count) 0))
           (best-start current)
           (best-end current)
           (best-count 1)
           (best-balance most-positive-fixnum))
      (dotimes (index count)
        (aset prefix-widths (1+ index)
              (+ (aref prefix-widths index)
                 (nth 2 (nth index entries)))))
      (dotimes (start (1+ current))
        (cl-loop
         for end from current below count
         for width = (- (aref prefix-widths (1+ end))
                        (aref prefix-widths start))
         for candidate-count = (1+ (- end start))
         for balance = (abs (- (+ start end) (* 2 current)))
         when (and (<= width available)
                   (or (> candidate-count best-count)
                       (and (= candidate-count best-count)
                            (< balance best-balance))))
         do (setq best-start start
                  best-end end
                  best-count candidate-count
                  best-balance balance)))
      (seq-subseq entries best-start (1+ best-end)))))

(defun brutal-paper--parent-tab-layout (items &optional frame)
  "Return visible responsive parent-tab layout entries for ITEMS on FRAME."
  (let* ((frame (or frame (selected-frame)))
         (entries
          (cl-loop for item in items for index from 1
                   for tab = (brutal-paper--tab-item-as-native-tab item)
                   for pair = (brutal-paper--parent-tab-widths tab index)
                   collect (list item index (car pair) (cadr pair))))
         (leading (brutal-paper--parent-row-leading-width frame))
         (available
          (max 1 (- (frame-inner-width frame) leading
                    (brutal-paper--tab-bar-global-status-width frame))))
         (visible
          (brutal-paper--visible-parent-tab-entries entries available))
         (minimums (mapcar (lambda (entry) (nth 2 entry)) visible))
         (naturals (mapcar (lambda (entry) (nth 3 entry)) visible))
         (usable
          (max (if minimums (apply #'+ minimums) 0) available))
         (widths
          (if (or (null naturals) (<= (apply #'+ naturals) usable))
              naturals
            (brutal-paper--shrink-widths-to-fit
             naturals minimums usable))))
    (cl-mapcar
     (lambda (entry width)
       (list :item (nth 0 entry) :index (nth 1 entry) :width width))
     visible widths)))

(defun brutal-paper--tab-bar-global-status ()
  "Return non-empty `global-mode-string' text for the workspace row."
  (let ((status
         (string-trim
          (mapconcat
           (lambda (item)
             (let ((label (nth 2 item)))
               (if (stringp label) label "")))
           (tab-bar-format-global) ""))))
    (unless (string-empty-p status) status)))

(defun brutal-paper--tab-bar-global-status-width (&optional frame)
  "Return the width reserved for the global workspace-row status on FRAME."
  (if-let* ((status (brutal-paper--tab-bar-global-status)))
      (let ((font (brutal-paper--tab-font-spec t frame)))
        (+ brutal-paper-tab-left-padding brutal-paper-tab-right-padding
           (brutal-paper--svg-text-width
            status brutal-paper-tab-font-size
            (plist-get font :family)
            (plist-get font :weight)
            (plist-get font :slant))))
    0))

(defun brutal-paper--sub-tab-target-widths (items &optional frame)
  "Return responsive widths for sub-tab ITEMS on FRAME."
  (let* ((frame (or frame (selected-frame)))
         (pairs
          (cl-loop for item in items for index from 1
                   collect (brutal-paper--sub-tab-widths item index)))
         (minimums (mapcar #'car pairs))
         (naturals (mapcar #'cadr pairs))
         (leading (max 0 (brutal-paper--frame-paper-left-offset frame)))
         (available (max (length items) (- (frame-inner-width frame) leading))))
    (if (<= (apply #'+ naturals) available)
        naturals
      (brutal-paper--shrink-widths-to-fit naturals minimums available))))

(defun brutal-paper--sub-tab-layout (item index width)
  "Return rendered text geometry for sub-tab ITEM at INDEX and WIDTH."
  (let* ((font (brutal-paper--sub-tab-font-spec
                (plist-get item :current)))
         (family (plist-get font :family))
         (weight (plist-get font :weight))
         (slant (plist-get font :slant))
         (order (number-to-string index))
         (order-width
          (brutal-paper--svg-text-width
           order brutal-paper-sub-tab-font-size family weight slant))
         (name (plist-get item :name))
         (subtitle (or (plist-get item :subtitle) ""))
         (content-width
          (max 0 (- width (* 2 brutal-paper-sub-tab-horizontal-padding)
                    order-width brutal-paper-sub-tab-order-gap)))
         (name-width
          (brutal-paper--svg-text-width
           name brutal-paper-sub-tab-font-size family weight slant))
         (subtitle-width
          (if (string-empty-p subtitle)
              0
            (brutal-paper--svg-text-width
             subtitle brutal-paper-sub-tab-subtitle-font-size
             family weight slant)))
         (show-subtitle
          (and (not (string-empty-p subtitle))
               (<= (+ name-width brutal-paper-sub-tab-subtitle-gap
                      subtitle-width)
                   content-width)))
         (fitted-name
          (brutal-paper--fit-svg-text
           name brutal-paper-sub-tab-font-size font
           (if show-subtitle
               (- content-width brutal-paper-sub-tab-subtitle-gap
                  subtitle-width)
             content-width))))
    (list :width width :font font :order order
          :order-width order-width :name fitted-name
          :name-width
          (brutal-paper--svg-text-width
           fitted-name brutal-paper-sub-tab-font-size family weight slant)
          :subtitle (and show-subtitle subtitle))))

(defun brutal-paper--sub-tab-svg
    (item index width suppress-divider &optional frame)
  "Return the flat secondary SVG for ITEM at INDEX and WIDTH on FRAME.
Omit the trailing separator when SUPPRESS-DIVIDER is non-nil."
  (let* ((frame (or frame (selected-frame)))
         (layout (brutal-paper--sub-tab-layout item index width))
         (font (plist-get layout :font))
         (family (plist-get font :family))
         (weight (plist-get font :weight))
         (slant (plist-get font :slant))
         (row-height (max 1 brutal-paper-sub-tab-row-height))
         (gap (brutal-paper--effective-window-gap frame))
         (height (+ row-height gap))
         (canvas (brutal-paper-canvas-color frame))
         (parent-index (brutal-paper--current-tab-index frame))
         (pill (brutal-paper--tab-marker-color parent-index frame))
         (current (plist-get item :current))
         (status (plist-get item :status))
         (surface (if current pill canvas))
         (ink (brutal-paper--readable-ink surface frame))
         (separator
          (or (brutal-paper--mix
               surface ink brutal-paper-sub-tab-separator-color-mix)
              ink))
         (subtitle-ink
          (or (brutal-paper--mix
               surface ink brutal-paper-sub-tab-subtitle-color-mix)
              ink))
         (center (/ height 2.0))
         (x brutal-paper-sub-tab-horizontal-padding)
         (svg (svg-create width height :overflow "hidden")))
    (svg-rectangle svg 0 0 width height :fill canvas)
    (when current
      (let* ((inset (min brutal-paper-sub-tab-pill-inset
                         (/ row-height 3)
                         (/ (max 0 (1- width)) 2)))
             (pill-height (max 1 (- row-height (* 2 inset))))
             (pill-y
              (max 0
                   (min (- height pill-height)
                        (- center (/ pill-height 2.0))))))
        (svg-rectangle svg inset pill-y
                       (max 1 (- width (* 2 inset))) pill-height
                       :rx (/ pill-height 2.0) :ry (/ pill-height 2.0)
                       :fill surface)))
    (unless suppress-divider
      (let* ((separator-height
              (min height brutal-paper-sub-tab-separator-height))
             (separator-top (- center (/ separator-height 2.0))))
        (svg-line svg
                  (- width 0.5) separator-top
                  (- width 0.5) (+ separator-top separator-height)
                  :stroke separator :stroke-width 1)))
    (brutal-paper--paint-tab-status
     svg status
     (+ x (/ (plist-get layout :order-width) 2.0)) center
     (+ (/ (max (plist-get layout :order-width)
                brutal-paper-sub-tab-font-size)
           2.0)
        1)
     ink frame)
    (svg-text svg (plist-get layout :order)
              :x x
              :y center
              :dominant-baseline "middle"
              :font-family (brutal-paper--svg-font-family family)
              :font-size brutal-paper-sub-tab-font-size
              :font-weight (symbol-name weight)
              :font-style (symbol-name slant) :fill ink)
    (setq x (+ x (plist-get layout :order-width)
               brutal-paper-sub-tab-order-gap))
    (svg-text svg (plist-get layout :name)
              :x x
              :y center
              :dominant-baseline "middle"
              :font-family (brutal-paper--svg-font-family family)
              :font-size brutal-paper-sub-tab-font-size
              :font-weight (symbol-name weight)
              :font-style (symbol-name slant) :fill ink)
    (when-let* ((description (plist-get layout :subtitle)))
      (svg-text svg description
                :x (+ x (plist-get layout :name-width)
                      brutal-paper-sub-tab-subtitle-gap)
                :y center
                :dominant-baseline "middle"
                :font-family (brutal-paper--svg-font-family family)
                :font-size brutal-paper-sub-tab-subtitle-font-size
                :font-weight (symbol-name weight)
                :font-style (symbol-name slant) :fill subtitle-ink))
    svg))

(defun brutal-paper--sub-tab-image
    (item index width suppress-divider &optional frame)
  "Return ITEM's cached secondary image at INDEX and WIDTH on FRAME.
Omit the trailing separator when SUPPRESS-DIVIDER is non-nil."
  (when (and (display-images-p) (image-type-available-p 'svg))
    (let* ((frame (or frame (selected-frame)))
           (key (list item index width suppress-divider
                      (brutal-paper--tab-status-cache-phase
                       (plist-get item :status))
                      (brutal-paper--sub-tab-font-spec
                       (plist-get item :current) frame)
                      (brutal-paper--tab-marker-color
                      (brutal-paper--current-tab-index frame) frame)
                      (brutal-paper--effective-window-gap frame)
                      brutal-paper-sub-tab-row-height
                      brutal-paper-sub-tab-separator-height
                      brutal-paper-sub-tab-separator-color-mix
                      brutal-paper-sub-tab-subtitle-color-mix
                      (brutal-paper-canvas-color frame))))
      (or (gethash key brutal-paper--sub-tab-image-cache)
          (puthash key
                   (svg-image
                    (brutal-paper--sub-tab-svg
                     item index width suppress-divider frame)
                    :ascent 'center)
                   brutal-paper--sub-tab-image-cache)))))

(defun brutal-paper--sub-tab-label
    (item index width suppress-divider &optional frame)
  "Return ITEM's secondary-row label at INDEX and WIDTH on FRAME.
Omit the trailing separator when SUPPRESS-DIVIDER is non-nil."
  (if-let* ((image (brutal-paper--sub-tab-image
                    item index width suppress-divider frame)))
      (propertize (brutal-paper--tab-cell-identity
                   'sub-tab index
                   (if (plist-get item :current) 'current 'inactive))
                  'face 'tab-bar 'mouse-face 'brutal-paper-sub-tab-hover
                  'display image)
    (format " %d%s %s%s " index
            (or (brutal-paper--tab-status-label
                 (plist-get item :status)) "")
            (plist-get item :name)
            (if-let* ((subtitle (plist-get item :subtitle)))
                (format " %s" subtitle)
              ""))))

(defun brutal-paper--sub-tab-row-spacer (width &optional frame)
  "Return a Canvas spacer WIDTH pixels wide for the secondary row on FRAME."
  (when (and (> width 0) (display-images-p))
    (let* ((frame (or frame (selected-frame)))
           (height (+ brutal-paper-sub-tab-row-height
                      (brutal-paper--effective-window-gap frame)))
           (canvas (brutal-paper-canvas-color frame))
           (key (list width height canvas)))
      (or (gethash key brutal-paper--sub-tab-fill-image-cache)
          (puthash
           key
           (brutal-paper--canvas-image
            (list 'sub-tab-row-spacer frame) width height canvas nil
            :ascent 'center)
           brutal-paper--sub-tab-fill-image-cache)))))

(defun brutal-paper--tab-bar-format-sub-tabs ()
  "Render the optional secondary row from the current public tab model."
  (when (brutal-paper--sub-tabs-visible-p)
    (let* ((frame (selected-frame))
           (items (brutal-paper--tab-model-items :sub-tabs frame))
           (widths (brutal-paper--sub-tab-target-widths items frame))
           (leading (max 0 (brutal-paper--frame-paper-left-offset frame)))
           (used leading)
           (result nil))
      (when-let* ((image (brutal-paper--sub-tab-row-spacer leading frame)))
        (push (list 'brutal-paper-sub-tab-leading 'menu-item
                    (brutal-paper--static-tab-cell
                     image (brutal-paper--tab-cell-identity 'sub-tab-leading)
                     'brutal-paper-sub-tab-hover)
                    #'ignore)
              result))
      (cl-loop
       for item in items
       for index from 1
       for width in widths
       for next = (nth index items)
       for suppress-divider = (or (plist-get item :current)
                                  (plist-get next :current)
                                  (null next))
       for label = (brutal-paper--sub-tab-label
                    item index width suppress-divider frame)
       do (setq used (+ used width))
       do (push (brutal-paper--tab-menu-item
                 item index label 'sub-tab)
                result))
      (when-let* ((image
                   (brutal-paper--sub-tab-row-spacer
                    (max 1 (- (frame-inner-width frame) used)) frame)))
        (push (list 'brutal-paper-sub-tab-fill 'menu-item
                    (brutal-paper--static-tab-cell
                     image (brutal-paper--tab-cell-identity 'sub-tab-fill)
                     'brutal-paper-sub-tab-hover)
                    #'ignore)
              result))
      (nreverse result))))

(defun brutal-paper--fill-image (width &optional frame)
  "Return an image WIDTH pixels wide completing the parent row on FRAME."
  (let* ((frame (or frame (selected-frame)))
         (width (max 1 width))
         (gap (brutal-paper--main-tab-row-gap frame))
         (height (+ brutal-paper-tab-row-height gap))
         (background (brutal-paper--tab-bar-background frame))
         (canvas (brutal-paper-canvas-color frame))
         (junction (brutal-paper--tab-junction-color frame))
         (junction-height
          (min brutal-paper-tab-junction-width
               brutal-paper-tab-row-height))
         (status (brutal-paper--tab-bar-global-status))
         (font (and status (brutal-paper--tab-font-spec t frame)))
         (status-foreground
          (and status
               (or (brutal-paper--face-color 'link :foreground frame)
                   (brutal-paper--accent frame))))
         (rectangles
          (append
           (when (> gap 0)
             (list (list 0 brutal-paper-tab-row-height width gap canvas)))
           (when (> junction-height 0)
             (list
              (list 0 (- brutal-paper-tab-row-height junction-height)
                    width junction-height junction)))))
         (key (list width height background canvas
                    brutal-paper-tab-junction-width
                    junction status font status-foreground)))
    (or (gethash key brutal-paper--tab-fill-image-cache)
        (puthash
         key
         (if status
             (let ((svg (svg-create width height)))
               (svg-rectangle svg 0 0 width height :fill background)
               (dolist (rectangle rectangles)
                 (pcase-let ((`(,x ,y ,rectangle-width ,rectangle-height
                                ,colour)
                              rectangle))
                   (svg-rectangle svg x y rectangle-width rectangle-height
                                  :fill colour)))
               (svg-text svg status
                         :x (- width brutal-paper-tab-right-padding)
                         :y (brutal-paper--tab-content-center-y)
                         :dominant-baseline "middle"
                         :font-family
                         (brutal-paper--svg-font-family
                          (plist-get font :family))
                         :font-size brutal-paper-tab-font-size
                         :font-weight (symbol-name (plist-get font :weight))
                         :font-style (symbol-name (plist-get font :slant))
                         :text-anchor "end"
                         :fill status-foreground)
               (svg-image svg :ascent 'center))
           (brutal-paper--canvas-image
            (list 'parent-row-fill frame) width height background rectangles
            :ascent 'center))
         brutal-paper--tab-fill-image-cache))))

(defun brutal-paper--tab-bar-format-fill ()
  "Return the static Canvas fill after the final workspace tab."
  (let* ((frame (selected-frame))
         (items (brutal-paper--tab-model-items :tabs frame))
         (layout (brutal-paper--parent-tab-layout items frame))
         (used (+ (brutal-paper--parent-row-leading-width frame)
                  (apply #'+ 0
                         (mapcar (lambda (entry)
                                   (plist-get entry :width))
                                 layout))))
         (remaining (- (frame-inner-width frame) used)))
    (when (> remaining 0)
      `((brutal-paper-fill menu-item
         ,(brutal-paper--static-tab-cell
           (brutal-paper--fill-image remaining frame)
           (brutal-paper--tab-cell-identity 'parent-fill))
         ignore)))))

(defun brutal-paper--window-order (&optional window)
  "Return WINDOW's one-based order and total as a cons cell."
  (let* ((window (or window (selected-window)))
         (frame (window-frame window))
         (windows (window-list frame 'no-minibuffer
                               (frame-first-window frame)))
         (position (cl-position window windows)))
    (cons (1+ (or position 0)) (max 1 (length windows)))))

(defun brutal-paper--buffer-status ()
  "Return the compact native-style status marker for the current buffer."
  (cond
   ((and buffer-read-only (buffer-modified-p)) "%*")
   (buffer-read-only "%%")
   ((buffer-modified-p) "**")
   (t "--")))

(defun brutal-paper--line-position ()
  "Return current and total line positions for the paper status row."
  (format "%d/%d"
          (line-number-at-pos (point) t)
          (line-number-at-pos (point-max) t)))

(defun brutal-paper--window-edge-widths (&optional window)
  "Return SVG Canvas widths at WINDOW's left and right edges.
The footer SVG spans the complete window, so reproduce its native margin
columns as Canvas before painting the paper surface and shadow.  Margin
columns use the frame font even when the buffer's editing face is remapped."
  (let* ((window (or window (selected-window)))
         (margins (and (window-live-p window) (window-margins window)))
         (column-width
          (max 1
               (or (ignore-errors (frame-char-width (window-frame window)))
                   (ignore-errors (window-font-width window 'default))
                   1))))
    (cons (* (or (car-safe margins) 0) column-width)
          (* (or (cdr-safe margins) 0) column-width))))

(defun brutal-paper--window-complete-pixel-width (&optional window)
  "Return WINDOW's complete width, including margins and fringes."
  (max 1 (or (ignore-errors
               (window-pixel-width (or window (selected-window))))
             1)))

(defun brutal-paper--window-body-pixel-width (&optional window)
  "Return the drawable text-body width of WINDOW in pixels."
  (max 1 (or (ignore-errors
               (window-body-width (or window (selected-window)) t))
             1)))

(defun brutal-paper--canvas-edge-space (width base-face &optional frame)
  "Return WIDTH pixels of Canvas using BASE-FACE metrics on FRAME."
  (if (not (and (numberp width) (> width 0)))
      ""
    (let ((canvas (brutal-paper-canvas-color frame)))
      (propertize
       " "
       'face (list `(:foreground ,canvas :background ,canvas
                      :box nil :overline nil :underline nil)
                   base-face)
       'display `(space :width (,width))))))

(defun brutal-paper--tab-line-left-edge-spacer ()
  "Return outer Canvas followed by alignment to the first text column."
  (let* ((window (selected-window))
         (frame (window-frame window))
         (left (car (brutal-paper--window-edge-widths window))))
    (concat
     (brutal-paper--canvas-edge-space left 'tab-line frame)
     (propertize " " 'face 'tab-line 'display '(space :align-to 0)))))

(defun brutal-paper--tab-line-right-edge-spacer ()
  "Return alignment past the paper fringe and the outer right Canvas."
  (let* ((window (selected-window))
         (frame (window-frame window))
         (right (cdr (brutal-paper--window-edge-widths window))))
    (when (> right 0)
      (concat
       (propertize " " 'face 'tab-line
                   'display '(space :align-to right-margin))
       (brutal-paper--canvas-edge-space right 'tab-line frame)))))

(defun brutal-paper--complete-tab-line (items)
  "Wrap tab-line ITEMS in the current window's outer Canvas margins."
  (let ((items (cons (brutal-paper--tab-line-left-edge-spacer) items)))
    (if-let* ((right (brutal-paper--tab-line-right-edge-spacer)))
        (append items (list right))
      items)))

(defun brutal-paper--window-title-center-y ()
  "Return the optical center of the window-title block."
  (+ brutal-paper-window-title-top
     (/ brutal-paper-window-title-block-height 2.0)))

(defun brutal-paper--window-title-image ()
  "Return the selected window's complete SVG identity and metadata row."
  (when (and (display-images-p) (image-type-available-p 'svg))
    (let* ((window (selected-window))
           (frame (window-frame window))
           (active (mode-line-window-selected-p))
           (show-metadata brutal-paper-show-window-title-metadata)
           (font (brutal-paper--title-font-spec active frame))
           (font-family (plist-get font :family))
           (font-weight (plist-get font :weight))
           (font-slant (plist-get font :slant))
           (order (number-to-string (car (brutal-paper--window-order window))))
           (name (truncate-string-to-width
                  (buffer-name) brutal-paper-window-title-max-columns
                  nil nil "…"))
           (line-position (brutal-paper--line-position))
           (status (brutal-paper--buffer-status))
           (major-name
            (upcase
             (let ((name (string-trim
                          (substring-no-properties
                           (format-mode-line mode-name)))))
               (if (string-empty-p name) (symbol-name major-mode) name))))
           (width (brutal-paper--window-body-pixel-width window))
           (paper (brutal-paper--window-background frame))
           (ink (brutal-paper--foreground-color frame))
           (quiet-ink
            (or (brutal-paper--mix
                 ink paper brutal-paper-window-muted-ink-mix)
                ink))
           (order-background
            (if active
                (brutal-paper--accent frame)
              (brutal-paper--resolve-color
               brutal-paper-window-title-active-background frame)))
           (order-ink (brutal-paper--readable-ink order-background frame))
           (name-background
            (brutal-paper--resolve-color
             (if active
                 brutal-paper-window-title-active-background
               brutal-paper-window-title-inactive-background)
             frame))
           (name-ink (if active ink quiet-ink))
           (order-size brutal-paper-window-title-block-height)
           (name-width
            (brutal-paper--svg-text-width
             name brutal-paper-window-title-font-size
             font-family font-weight font-slant))
           (title-width (+ order-size brutal-paper-window-title-order-gap
                           name-width brutal-paper-window-title-padding))
           (line-width
            (+ brutal-paper-window-meta-horizontal-padding
               (brutal-paper--svg-text-width
                  line-position brutal-paper-window-meta-font-size
                  font-family font-weight font-slant)))
           (status-width brutal-paper-window-status-width)
           (major-width
            (+ brutal-paper-window-meta-horizontal-padding
               (brutal-paper--svg-text-width
                major-name brutal-paper-window-meta-font-size
                font-family font-weight font-slant)))
           (separator-width brutal-paper-window-meta-separator-width)
           (menu-width brutal-paper-window-menu-width)
           (metadata-width (+ line-width status-width major-width menu-width
                              (* 2 separator-width)))
           (compact
            (and show-metadata
                 (> (+ title-width (* 2 brutal-paper-window-title-padding)
                       metadata-width)
                    width)))
           (right-width
            (cond ((not show-metadata) 0)
                  (compact menu-width)
                  (t metadata-width)))
           (right-x (- width right-width))
           (key (list width active order name
                      line-position status major-name paper ink quiet-ink
                      order-background name-background show-metadata compact
                      font-family font-weight font-slant)))
      (or (gethash key brutal-paper--tab-line-image-cache)
          (let* ((svg (svg-create width brutal-paper-window-title-height))
               (center-y (brutal-paper--window-title-center-y))
               (metadata-baseline
                (and show-metadata
                     (brutal-paper--svg-centered-visible-text-y
                      center-y
                      (concat line-position " " status " " major-name)
                      brutal-paper-window-meta-font-size font frame)))
               (title-x 0)
               (name-x (+ title-x order-size
                          brutal-paper-window-title-order-gap)))
          (svg-rectangle svg 0 0 width brutal-paper-window-title-height
                         :fill paper)
          (svg-rectangle svg title-x brutal-paper-window-title-top
                         title-width brutal-paper-window-title-block-height
                         :fill name-background)
          (svg-rectangle svg title-x brutal-paper-window-title-top
                         order-size order-size :fill order-background)
          (svg-text svg order
                    :x (+ title-x (/ order-size 2.0))
                    :y center-y
                    :dominant-baseline "middle"
                    :font-family
                    (brutal-paper--svg-font-family font-family)
                    :font-size brutal-paper-window-title-font-size
                    :font-weight (symbol-name font-weight)
                    :font-style (symbol-name font-slant)
                    :text-anchor "middle" :fill order-ink)
          (svg-text svg name :x name-x
                    :y center-y
                    :dominant-baseline "middle"
                    :font-family
                    (brutal-paper--svg-font-family font-family)
                    :font-size brutal-paper-window-title-font-size
                    :font-weight (symbol-name font-weight)
                    :font-style (symbol-name font-slant)
                    :fill name-ink)
          (let ((cursor right-x))
            (when (and show-metadata (not compact))
              (svg-text svg line-position
                        :x (+ cursor
                              (/ brutal-paper-window-meta-horizontal-padding
                                 2.0))
                        :y metadata-baseline
                        :font-family
                        (brutal-paper--svg-font-family font-family)
                        :font-size brutal-paper-window-meta-font-size
                        :font-weight (symbol-name font-weight)
                        :font-style (symbol-name font-slant)
                        :fill (if active ink quiet-ink))
              (setq cursor (+ cursor line-width))
              (setq cursor (+ cursor (/ separator-width 2.0)))
              (svg-line
               svg cursor
               (- center-y (/ brutal-paper-window-separator-height 2.0))
               cursor
               (+ center-y (/ brutal-paper-window-separator-height 2.0))
               :stroke quiet-ink
               :stroke-width brutal-paper-window-separator-stroke-width)
              (setq cursor (+ cursor (/ separator-width 2.0)))
              (svg-text svg status :x (+ cursor (/ status-width 2.0))
                        :y metadata-baseline
                        :font-family
                        (brutal-paper--svg-font-family font-family)
                        :font-size brutal-paper-window-meta-font-size
                        :font-weight (symbol-name font-weight)
                        :font-style (symbol-name font-slant)
                        :text-anchor "middle"
                        :fill (if active ink quiet-ink))
              (setq cursor (+ cursor status-width))
              (setq cursor (+ cursor (/ separator-width 2.0)))
              (svg-line
               svg cursor
               (- center-y (/ brutal-paper-window-separator-height 2.0))
               cursor
               (+ center-y (/ brutal-paper-window-separator-height 2.0))
               :stroke quiet-ink
               :stroke-width brutal-paper-window-separator-stroke-width)
              (setq cursor (+ cursor (/ separator-width 2.0)))
              (svg-text svg major-name :x (+ cursor (/ major-width 2.0))
                        :y metadata-baseline
                        :font-family
                        (brutal-paper--svg-font-family font-family)
                        :font-size brutal-paper-window-meta-font-size
                        :font-weight (symbol-name font-weight)
                        :font-style (symbol-name font-slant)
                        :text-anchor "middle"
                        :fill (if active ink quiet-ink))
              (setq cursor (+ cursor major-width)))
            (let ((menu-center (+ cursor (/ menu-width 2.0))))
              (dolist (offset
                       (and show-metadata
                            (list (- brutal-paper-window-menu-line-gap)
                                  0 brutal-paper-window-menu-line-gap)))
                (svg-line svg
                          (- menu-center
                             (/ brutal-paper-window-menu-line-length 2.0))
                          (+ center-y offset)
                          (+ menu-center
                             (/ brutal-paper-window-menu-line-length 2.0))
                          (+ center-y offset)
                          :stroke (if active ink quiet-ink)
                          :stroke-width
                          brutal-paper-window-icon-stroke-width))))
          (puthash key (svg-image svg :ascent 'center :scale 1)
                   brutal-paper--tab-line-image-cache))))))

(defun brutal-paper--window-footer-shadow-geometry
    (width surface-height gap-height left-edge-width right-edge-width
           right-divider)
  "Return the hard-shadow rectangle inside complete footer WIDTH.
SURFACE-HEIGHT precedes the Canvas footer of GAP-HEIGHT pixels.
LEFT-EDGE-WIDTH and RIGHT-EDGE-WIDTH are outer Canvas strips; RIGHT-DIVIDER is
the inter-window Canvas following this paper window.  Return nil when the
footer cannot contain the configured hard shadow."
  (let* ((depth brutal-paper-shadow-depth)
         (paper-width
          (- width left-edge-width right-edge-width right-divider)))
    (when (and brutal-paper-enable-window-shadow
               (>= gap-height depth)
               (> paper-width depth))
      (list :x (+ left-edge-width depth)
            :y surface-height
            ;; Stop at the paper's own right edge so the native outer margin
            ;; remains aligned on every supported Emacs release.
            :width (- paper-width depth)
            :height depth))))

(defun brutal-paper--window-footer-image ()
  "Return the exact paper and Canvas footer image for the current window."
  (when (display-images-p)
    (let* ((window (selected-window))
           (frame (window-frame window))
           (active (mode-line-window-selected-p))
           (width (brutal-paper--window-complete-pixel-width window))
           (edges (brutal-paper--window-edge-widths window))
           (left-edge (car edges))
           (right-edge (cdr edges))
           (right-divider
            (or (ignore-errors (window-right-divider-width window)) 0))
           (paper (brutal-paper--window-background frame))
           (canvas (brutal-paper-canvas-color frame))
           (shadow (brutal-paper-hard-shadow frame))
           (surface brutal-paper-window-footer-surface-height)
           (gap brutal-paper-window-footer-gap-height)
           (height (+ surface gap))
           (shadow-geometry
            (brutal-paper--window-footer-shadow-geometry
             width surface gap left-edge right-edge right-divider))
           (key (list width left-edge right-edge right-divider active
                      paper canvas shadow surface gap shadow-geometry)))
      (or (gethash key brutal-paper--mode-line-image-cache)
          (puthash
           key
           (brutal-paper--canvas-image
            (list 'window-footer frame left-edge right-edge right-divider
                  active shadow-geometry)
            width height paper
            (append
             (when (> left-edge 0)
               (list (list 0 0 left-edge surface canvas)))
             (when (> right-edge 0)
               (list
                (list (- width right-edge) 0 right-edge surface canvas)))
             (when (> gap 0)
               (list (list 0 surface width gap canvas)))
             (when (and active shadow-geometry)
               (list
                (list (plist-get shadow-geometry :x)
                      (plist-get shadow-geometry :y)
                      (plist-get shadow-geometry :width)
                      (plist-get shadow-geometry :height)
                      shadow))))
            :ascent 'center :scale 1)
           brutal-paper--mode-line-image-cache)))))

(defun brutal-paper--tab-line ()
  "Return the current window's Brutal Paper identity and status row."
  (brutal-paper--complete-tab-line
   (if-let* ((image (brutal-paper--window-title-image)))
       (list (propertize " " 'face 'tab-line 'display image))
     (list
      (if brutal-paper-show-window-title-metadata
          (format " %d  %s  %s  %s "
                  (car (brutal-paper--window-order))
                  (buffer-name) (brutal-paper--line-position)
                  (brutal-paper--buffer-status))
        (format " %d  %s "
                (car (brutal-paper--window-order)) (buffer-name)))))))

(defun brutal-paper--mode-line ()
  "Return a content-free paper footer with a hard lower shadow."
  (if-let* ((image (brutal-paper--window-footer-image)))
      (propertize " " 'face 'brutal-paper-footer-active 'display image)
    (propertize " " 'face 'brutal-paper-footer-active)))

(defun brutal-paper--tab-name-format (tab index &optional target-width)
  "Return TAB at INDEX as an SVG cell constrained to TARGET-WIDTH."
  (if-let* ((image (brutal-paper--tab-image tab index target-width)))
      (brutal-paper--static-tab-cell
       image
       (brutal-paper--tab-cell-identity
        'parent-tab index
        (if (eq (car tab) 'current-tab) 'current 'inactive)))
    (format " [%d%s] %s " index
            (or (brutal-paper--tab-status-label
                 (alist-get 'brutal-paper-status tab)) "")
            (or (alist-get 'name tab) ""))))

(defun brutal-paper--tab-face (tab)
  "Return the neutral native face beneath TAB's complete SVG image."
  (ignore tab)
  `(:inherit tab-bar :background ,(brutal-paper--tab-bar-background)
    :box nil :overline nil :underline nil))

(defun brutal-paper--variable-state (variable)
  "Return VARIABLE's default binding as a restorable value."
  (if (default-boundp variable)
      (list t (copy-tree (default-value variable)))
    '(nil)))

(defun brutal-paper--save-variable-values ()
  "Capture native variables before the current mode session changes them."
  (unless brutal-paper--saved-variable-values
    (setq brutal-paper--saved-variable-values
          (mapcar
           (lambda (setting)
             (cons (car setting)
                   (brutal-paper--variable-state (car setting))))
           brutal-paper--managed-variable-values))))

(defun brutal-paper--apply-variable-values ()
  "Install the native renderer variables owned by Brutal Paper."
  (dolist (setting brutal-paper--managed-variable-values)
    (set-default (car setting) (copy-tree (cadr setting)))))

(defun brutal-paper--restore-variable-values ()
  "Restore native renderer variables captured by Brutal Paper."
  (dolist (entry brutal-paper--saved-variable-values)
    (if (car (cdr entry))
        (set-default (car entry) (copy-tree (cadr (cdr entry))))
      (makunbound (car entry))))
  (setq brutal-paper--saved-variable-values nil))

(defun brutal-paper--theme-setting-p (theme kind name)
  "Return non-nil when THEME contains a KIND setting for NAME."
  (seq-some
   (lambda (setting)
     (and (consp setting)
          (eq (car setting) kind)
          (eq (cadr setting) name)))
   (get theme 'theme-settings)))

(defun brutal-paper--refresh-saved-variables-for-theme (theme)
  "Update variable underlays changed by THEME before reapplying chrome."
  (dolist (entry brutal-paper--saved-variable-values)
    (when (brutal-paper--theme-setting-p theme 'theme-value (car entry))
      (setcdr entry (brutal-paper--variable-state (car entry))))))

(defun brutal-paper--face-attribute-values (face &optional frame)
  "Return directly specified attributes for FACE on FRAME."
  (condition-case nil
      (cl-mapcan
       (lambda (attribute)
         (list attribute (face-attribute face attribute frame nil)))
       brutal-paper--mutated-face-attributes)
    (error nil)))

(defun brutal-paper--saved-face-entry (face frame)
  "Return the saved entry for FACE on FRAME, if any."
  (cl-find-if
   (lambda (entry)
     (and (eq (nth 0 entry) frame)
          (eq (nth 1 entry) face)))
   brutal-paper--saved-face-attributes))

(defun brutal-paper--save-face-attributes (face &optional frame)
  "Save FACE's directly specified attributes on FRAME once per session."
  (when (and brutal-paper--modes-active
             (facep face)
             (not (brutal-paper--saved-face-entry face frame)))
    (when-let* ((attributes (brutal-paper--face-attribute-values face frame)))
      (push (list frame face attributes)
            brutal-paper--saved-face-attributes))))

(defun brutal-paper--refresh-saved-faces-for-theme (theme)
  "Update face underlays changed by THEME before reapplying chrome."
  (dolist (entry brutal-paper--saved-face-attributes)
    (when (brutal-paper--theme-setting-p theme 'theme-face (nth 1 entry))
      (when-let* ((attributes
                   (brutal-paper--face-attribute-values
                    (nth 1 entry) (nth 0 entry))))
        (setf (nth 2 entry) attributes)))))

(defun brutal-paper--restore-face-attributes ()
  "Restore every face value saved by the current enable session."
  (dolist (entry brutal-paper--saved-face-attributes)
    (let ((frame (nth 0 entry))
          (face (nth 1 entry))
          (attributes (nth 2 entry)))
      (when (and (facep face)
                 (or (null frame) (frame-live-p frame)))
        (condition-case nil
            (apply #'set-face-attribute face frame attributes)
          (error nil)))))
  (setq brutal-paper--saved-face-attributes nil))

(defun brutal-paper--save-global-face-attributes ()
  "Save global faces before Brutal Paper applies structural attributes."
  (dolist (face brutal-paper--mutated-faces)
    (brutal-paper--save-face-attributes face)))

(defun brutal-paper--apply-face (face foreground background &optional frame)
  "Apply structural FOREGROUND and BACKGROUND to FACE on FRAME."
  (when (facep face)
    (brutal-paper--save-face-attributes face frame)
    (set-face-attribute face frame
                        :inherit nil
                        :foreground (or foreground 'unspecified)
                        :background background
                        :box nil
                        :underline nil
                        :overline nil)))

(defun brutal-paper--apply-chrome-face
    (face foreground background &optional box height weight frame)
  "Apply paper chrome FACE with FOREGROUND and BACKGROUND on FRAME.
BOX, HEIGHT, and WEIGHT supply optional face traits."
  (when (facep face)
    (brutal-paper--save-face-attributes face frame)
    (set-face-attribute face frame
                        :inherit 'default
                        :foreground foreground
                        :background background
                        :box box
                        :height (or height 'unspecified)
                        :weight (or weight 'unspecified)
                        :underline nil
                        :overline nil)))

(defun brutal-paper--apply-faces (&optional frame)
  "Apply Brutal Paper structural faces globally and to FRAME."
  (let* ((window-background (brutal-paper--window-background frame))
         (tab-bar-background (brutal-paper--tab-bar-background frame))
         (foreground (brutal-paper--foreground-color frame))
         (canvas (brutal-paper-canvas-color frame))
         (native-tab-bar-background
          (brutal-paper--native-tab-bar-background frame))
         (accent (brutal-paper--accent frame))
         (shadow (brutal-paper-hard-shadow frame))
         (muted-background
          (or (brutal-paper--mix
               window-background canvas
               brutal-paper-chrome-muted-background-mix)
              canvas))
         (muted-foreground
          (or (brutal-paper--mix
               foreground window-background
               brutal-paper-chrome-muted-foreground-mix)
              foreground)))
    (dolist (face brutal-paper--mutated-faces)
      (brutal-paper--save-face-attributes face frame))
    (dolist (face '(internal-border vertical-border window-divider
                    window-divider-first-pixel window-divider-last-pixel
                    margin))
      (brutal-paper--apply-face face canvas canvas frame))
    ;; Fringes are paper padding around each editing body.  Continuation and
    ;; truncation bitmaps use this face's foreground, so keep those structural
    ;; markers visible in muted ink instead of leaking the editor's black text
    ;; colour into every wrapped line.  The divider alone owns the inter-window
    ;; Canvas gap, so two adjacent fringes do not inflate it.  Neither operation
    ;; changes the default face or its font.
    (when (facep 'fringe)
      (set-face-attribute 'fringe frame
                          :foreground muted-foreground
                          :background window-background))
    ;; The SVG occupies the text body, but Emacs paints each mode line's
    ;; native margin cells from these faces.  Set their background explicitly
    ;; so a later colour theme cannot leave gray blocks at the footer corners.
    (dolist (face '(mode-line mode-line-active mode-line-inactive))
      (when (facep face)
        (set-face-attribute face frame
                            :background canvas
                            :box nil
                            :underline nil
                            :overline nil)))
    ;; Emacs 32 leaves one native baseline pixel between tab-bar rows.  Use the
    ;; Canvas there so it cannot close the current parent tab's opening.
    (when (facep 'tab-bar)
      (set-face-attribute 'tab-bar frame
                          :background native-tab-bar-background
                          :box nil
                          :underline nil
                          :overline nil))
    (brutal-paper--apply-face
     'brutal-paper-tab-hover foreground tab-bar-background frame)
    (brutal-paper--apply-face
     'brutal-paper-sub-tab-hover foreground canvas frame)
    ;; Native title cells are the paper padding outside the SVG body.
    (when (facep 'tab-line)
      (set-face-attribute 'tab-line frame
                          :background window-background
                          :box nil
                          :underline nil
                          :overline nil))
    (when (facep 'brutal-paper-canvas)
      (brutal-paper--apply-face 'brutal-paper-canvas nil canvas frame))
    (when (facep 'brutal-paper-shadow)
      (brutal-paper--apply-face 'brutal-paper-shadow shadow shadow frame))
    (brutal-paper--apply-chrome-face
     'brutal-paper-tab-bar foreground tab-bar-background nil nil nil frame)
    (brutal-paper--apply-chrome-face
     'brutal-paper-tab-current foreground window-background
     nil nil nil frame)
    (brutal-paper--apply-chrome-face
     'brutal-paper-tab-inactive muted-foreground muted-background
     nil nil nil frame)
    (dolist (face '(brutal-paper-tab-bar brutal-paper-tab-current
                    brutal-paper-tab-inactive))
      (when (facep face)
        (set-face-attribute face frame
                            :box nil)))
    (brutal-paper--apply-chrome-face
     'brutal-paper-window-line foreground window-background nil nil nil frame)
    (brutal-paper--apply-chrome-face
     'brutal-paper-window-order-active
     (brutal-paper--readable-ink accent frame) accent nil nil 'bold frame)
    (brutal-paper--apply-chrome-face
     'brutal-paper-window-order-inactive
     muted-foreground muted-background nil nil 'bold frame)
    (brutal-paper--apply-chrome-face
     'brutal-paper-window-title-active
     foreground window-background nil nil 'bold frame)
    (brutal-paper--apply-chrome-face
     'brutal-paper-window-title-inactive
     muted-foreground window-background nil nil nil frame)
    (brutal-paper--apply-chrome-face
     'brutal-paper-window-meta-active
     foreground window-background nil nil nil frame)
    (brutal-paper--apply-chrome-face
     'brutal-paper-window-meta-inactive
     muted-foreground window-background nil nil nil frame)
    (brutal-paper--apply-chrome-face
     'brutal-paper-footer-active foreground canvas
     nil nil nil frame)
    (brutal-paper--apply-chrome-face
     'brutal-paper-footer-inactive muted-foreground canvas
     nil nil nil frame)
    canvas))

(defun brutal-paper--echo-area-buffer-p (&optional buffer)
  "Return non-nil when BUFFER belongs to the minibuffer or echo area."
  (let ((buffer (or buffer (current-buffer))))
    (or (minibufferp buffer)
        (member (buffer-name buffer)
                brutal-paper--echo-area-buffer-names))))

(defun brutal-paper--active-isearch-buffer ()
  "Return the buffer owning a live isearch session, if any."
  (when-let* ((buffer
               (and (boundp 'isearch--current-buffer)
                    (symbol-value 'isearch--current-buffer)))
              ((buffer-live-p buffer)))
    (and (with-current-buffer buffer
           (and (boundp 'isearch-mode)
                (symbol-value 'isearch-mode)))
         buffer)))

(defun brutal-paper--style-echo-area-unless-isearch (frame)
  "Style FRAME's echo area unless isearch owns its read-only message."
  (unless (brutal-paper--active-isearch-buffer)
    (brutal-paper--style-echo-area frame)))

(defun brutal-paper--echo-area-face-remap-live-p (cookie face)
  "Return non-nil when COOKIE still remaps FACE in this buffer."
  (and cookie
       (memq (cdr cookie) (cdr (assq face face-remapping-alist)))))

(defun brutal-paper--echo-area-remap-live-p ()
  "Return non-nil when this buffer still owns its paper remap."
  (brutal-paper--echo-area-face-remap-live-p
   brutal-paper--echo-area-remap-cookie 'default))

(defun brutal-paper--echo-area-padding-spacer
    (background image-height &optional ascent image-width fallback-background)
  "Return an exact-height structural image on BACKGROUND.
IMAGE-HEIGHT is the canvas raster height.  A normally terminated inline row also
has a one-pixel baseline; a `line-height' t structural row uses the image's
exact height.  ASCENT defaults to 100; zero extends the current line below its
baseline.  IMAGE-WIDTH defaults to one pixel.  FALLBACK-BACKGROUND is shown
until the image is realized."
  (let* ((width (max 1 (or image-width 1)))
         (height (max 1 image-height)))
    (propertize
     " "
     'display
     (brutal-paper--canvas-image
      (list 'echo-area-padding (selected-frame) (current-buffer))
      width height background nil :ascent (or ascent 100) :scale 1)
     'face `(:height 1 :background ,(or fallback-background background)
                     :extend t)
     'cursor-intangible t)))

(defun brutal-paper--minibuffer-input-prefix (background)
  "Return horizontal minibuffer padding on BACKGROUND.
The width-only display spec cannot alter the prompt row's font metrics."
  (let ((width (max 1 brutal-paper-fringe-width)))
    ;; A specified `(space :width ...)' still contributes the default font's
    ;; ascent on NS Emacs.  Use a one-pixel-high surface so this horizontal
    ;; prefix cannot enlarge the cursor-free top spacer; prompt text continues
    ;; to determine the real input row's native line box.
    (brutal-paper--echo-area-padding-spacer
     background 1 100 width background)))

(defun brutal-paper--default-font-info (&optional frame)
  "Return realized default-font metrics for FRAME, or nil."
  (when-let* ((font (face-font 'default frame)))
    (font-info font frame)))

(defun brutal-paper--default-font-pixel-size (&optional frame)
  "Return the realized default font pixelsize for FRAME."
  (let ((metrics (brutal-paper--default-font-info frame)))
    (if (and (vectorp metrics)
             (> (length metrics) 2)
             (numberp (aref metrics 2))
             (> (aref metrics 2) 0))
        (aref metrics 2)
      ;; Font backends normally provide SIZE.  Keep a proportional graphical
      ;; fallback instead of coupling vertical padding to window geometry.
      (max 1 (round (* (default-line-height) (/ 2.0 3.0)))))))

(defun brutal-paper--default-font-space-width (&optional frame)
  "Return the realized default-font space width for FRAME."
  (let ((metrics (brutal-paper--default-font-info frame)))
    (if (and (vectorp metrics)
             (> (length metrics) 10)
             (numberp (aref metrics 10))
             (> (aref metrics 10) 0))
        (aref metrics 10)
      (max 1 (frame-char-width frame)))))

(defun brutal-paper--minibuffer-right-padding-columns (&optional frame)
  "Return the completion text inset before FRAME's right Paper edge."
  (if (numberp brutal-paper-minibuffer-right-padding)
      (max 0 brutal-paper-minibuffer-right-padding)
    (if (zerop brutal-paper-fringe-width)
        0
      (max 1
           (round
            (/ (float brutal-paper-fringe-width)
               (brutal-paper--default-font-space-width frame)))))))

(defun brutal-paper--marginalia-align-around (function candidates)
  "Call FUNCTION for CANDIDATES with a Paper-safe right alignment.
Marginalia exposes its right-edge offset as a dynamic option.  Move that
anchor left while an active Brutal Paper minibuffer is being formatted, rather
than shrinking the minibuffer body with a native window margin."
  (let ((window (active-minibuffer-window)))
    (if (and brutal-paper-enable-echo-area
             brutal-paper-mode
             (window-live-p window)
             (boundp 'marginalia-align)
             (eq (symbol-value 'marginalia-align) 'right)
             (boundp 'marginalia-align-offset))
        (let* ((frame (window-frame window))
               (offset (symbol-value 'marginalia-align-offset))
               (padding
                (brutal-paper--minibuffer-right-padding-columns frame)))
          (cl-progv '(marginalia-align-offset)
              (list (- (if (numberp offset) offset 0) padding))
            (funcall function candidates)))
      (funcall function candidates))))

(defun brutal-paper--install-marginalia-alignment-advice ()
  "Install the optional Marginalia text-alignment adapter once."
  (unless (advice-member-p
           #'brutal-paper--marginalia-align-around 'marginalia--align)
    (advice-add 'marginalia--align :around
                #'brutal-paper--marginalia-align-around)))

(defun brutal-paper--after-load (&rest _)
  "Install optional adapters for features loaded during an active session."
  (when (and brutal-paper-mode (featurep 'marginalia))
    (brutal-paper--install-marginalia-alignment-advice)))

(defun brutal-paper--minibuffer-vertical-padding-height (&optional frame)
  "Return one font-relative Paper inset for FRAME's active minibuffer."
  (max 0
       (ceiling
        (* (brutal-paper--default-font-pixel-size frame)
           brutal-paper-minibuffer-vertical-padding-ratio))))

(defun brutal-paper--minibuffer-top-padding-row (background &optional frame)
  "Return a BACKGROUND spacer row above FRAME's native prompt row."
  (let ((height (brutal-paper--minibuffer-vertical-padding-height frame)))
    (when (> height 0)
      (concat
       (when (> height 1)
         (propertize
          (brutal-paper--echo-area-padding-spacer
           background height 100)
          'brutal-paper-echo-top-spacer t))
       (propertize
        "\n"
        'face `(:height 1 :background ,background :extend t)
        ;; Ignore the newline's default-font strut: the preceding image alone
        ;; owns this cursor-free structural row's exact height.  The native
        ;; prompt row keeps its untouched font metrics and cursor placement.
        'line-height t
        'brutal-paper-echo-top-spacer t
        'cursor-intangible t)))))

(defun brutal-paper--remove-minibuffer-input-inset ()
  "Restore the line prefix replaced by Brutal Paper in this minibuffer."
  (when (overlayp brutal-paper--active-minibuffer-top-padding-overlay)
    (delete-overlay brutal-paper--active-minibuffer-top-padding-overlay))
  (dolist (overlay
           (append
            (overlays-at (point-min))
            (overlays-in
             (point-min) (min (point-max) (1+ (point-min))))))
    (when (overlay-get overlay 'brutal-paper-active-minibuffer-top-padding)
      (delete-overlay overlay)))
  (setq-local brutal-paper--active-minibuffer-top-padding-overlay nil)
  (let ((state brutal-paper--minibuffer-input-inset-state))
    (when-let* ((state state)
              (start (nth 0 state))
              (end (nth 1 state))
              ((marker-buffer start))
              ((eq (marker-buffer start) (current-buffer)))
              ((eq (marker-buffer end) (current-buffer))))
    (let ((begin (marker-position start))
          (finish (marker-position end))
          (previous (nth 2 state))
          (inhibit-read-only t)
          (inhibit-modification-hooks t))
      (when (and begin finish (< begin finish) (<= finish (point-max)))
        (with-silent-modifications
          (if previous
              (put-text-property begin finish 'line-prefix previous)
            (remove-text-properties begin finish '(line-prefix nil)))
          (remove-text-properties
           begin finish '(brutal-paper-minibuffer-input-inset nil))))
      (set-marker start nil)
      (set-marker end nil)))
    (when-let* ((saved-hscroll (nth 3 state)))
      (if (car saved-hscroll)
          (setq-local hscroll-margin (cdr saved-hscroll))
        (kill-local-variable 'hscroll-margin))))
  (setq-local brutal-paper--minibuffer-input-inset-state nil))

(defun brutal-paper--install-minibuffer-input-inset (background &optional frame)
  "Inset FRAME's active minibuffer input over BACKGROUND without stretching."
  (brutal-paper--remove-minibuffer-input-inset)
  (when (< (point-min) (point-max))
    (let* ((start (point-min))
           (end (1+ start))
           (prefix (and (> brutal-paper-fringe-width 0)
                        (brutal-paper--minibuffer-input-prefix background)))
           (previous (get-text-property start 'line-prefix))
           (saved-hscroll
            (cons (local-variable-p 'hscroll-margin) hscroll-margin))
           (inhibit-read-only t)
           (inhibit-modification-hooks t))
      (when prefix
        (with-silent-modifications
          (add-text-properties
           start end
           `(line-prefix ,prefix brutal-paper-minibuffer-input-inset t))))
      (setq-local brutal-paper--minibuffer-input-inset-state
                  (list (copy-marker start)
                        (copy-marker end t)
                        previous
                        saved-hscroll))
      (setq-local hscroll-margin
                  (max hscroll-margin
                       (brutal-paper--outer-edge-margin-columns frame)))
      (when-let* ((top-row
                   (brutal-paper--minibuffer-top-padding-row
                    background frame)))
        (setq-local brutal-paper--active-minibuffer-top-padding-overlay
                    (make-overlay start start nil t t))
        (overlay-put brutal-paper--active-minibuffer-top-padding-overlay
                     'brutal-paper-active-minibuffer-top-padding t)
        (overlay-put brutal-paper--active-minibuffer-top-padding-overlay
                     'before-string top-row)))))

(defun brutal-paper--minibuffer-footer-row
    (paper-background canvas-background &optional body-width frame)
  "Return one composite Paper-and-Canvas footer display row.
Keeping both surfaces in one image avoids Emacs redisplay instability caused
by consecutive display-only rows on a zero-width minibuffer overlay.
Use PAPER-BACKGROUND, CANVAS-BACKGROUND, BODY-WIDTH, and FRAME for geometry."
  (let* ((paper-height
          (brutal-paper--minibuffer-vertical-padding-height frame))
         (canvas-height (brutal-paper--effective-window-gap frame))
         (height (+ paper-height canvas-height)))
    (when (> height 0)
      (let ((width (max 1 (or body-width 1))))
        (propertize
         " "
         'display
         (brutal-paper--canvas-image
          (list 'minibuffer-footer (or frame (selected-frame))
                (current-buffer))
          width height
          (if (> paper-height 0) paper-background canvas-background)
          (when (> canvas-height 0)
            (list
             (list 0 paper-height width canvas-height canvas-background)))
          :ascent 100 :scale 1)
         'face `(:height 1
                         :background ,(if (> paper-height 0)
                                          paper-background
                                        canvas-background)
                         :extend t)
         'brutal-paper-echo-bottom-spacer (> paper-height 0)
         'brutal-paper-echo-bottom-gap (> canvas-height 0)
         'cursor-intangible t)))))

(defun brutal-paper--minibuffer-bottom-spacing
    (paper-background canvas-background
                      &optional body-width defer-footer omit-leading-newline
                      frame)
  "Return one deferred or realized minibuffer footer display row.
Use PAPER-BACKGROUND and CANVAS-BACKGROUND across BODY-WIDTH on FRAME.
DEFER-FOOTER leaves the composite surface unrealized.
OMIT-LEADING-NEWLINE is for completion overlays whose candidates already end
at the beginning of the footer row."
  (concat
   (unless omit-leading-newline
     (propertize "\n"
                 'face `(:background ,paper-background :extend t)
                 'brutal-paper-active-minibuffer-spacing t
                 'cursor-intangible t))
   (if defer-footer
       ""
     (or (brutal-paper--minibuffer-footer-row
          paper-background canvas-background body-width frame)
         ""))))

(defun brutal-paper--native-minibuffer-bottom-spacing
    (paper-background canvas-background
                      &optional body-width defer-footer frame)
  "Return native cursor and one deferred or realized footer row.
The leading cursor-face cell follows point while the native cursor is hidden;
NS Emacs otherwise places that cursor after every display-only footer row.
PAPER-BACKGROUND and CANVAS-BACKGROUND share the same composite image used by
completion overlays, keeping redisplay geometry identical in both paths.
BODY-WIDTH and FRAME determine its size; DEFER-FOOTER postpones realization."
  (concat
   (propertize " "
               'face 'cursor
               'brutal-paper-native-minibuffer-cursor t)
   (brutal-paper--minibuffer-bottom-spacing
    paper-background canvas-background body-width defer-footer nil frame)))

(defun brutal-paper--active-minibuffer-bottom-spacing-p (string)
  "Return non-nil when STRING is a Brutal Paper minibuffer footer."
  (and (stringp string)
       (> (length string) 0)
       (or (text-property-any
            0 (length string)
            'brutal-paper-active-minibuffer-spacing t string)
           (text-property-any
            0 (length string) 'brutal-paper-echo-bottom-spacer t string)
           (text-property-any
            0 (length string) 'brutal-paper-echo-bottom-gap t string))))

(defun brutal-paper--completion-overlay-has-body-p (overlay)
  "Return non-nil when completion OVERLAY displays rows below the prompt."
  (when-let* ((before-string (and (overlayp overlay)
                                  (overlay-get overlay 'before-string)))
              ((stringp before-string)))
    (string-match-p "\n" before-string)))

(defun brutal-paper--remove-native-minibuffer-surfaces ()
  "Restore the active native minibuffer's ordinary paper remap."
  (when brutal-paper--native-minibuffer-canvas-remap-cookie
    (face-remap-remove-relative
     brutal-paper--native-minibuffer-canvas-remap-cookie)
    (setq-local brutal-paper--native-minibuffer-canvas-remap-cookie nil))
  (when (overlayp brutal-paper--native-minibuffer-paper-overlay)
    (delete-overlay brutal-paper--native-minibuffer-paper-overlay))
  (setq-local brutal-paper--native-minibuffer-paper-overlay nil))

(defun brutal-paper--remove-minibuffer-fringe-surface ()
  "Remove the buffer-local Canvas remap from minibuffer fringes."
  (when brutal-paper--minibuffer-fringe-remap-cookie
    (face-remap-remove-relative
     brutal-paper--minibuffer-fringe-remap-cookie)
    (setq-local brutal-paper--minibuffer-fringe-remap-cookie nil)))

(defun brutal-paper--install-minibuffer-fringe-surface (background)
  "Paint this minibuffer's structural fringes with BACKGROUND."
  (brutal-paper--remove-minibuffer-fringe-surface)
  (setq-local brutal-paper--minibuffer-fringe-remap-cookie
              (face-remap-add-relative
               'fringe `(:background ,background :extend t))))

(defun brutal-paper--install-native-minibuffer-surfaces
    (paper-background canvas-background)
  "Use PAPER-BACKGROUND for input and CANVAS-BACKGROUND for its last row."
  (brutal-paper--remove-native-minibuffer-surfaces)
  (setq-local
   brutal-paper--native-minibuffer-canvas-remap-cookie
   (face-remap-add-relative
    'default `(:background ,canvas-background :extend t)))
  (setq-local brutal-paper--native-minibuffer-paper-overlay
              (make-overlay (point-min) (point-max) nil t t))
  (overlay-put brutal-paper--native-minibuffer-paper-overlay
               'brutal-paper-native-minibuffer-paper t)
  (overlay-put brutal-paper--native-minibuffer-paper-overlay 'priority 1000)
  (overlay-put brutal-paper--native-minibuffer-paper-overlay
               'face `(:background ,paper-background :extend t)))

(defun brutal-paper--remove-active-minibuffer-bottom-padding ()
  "Remove every active-minibuffer footer owned by Brutal Paper."
  (when (and (boundp 'vertico--candidates-ov)
             (overlayp vertico--candidates-ov)
             (brutal-paper--active-minibuffer-bottom-spacing-p
              (overlay-get vertico--candidates-ov 'after-string)))
    (overlay-put vertico--candidates-ov 'after-string nil))
  (when (overlayp brutal-paper--active-minibuffer-bottom-padding-overlay)
    (delete-overlay brutal-paper--active-minibuffer-bottom-padding-overlay))
  (setq-local brutal-paper--active-minibuffer-bottom-padding-overlay nil)
  (brutal-paper--remove-minibuffer-fringe-surface)
  (brutal-paper--remove-native-minibuffer-surfaces)
  (cond
   ((consp brutal-paper--saved-minibuffer-cursor-state)
    (if (car brutal-paper--saved-minibuffer-cursor-state)
        (setq-local cursor-type
                    (cdr brutal-paper--saved-minibuffer-cursor-state))
      (kill-local-variable 'cursor-type))
    (kill-local-variable 'brutal-paper--saved-minibuffer-cursor-state))))

(defun brutal-paper--install-active-minibuffer-bottom-padding
    (paper-background canvas-background
                      &optional body-width defer-footer frame)
  "Install PAPER-BACKGROUND and CANVAS-BACKGROUND below active input.
Use BODY-WIDTH and FRAME for geometry; DEFER-FOOTER postpones realization."
  (let* ((completion-overlay
          (and (boundp 'vertico--candidates-ov)
               (overlayp vertico--candidates-ov)
               (overlay-buffer vertico--candidates-ov)
               vertico--candidates-ov))
         (spacing
          (brutal-paper--minibuffer-bottom-spacing
           paper-background canvas-background body-width defer-footer
           (brutal-paper--completion-overlay-has-body-p completion-overlay)
           frame)))
    (brutal-paper--install-minibuffer-fringe-surface
     canvas-background)
    (if completion-overlay
        (progn
          (brutal-paper--remove-native-minibuffer-surfaces)
          (when (overlayp brutal-paper--active-minibuffer-bottom-padding-overlay)
            (delete-overlay
             brutal-paper--active-minibuffer-bottom-padding-overlay))
          (setq-local brutal-paper--active-minibuffer-bottom-padding-overlay nil)
          (overlay-put completion-overlay 'after-string spacing))
      (brutal-paper--install-native-minibuffer-surfaces
       paper-background canvas-background)
      (unless (and (overlayp
                    brutal-paper--active-minibuffer-bottom-padding-overlay)
                   (eq (overlay-buffer
                        brutal-paper--active-minibuffer-bottom-padding-overlay)
                       (current-buffer)))
        (setq-local brutal-paper--active-minibuffer-bottom-padding-overlay
                    (make-overlay (point-max) (point-max) nil t t)))
      (when (eq brutal-paper--saved-minibuffer-cursor-state
                brutal-paper--unset-minibuffer-cursor-state)
        (setq-local brutal-paper--saved-minibuffer-cursor-state
                    (cons (local-variable-p 'cursor-type) cursor-type)))
      (setq-local cursor-type nil)
      (move-overlay brutal-paper--active-minibuffer-bottom-padding-overlay
                    (point-max) (point-max) (current-buffer))
      (overlay-put brutal-paper--active-minibuffer-bottom-padding-overlay
                   'brutal-paper-active-minibuffer-bottom-padding t)
      (overlay-put brutal-paper--active-minibuffer-bottom-padding-overlay
                   'priority 1100)
      (overlay-put brutal-paper--active-minibuffer-bottom-padding-overlay
                   'face `(:background ,canvas-background :extend t))
      (overlay-put brutal-paper--active-minibuffer-bottom-padding-overlay
                   'after-string
                   (brutal-paper--native-minibuffer-bottom-spacing
                    paper-background canvas-background body-width
                    defer-footer frame)))))

(defun brutal-paper--echo-area-window-for-buffer (buffer)
  "Return the minibuffer window displaying BUFFER, if any."
  (or (get-buffer-window buffer t)
      (catch 'window
        (dolist (frame (frame-list))
          (when-let* ((window (minibuffer-window frame))
                      ((window-live-p window))
                      ((eq (window-buffer window) buffer)))
            (throw 'window window)))
        nil)))

(defun brutal-paper--inactive-echo-bottom-gap-string (background)
  "Return an independent BACKGROUND Canvas row below inactive echo text."
  (let ((gap (brutal-paper--effective-window-gap)))
    (if (zerop gap)
        ""
      (let* ((height gap)
             (spacer
              (if (> height 1)
                  (brutal-paper--echo-area-padding-spacer
                   background (1- height) 100)
                (propertize
                 " "
                 'display '(space :width 0)
                 'face `(:height 1 :background ,background :extend t)
                 'cursor-intangible t))))
        (propertize
         (concat
          (propertize
           "\n"
           'face `(:height 1 :background ,background :extend t)
           'cursor-intangible t)
          ;; Leave the structural image as the final display row.  A trailing
          ;; newline would create another row and make window-height
          ;; reconciliation oscillate during redisplay.
          spacer)
         'brutal-paper-echo-bottom-gap t)))))

(defun brutal-paper--inactive-echo-bottom-gap-overlay-p (overlay)
  "Return non-nil when OVERLAY owns a Brutal Paper echo footer."
  (and
   (overlayp overlay)
   (or (overlay-get overlay 'brutal-paper-inactive-echo-bottom-gap)
       (when-let* ((after-string (overlay-get overlay 'after-string))
                   ((stringp after-string))
                   ((> (length after-string) 0)))
         (get-text-property
          0 'brutal-paper-echo-bottom-gap after-string)))))

(defun brutal-paper--remove-inactive-echo-bottom-gap ()
  "Remove every Brutal Paper footer from the current echo buffer."
  (dolist (overlay (overlays-in (point-min) (point-max)))
    (when (brutal-paper--inactive-echo-bottom-gap-overlay-p overlay)
      (delete-overlay overlay)))
  (setq-local brutal-paper--inactive-echo-bottom-gap-overlay nil))

(defun brutal-paper--install-inactive-echo-bottom-gap (background)
  "Install one display-only Canvas footer on inactive echo BACKGROUND."
  (let ((current
         (and (overlayp brutal-paper--inactive-echo-bottom-gap-overlay)
              (eq (overlay-buffer
                   brutal-paper--inactive-echo-bottom-gap-overlay)
                  (current-buffer))
              brutal-paper--inactive-echo-bottom-gap-overlay)))
    (dolist (overlay (overlays-in (point-min) (point-max)))
      (when (and (not (eq overlay current))
                 (brutal-paper--inactive-echo-bottom-gap-overlay-p overlay))
        (delete-overlay overlay)))
    (unless current
      (setq-local brutal-paper--inactive-echo-bottom-gap-overlay
                  (make-overlay (point-max) (point-max) nil t t))))
  (move-overlay brutal-paper--inactive-echo-bottom-gap-overlay
                (point-max) (point-max) (current-buffer))
  (overlay-put brutal-paper--inactive-echo-bottom-gap-overlay
               'brutal-paper-inactive-echo-bottom-gap t)
  (overlay-put
   brutal-paper--inactive-echo-bottom-gap-overlay 'after-string
   (brutal-paper--inactive-echo-bottom-gap-string background)))

(defun brutal-paper--echo-area-visible-message-line-count (window)
  "Return the visible display-row count of WINDOW's current message."
  (let* ((message (current-message))
         (lines (and (stringp message) (split-string message "\n" t)))
         (width (max 1 (or (window-body-width window t) 1)))
         (rows 0))
    (dolist (line lines)
      (setq rows
            (+ rows
               (max 1 (ceiling
                       (/ (float (string-pixel-width line)) width))))))
    (max 1 rows)))

(defun brutal-paper--echo-area-target-pixel-height (window)
  "Return inactive echo WINDOW's content height plus its Canvas footer."
  (when (and (window-live-p window)
             (not (minibuffer-window-active-p window)))
    (+ (* (default-line-height)
          (brutal-paper--echo-area-visible-message-line-count window))
       (brutal-paper--effective-window-gap (window-frame window)))))

(defun brutal-paper--reconcile-echo-area-window-height (window)
  "Resize inactive echo WINDOW to its exact content and bottom gap."
  (when (and (window-live-p window)
             (display-graphic-p (window-frame window))
             (not brutal-paper--resizing-echo-area-window))
    (when-let* ((target
                 (brutal-paper--echo-area-target-pixel-height window))
                (current (window-body-height window t))
                ((numberp current))
                (delta (- target current))
                ((not (zerop delta))))
      (setq brutal-paper--resizing-echo-area-window t)
      (unwind-protect
        (condition-case nil
            (let ((before (window-pixel-height window)))
              (window-resize window delta nil nil t)
              (unless (= before (window-pixel-height window))
                (force-mode-line-update t)))
          (error nil))
        (setq brutal-paper--resizing-echo-area-window nil)))))

(defun brutal-paper--fill-empty-echo-area (background)
  "Give an empty echo buffer one extending BACKGROUND glyph."
  (cond
   ((= (point-min) (point-max))
    (let ((buffer-undo-list t)
          (inhibit-read-only t))
      (with-silent-modifications
        (insert (propertize
                 " "
                 'display '(space :width 0)
                 'face `(:background ,background :extend t)
                 'brutal-paper-echo-background t)))))
   ((and (= (- (point-max) (point-min)) 1)
         (get-text-property (point-min) 'brutal-paper-echo-background))
    (let ((buffer-undo-list t)
          (inhibit-read-only t))
      (with-silent-modifications
        (put-text-property
         (point-min) (point-max) 'face
         `(:background ,background :extend t)))))))

(defun brutal-paper--style-echo-area-buffer (buffer background &optional fill)
  "Paint echo-area BUFFER with BACKGROUND.
When FILL is non-nil, extend the colour through an empty inactive row."
  (when (and (buffer-live-p buffer)
             (brutal-paper--echo-area-buffer-p buffer))
    (with-current-buffer buffer
      (let ((style (list background
                         (brutal-paper--readable-ink background))))
        (unless (and (equal style brutal-paper--echo-area-remap-color)
                     (brutal-paper--echo-area-remap-live-p))
          (when (brutal-paper--echo-area-remap-live-p)
            (face-remap-remove-relative
             brutal-paper--echo-area-remap-cookie))
          (setq-local
           brutal-paper--echo-area-remap-cookie
           (face-remap-add-relative
            'default
            `(:foreground ,(cadr style)
              :background ,background
              :extend t))
           brutal-paper--echo-area-remap-color style))
        (if fill
            (progn
              (brutal-paper--remove-minibuffer-input-inset)
              (brutal-paper--remove-active-minibuffer-bottom-padding)
              (brutal-paper--install-minibuffer-fringe-surface background)
              (brutal-paper--fill-empty-echo-area background)
              (brutal-paper--install-inactive-echo-bottom-gap background))
          (brutal-paper--remove-inactive-echo-bottom-gap))))))

(defun brutal-paper--style-current-minibuffer ()
  "Keep active minibuffer input on the editing paper surface."
  (when (and brutal-paper-enable-echo-area brutal-paper-mode)
    (let* ((window
            (brutal-paper--echo-area-window-for-buffer (current-buffer)))
           (frame
            (if (window-live-p window)
                (window-frame window)
              (selected-frame)))
           (background (brutal-paper--window-background frame)))
      (brutal-paper--style-echo-area-buffer
       (current-buffer) background)
      (brutal-paper--install-minibuffer-input-inset background frame)
      (when (window-live-p window)
        (brutal-paper--normalize-minibuffer-edges frame)))))

(defun brutal-paper--install-current-minibuffer-bottom-padding
    (&optional realize-footer)
  "Install active minibuffer spacing; realize it when REALIZE-FOOTER is set."
  (when (and brutal-paper-enable-echo-area
             (minibufferp)
             brutal-paper-mode)
    (when-let* ((window
                 (brutal-paper--echo-area-window-for-buffer
                  (current-buffer)))
                ((window-live-p window))
                (frame (window-frame window))
                (paper (brutal-paper--window-background frame))
                (canvas (brutal-paper-canvas-color frame)))
      (brutal-paper--install-active-minibuffer-bottom-padding
       paper canvas (window-body-width window t) (not realize-footer) frame)
      (brutal-paper--normalize-minibuffer-edges frame)
      (force-window-update window)
      (brutal-paper--schedule-echo-area-refresh frame))))

(defun brutal-paper--style-echo-area (&optional frame)
  "Paint FRAME's inactive echo area with its current Canvas colour."
  (let* ((frame (or frame (selected-frame)))
         (window (and (frame-live-p frame) (minibuffer-window frame))))
    (when (and brutal-paper-mode
               brutal-paper-enable-echo-area
               (window-live-p window)
               (not (minibuffer-window-active-p window)))
      (let ((background (brutal-paper-canvas-color frame)))
        (brutal-paper--style-echo-area-buffer
         (window-buffer window) background t)
        (dolist (name brutal-paper--echo-area-buffer-names)
          (when-let* ((buffer (get-buffer name)))
            (brutal-paper--style-echo-area-buffer buffer background t)))
        (brutal-paper--normalize-minibuffer-edges frame)
        (brutal-paper--reconcile-echo-area-window-height window)
        (force-window-update window)))))

(defun brutal-paper--active-minibuffer-target-pixel-height (&optional frame)
  "Return the exact pixel height of FRAME's active input and spacing."
  (let ((padding (brutal-paper--minibuffer-vertical-padding-height frame)))
    (+ (default-line-height)
       padding
       padding
       (brutal-paper--effective-window-gap frame))))

(defun brutal-paper--reconcile-active-minibuffer-window-height (window)
  "Keep WINDOW's native minibuffer input visible above its footer."
  (when (and (window-live-p window)
             (minibuffer-window-active-p window)
             (not brutal-paper--resizing-echo-area-window))
    (with-current-buffer (window-buffer window)
      (when (and (overlayp
                  brutal-paper--active-minibuffer-bottom-padding-overlay))
        (let* ((target
                (brutal-paper--active-minibuffer-target-pixel-height
                 (window-frame window)))
               (current (window-body-height window t))
               (delta (max 0 (- target current))))
          (setq brutal-paper--resizing-echo-area-window t)
          (unwind-protect
              (condition-case nil
                  (progn
                    (when (> delta 0)
                      (let ((before (window-pixel-height window)))
                        (window-resize window delta nil nil t)
                        (unless (= before (window-pixel-height window))
                          (force-mode-line-update t))))
                    (set-window-start window (point-min) t)
                    (force-window-update window))
                (error nil))
            (setq brutal-paper--resizing-echo-area-window nil)))))))

(defun brutal-paper--cancel-echo-area-refresh ()
  "Cancel deferred echo-area work and forget its pending frames."
  (when (timerp brutal-paper--echo-area-refresh-timer)
    (cancel-timer brutal-paper--echo-area-refresh-timer))
  (setq brutal-paper--echo-area-refresh-timer nil
        brutal-paper--pending-echo-area-frames nil))

(defun brutal-paper--run-echo-area-refresh ()
  "Refresh echo areas after the hook or redisplay transaction has ended."
  (setq brutal-paper--echo-area-refresh-timer nil)
  (let ((frames (prog1 (nreverse brutal-paper--pending-echo-area-frames)
                  (setq brutal-paper--pending-echo-area-frames nil))))
    (when (and brutal-paper-enable-echo-area
               brutal-paper-mode
               (not brutal-paper--refreshing-echo-area))
      ;; Use a global guard: redisplay callbacks triggered by `window-resize'
      ;; are not required to preserve the caller's dynamic binding.
      (setq brutal-paper--refreshing-echo-area t)
      (unwind-protect
          (dolist (frame frames)
            (when (frame-live-p frame)
              (when-let* ((window (minibuffer-window frame))
                          ((window-live-p window)))
                (if (minibuffer-window-active-p window)
                    (with-current-buffer (window-buffer window)
                      (brutal-paper--install-current-minibuffer-bottom-padding
                       t)
                      (brutal-paper--reconcile-active-minibuffer-window-height
                       window))
                  (brutal-paper--style-echo-area-unless-isearch frame)))))
        (setq brutal-paper--refreshing-echo-area nil)))))

(defun brutal-paper--schedule-echo-area-refresh (&optional frame)
  "Defer FRAME's echo-area work until Emacs leaves its current transaction."
  (when (and brutal-paper-enable-echo-area
             brutal-paper-mode
             (not brutal-paper--applying)
             (not brutal-paper--refreshing-echo-area))
    (cl-pushnew (or frame (selected-frame))
                brutal-paper--pending-echo-area-frames)
    (unless (timerp brutal-paper--echo-area-refresh-timer)
      (setq brutal-paper--echo-area-refresh-timer
            (run-at-time 0 nil #'brutal-paper--run-echo-area-refresh)))))

(defun brutal-paper--restore-echo-area ()
  "Remove echo-area face remaps and sentinels installed by the theme."
  (brutal-paper--cancel-echo-area-refresh)
  (dolist (buffer (buffer-list))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (brutal-paper--remove-minibuffer-input-inset)
        (brutal-paper--remove-active-minibuffer-bottom-padding)
        (brutal-paper--remove-inactive-echo-bottom-gap)
        (when (local-variable-p
               'brutal-paper--echo-area-remap-cookie buffer)
          (when (brutal-paper--echo-area-remap-live-p)
            (face-remap-remove-relative brutal-paper--echo-area-remap-cookie))
          (let ((buffer-undo-list t)
                (inhibit-read-only t))
            (with-silent-modifications
              (when (and (= (- (point-max) (point-min)) 1)
                         (get-text-property
                          (point-min) 'brutal-paper-echo-background))
                (delete-region (point-min) (point-max)))))
          (kill-local-variable 'brutal-paper--echo-area-remap-cookie)
          (kill-local-variable 'brutal-paper--echo-area-remap-color))))))

(defun brutal-paper--window-canvas-outer-edge-margins
    (window &optional root-edges)
  "Return Canvas margin columns for outer frame edges touched by WINDOW.
ROOT-EDGES defaults to the pixel edges of WINDOW's frame root window."
  (condition-case nil
      (let* ((root-edges
              (or root-edges
                  (window-pixel-edges
                   (frame-root-window (window-frame window)))))
             (edges (window-pixel-edges window))
             (scroll-bars (window-scroll-bars window))
             (scroll-bar-side
              (let ((type (nth 2 scroll-bars)))
                (if (eq type t)
                    (frame-parameter
                     (window-frame window) 'vertical-scroll-bars)
                  type)))
             (columns
              (brutal-paper--outer-edge-margin-columns
               (window-frame window))))
        ;; Native scroll bars sit outside window margins.  Reserving Canvas on
        ;; that same outer side would put the margin between paper and the
        ;; scroll bar; the frame divider already supplies Canvas after it.
        (cons (and (= (nth 0 edges) (nth 0 root-edges))
                   (not (eq scroll-bar-side 'left))
                   columns)
              (and (= (nth 2 edges) (nth 2 root-edges))
                   (not (eq scroll-bar-side 'right))
                   columns)))
    (error '(nil . nil))))

(defun brutal-paper--save-window-edges (window)
  "Save WINDOW's margins and fringes before the first mode mutation."
  (unless (gethash window brutal-paper--saved-window-edges)
    (puthash window
             (cons (window-margins window) (window-fringes window))
             brutal-paper--saved-window-edges)))

(defun brutal-paper--set-window-edges (window margins fringe-width)
  "Set WINDOW's MARGINS and FRINGE-WIDTH when they differ.
FRINGE-WIDTH is either one symmetric pixel width or a left/right cons."
  (let* ((left-fringe
          (if (consp fringe-width) (car fringe-width) fringe-width))
         (right-fringe
          (if (consp fringe-width) (cdr fringe-width) fringe-width))
         (current-margins (window-margins window))
        (current-fringes (window-fringes window))
        changed)
    (unless (and (equal (car-safe current-margins) (car margins))
                 (equal (cdr-safe current-margins) (cdr margins)))
      (brutal-paper--save-window-edges window)
      (set-window-margins window (car margins) (cdr margins))
      (setq changed t))
    (unless (and (= (nth 0 current-fringes) left-fringe)
                 (= (nth 1 current-fringes) right-fringe))
      (brutal-paper--save-window-edges window)
      (set-window-fringes window left-fringe right-fringe nil t)
      (setq changed t))
    (when changed
      (force-window-update window))))

(defun brutal-paper--minibuffer-paper-edge-fringes (frame window)
  "Return Canvas fringe widths aligning WINDOW to FRAME's outer Paper."
  (condition-case nil
      (let ((window-edges (window-pixel-edges window))
            left-paper-edge
            right-paper-edge)
        (dolist (paper-window (window-list frame 'no-minibuffer))
          (when (window-live-p paper-window)
            (let* ((body-edges (window-body-pixel-edges paper-window))
                   (fringes (window-fringes paper-window))
                   (paper-left (- (nth 0 body-edges)
                                  (or (nth 0 fringes) 0)))
                   (paper-right (+ (nth 2 body-edges)
                                   (or (nth 1 fringes) 0))))
              (setq left-paper-edge
                    (if left-paper-edge
                        (min left-paper-edge paper-left)
                      paper-left)
                    right-paper-edge
                    (if right-paper-edge
                        (max right-paper-edge paper-right)
                      paper-right)))))
        (if (and left-paper-edge right-paper-edge)
            (cons (max 0 (- left-paper-edge (nth 0 window-edges)))
                  (max 0 (- (nth 2 window-edges) right-paper-edge)))
          (cons brutal-paper-fringe-width brutal-paper-fringe-width)))
    (error
     (cons brutal-paper-fringe-width brutal-paper-fringe-width))))

(defun brutal-paper--normalize-minibuffer-edges (frame)
  "Align FRAME's minibuffer Canvas fringes with outer Paper edges."
  (when-let* ((window (minibuffer-window frame)))
    (when (window-live-p window)
      (brutal-paper--set-window-edges
       window
       (cons nil nil)
       (if brutal-paper-enable-echo-area
           (brutal-paper--minibuffer-paper-edge-fringes frame window)
         (cons 0 0))))))

(defun brutal-paper--normalize-window-edges (&optional frame)
  "Restore paper fringes and true outer Canvas margins on FRAME."
  (let ((frame (or frame (selected-frame))))
    (when (and brutal-paper-enable-window-margins
               (brutal-paper--top-level-frame-p frame)
               (display-graphic-p frame)
               (not brutal-paper--normalizing-window-edges))
      (let ((brutal-paper--normalizing-window-edges t)
            (root-edges
             (window-pixel-edges (frame-root-window frame))))
        (dolist (window (window-list frame 'no-minibuffer))
          (when (window-live-p window)
            (brutal-paper--set-window-edges
             window
             (brutal-paper--window-canvas-outer-edge-margins
              window root-edges)
             brutal-paper-fringe-width)))
        (brutal-paper--normalize-minibuffer-edges frame)))))

(defun brutal-paper--restore-window-edges ()
  "Restore every live window geometry value saved by Brutal Paper."
  (maphash
   (lambda (window saved)
     (when (window-live-p window)
       (let ((margins (car saved))
             (fringes (cdr saved)))
         (set-window-margins window (car margins) (cdr margins))
         (set-window-fringes window
                             (nth 0 fringes) (nth 1 fringes)
                             (nth 2 fringes) (nth 3 fringes)))))
  brutal-paper--saved-window-edges)
  (clrhash brutal-paper--saved-window-edges))

(defun brutal-paper--save-frame-chrome (frame)
  "Save every FRAME parameter mutated by Brutal Paper once."
  (unless (gethash frame brutal-paper--saved-frame-chrome)
    (puthash
     frame
     (mapcar (lambda (parameter)
               (cons parameter (frame-parameter frame parameter)))
             '(undecorated undecorated-round menu-bar-lines
               tab-bar-lines tab-bar-lines-keep-state
               internal-border-width left-fringe right-fringe
               right-divider-width bottom-divider-width border-color))
     brutal-paper--saved-frame-chrome)))

(defun brutal-paper--sync-tab-bar-lines (frame)
  "Give FRAME one explicit tab-bar line per visible consumer row."
  (when (and brutal-paper-enable-tab-bar
             brutal-paper-mode
             (frame-live-p frame)
             (brutal-paper--top-level-frame-p frame))
    (let ((target (if (brutal-paper--sub-tabs-visible-p frame) 2 1)))
      (when (facep 'tab-bar)
        (set-face-attribute
         'tab-bar frame :background
         (brutal-paper--native-tab-bar-background frame)))
      (unless (and (equal (frame-parameter frame 'tab-bar-lines) target)
                   (frame-parameter frame 'tab-bar-lines-keep-state))
        (brutal-paper--save-frame-chrome frame)
        ;; Mark the explicit row count as frame-owned so native tab-bar
        ;; recalculation cannot collapse a consumer's secondary row.
        (set-frame-parameter frame 'tab-bar-lines-keep-state t)
        (set-frame-parameter frame 'tab-bar-lines target)))))

(defun brutal-paper--apply-window-divider-state (gap)
  "Apply or restore the native window divider using GAP pixels."
  (if brutal-paper-window-divider-mode
      (progn
        (setq window-divider-default-right-width gap
              window-divider-default-bottom-width
              (max 0 brutal-paper-bottom-divider-width))
        (unless (bound-and-true-p window-divider-mode)
          (window-divider-mode 1)))
    (setq window-divider-default-right-width
          brutal-paper--saved-window-divider-default-right-width
          window-divider-default-bottom-width
          brutal-paper--saved-window-divider-default-bottom-width)
    (unless (eq (bound-and-true-p window-divider-mode)
                brutal-paper--saved-window-divider-mode)
      (window-divider-mode
       (if brutal-paper--saved-window-divider-mode 1 -1)))))

(defun brutal-paper--apply-frame (&optional frame)
  "Apply Brutal Paper geometry to top-level FRAME."
  (let ((frame (or frame (selected-frame))))
    (when (and (brutal-paper--top-level-frame-p frame)
               (display-graphic-p frame)
               (not brutal-paper--applying))
      ;; Redisplay and window-configuration callbacks can run outside the
      ;; dynamic binding that initiated a frame change.  Keep the guard in the
      ;; symbol's global value until every resulting callback has settled.
      (setq brutal-paper--applying t)
      (unwind-protect
          (let ((gap (brutal-paper--effective-window-gap frame))
                (fringe (max 0 brutal-paper-fringe-width)))
            ;; Save inherited geometry before frame parameters realize the
            ;; configured fringe widths on existing windows.
            (dolist (window
                     (cons (minibuffer-window frame)
                           (window-list frame 'no-minibuffer)))
              (when (window-live-p window)
                (brutal-paper--save-window-edges window)))
            (brutal-paper--save-frame-chrome frame)
            (when brutal-paper-rounded-frame-chrome
              (dolist (entry '((undecorated . nil)
                               (undecorated-round . t)
                               (menu-bar-lines . 0)))
                (unless (equal (frame-parameter frame (car entry)) (cdr entry))
                  (set-frame-parameter frame (car entry) (cdr entry)))))
            (dolist (entry
                     `((internal-border-width . 0)
                       (left-fringe . ,fringe)
                       (right-fringe . ,fringe)
                       (right-divider-width . ,gap)
                       (bottom-divider-width
                        . ,(max 0 brutal-paper-bottom-divider-width))))
              (unless (equal (frame-parameter frame (car entry)) (cdr entry))
                (set-frame-parameter frame (car entry) (cdr entry))))
            (brutal-paper--apply-window-divider-state gap)
            (let ((canvas (brutal-paper-canvas-color frame)))
              (unless (equal (frame-parameter frame 'border-color) canvas)
                (set-frame-parameter frame 'border-color canvas))
              (brutal-paper--style-echo-area-unless-isearch frame))
            (brutal-paper--normalize-window-edges frame))
        (setq brutal-paper--applying nil)))))

(defun brutal-paper--cancel-tab-status-animation ()
  "Stop the tab-status animation and reset its first frame."
  (when (timerp brutal-paper--tab-status-timer)
    (cancel-timer brutal-paper--tab-status-timer))
  (setq brutal-paper--tab-status-timer nil
        brutal-paper--tab-status-phase 1))

(defun brutal-paper--frame-has-animated-tab-status-p (frame)
  "Return non-nil when FRAME contains a status using animated dots."
  (seq-some
   (lambda (item)
     (eq (plist-get
          (brutal-paper--tab-status-spec (plist-get item :status)) :icon)
         'dots))
   (append (brutal-paper--tab-model-items :tabs frame)
           (brutal-paper--tab-model-items :sub-tabs frame))))

(defun brutal-paper--sync-tab-status-animation ()
  "Run the tab-status timer only while animated dots are visible."
  (if (and brutal-paper-mode
           (seq-some
            (lambda (frame)
              (and (brutal-paper--top-level-frame-p frame)
                   (brutal-paper--frame-has-animated-tab-status-p frame)))
            (frame-list)))
      (unless (timerp brutal-paper--tab-status-timer)
        (setq brutal-paper--tab-status-timer
              (run-with-timer 0.4 0.4 #'brutal-paper--animate-tab-status)))
    (brutal-paper--cancel-tab-status-animation)))

(defun brutal-paper--animate-tab-status ()
  "Advance animated tab-status dots and refresh the workspace rows."
  (if brutal-paper-mode
      (progn
        (setq brutal-paper--tab-status-phase
              (1+ (% brutal-paper--tab-status-phase 3)))
        (force-mode-line-update t))
    (brutal-paper--cancel-tab-status-animation)))

(defun brutal-paper--refresh-rendered-chrome (&optional frame)
  "Force tab, title, and footer redisplay on FRAME or every live frame."
  (brutal-paper--sync-tab-status-animation)
  (force-mode-line-update t)
  (dolist (candidate (if frame (list frame) (frame-list)))
    (when (and (ignore-errors (frame-live-p candidate))
               (brutal-paper--top-level-frame-p candidate))
      (brutal-paper--sync-tab-bar-lines candidate)
      (redraw-frame candidate))))

;;;###autoload
(defun brutal-paper-refresh (&optional frame)
  "Refresh rendered Brutal Paper chrome on FRAME or every live frame.
Use this after a consumer changes native tab names or other data read by the
renderer.  Unlike `brutal-paper-apply', this does not reapply paper or window
geometry; it only synchronizes the native tab-bar line count with the consumer
  rows."
  (interactive)
  (brutal-paper--clear-image-caches)
  (brutal-paper--refresh-rendered-chrome frame))

(defun brutal-paper-apply (&optional frame)
  "Apply Brutal Paper's configured features to FRAME or all top-level frames.
Features disabled by an embedding configuration are removed immediately.
Do nothing while `brutal-paper-mode' is disabled."
  (interactive)
  (when brutal-paper-mode
    (brutal-paper--clear-image-caches)
    (brutal-paper--install-all-buffer-chrome)
    (unless brutal-paper-enable-echo-area
      (brutal-paper--restore-echo-area))
    (unless brutal-paper-enable-window-margins
      (brutal-paper--restore-window-edges))
    (if frame
        (progn
          (brutal-paper--apply-faces frame)
          (brutal-paper--apply-frame frame))
      (brutal-paper--apply-faces)
      (dolist (candidate (seq-filter #'brutal-paper--top-level-frame-p
                                     (frame-list)))
        (brutal-paper--apply-frame candidate)))
    (brutal-paper--refresh-rendered-chrome frame)))

(defun brutal-paper--clear-image-caches ()
  "Invalidate derived chrome after geometry or colour changes.
Reusable Canvas specs remain alive and are repainted on the next render."
  (mapc #'clrhash
        (list brutal-paper--tab-image-cache
              brutal-paper--tab-fill-image-cache
              brutal-paper--sub-tab-image-cache
              brutal-paper--sub-tab-fill-image-cache
              brutal-paper--svg-font-metrics-cache
              brutal-paper--tab-model-cache
              brutal-paper--tab-line-image-cache
              brutal-paper--mode-line-image-cache
              brutal-paper--logo-aspect-ratio-cache)))

(defun brutal-paper--refresh-focus-appearance ()
  "Refresh frame chrome after the focused frame has settled."
  (setq brutal-paper--focus-refresh-timer nil)
  (when brutal-paper-mode
    (brutal-paper--clear-image-caches)
    (force-mode-line-update t)
    (dolist (frame (seq-filter #'brutal-paper--top-level-frame-p
                               (frame-list)))
      (when (frame-live-p frame)
        (redraw-frame frame)))))

(defun brutal-paper--focus-changed ()
  "Coalesce workspace-row refreshes after frame focus changes."
  (when brutal-paper-mode
    (when (timerp brutal-paper--focus-refresh-timer)
      (cancel-timer brutal-paper--focus-refresh-timer))
    (setq brutal-paper--focus-refresh-timer
          (run-at-time 0.03 nil #'brutal-paper--refresh-focus-appearance))))

(defun brutal-paper--save-buffer-chrome (&optional buffer)
  "Save BUFFER's local line formats and tab-line mode once per session."
  (with-current-buffer (or buffer (current-buffer))
    (unless (or (minibufferp) brutal-paper--buffer-chrome-installed)
      (setq brutal-paper--saved-local-tab-line
            (and (local-variable-p 'tab-line-format)
                 (cons t tab-line-format))
            brutal-paper--saved-local-mode-line
            (and (local-variable-p 'mode-line-format)
                 (cons t mode-line-format))
            brutal-paper--saved-local-tab-line-mode
            (cons (local-variable-p 'tab-line-mode)
                  (bound-and-true-p tab-line-mode))
            brutal-paper--buffer-chrome-installed t))))

(defun brutal-paper--save-all-buffer-chrome ()
  "Save chrome state in every existing non-minibuffer buffer."
  (dolist (buffer (buffer-list))
    (when (buffer-live-p buffer)
      (brutal-paper--save-buffer-chrome buffer))))

(defun brutal-paper--clear-installed-tab-line-formats ()
  "Clear saved buffers' tab-line formats before changing the native mode.
Emacs reports a format installed outside `tab-line-mode' when that mode is
toggled with a non-native value.  The original values remain in the chrome
snapshot and are restored after the mode transition."
  (dolist (buffer (buffer-list))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when brutal-paper--buffer-chrome-installed
          (setq-local tab-line-format nil))))))

(defun brutal-paper--install-buffer-chrome (&optional buffer)
  "Install standalone paper line formats in BUFFER."
  (when brutal-paper-mode
    (with-current-buffer (or buffer (current-buffer))
      (unless (minibufferp)
        (brutal-paper--save-buffer-chrome)
        (setq-local mode-line-format brutal-paper-mode-line-format)
        (when brutal-paper-enable-tab-line
          (unless (bound-and-true-p tab-line-mode)
            (setq-local tab-line-format nil)
            (tab-line-mode 1))
          (setq-local tab-line-format brutal-paper-tab-line-format))))))

(defun brutal-paper--install-all-buffer-chrome ()
  "Install standalone paper line formats in every existing buffer."
  (dolist (buffer (buffer-list))
    (brutal-paper--install-buffer-chrome buffer)))

(defun brutal-paper--window-buffer-changed (window &rest _)
  "Install standalone paper chrome in WINDOW's displayed buffer."
  (when (window-live-p window)
    (brutal-paper--install-buffer-chrome (window-buffer window))
    (brutal-paper--normalize-window-edges (window-frame window))))

(defun brutal-paper--restore-all-buffer-chrome ()
  "Restore buffer-local line formats and tab-line modes from the snapshot."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when brutal-paper--buffer-chrome-installed
        (setq-local tab-line-format nil)
        (when brutal-paper--saved-local-tab-line-mode
          (tab-line-mode
           (if (cdr brutal-paper--saved-local-tab-line-mode) 1 -1)))
        (unless (car-safe brutal-paper--saved-local-tab-line-mode)
          (kill-local-variable 'tab-line-mode))
        (if brutal-paper--saved-local-tab-line
            (setq-local tab-line-format
                        (cdr brutal-paper--saved-local-tab-line))
          (kill-local-variable 'tab-line-format))
        (if brutal-paper--saved-local-mode-line
            (setq-local mode-line-format
                        (cdr brutal-paper--saved-local-mode-line))
          (kill-local-variable 'mode-line-format))
        (setq brutal-paper--buffer-chrome-installed nil
              brutal-paper--saved-local-tab-line nil
              brutal-paper--saved-local-mode-line nil
              brutal-paper--saved-local-tab-line-mode nil)))))

(defun brutal-paper--tab-selected (&rest _)
  "Refresh Canvas and SVG chrome after selecting a workspace tab."
  (when brutal-paper-mode
    (brutal-paper-apply (selected-frame))
    (force-mode-line-update t)))

(defun brutal-paper--refresh-active-isearch-prompt ()
  "Reissue the active isearch prompt after its theme face changes."
  (when-let* ((buffer (brutal-paper--active-isearch-buffer)))
    (with-current-buffer buffer
      (isearch-update))))

(defun brutal-paper--theme-changed (theme)
  "Refresh structural colours after THEME is enabled or disabled.
When THEME owns a native variable or face that Brutal Paper overlays, retain
its newly realized value as the underlay restored by a later mode disable."
  ;; Emacs reports the synthetic user-theme pass before the actual theme.
  ;; Reapplying our layer there would hide the actual theme values before its
  ;; callback can become the new restorable underlay.
  (when (and theme (not (eq theme 'user)) brutal-paper-mode)
    (brutal-paper--refresh-saved-variables-for-theme theme)
    (brutal-paper--refresh-saved-faces-for-theme theme)
    (brutal-paper--apply-variable-values)
    (brutal-paper-apply)
    (brutal-paper--refresh-active-isearch-prompt)))

(defun brutal-paper--force-scroll-bar-mode-off (arguments)
  "Force an enabling mode call in ARGUMENTS to disable scroll bars instead."
  (if (and brutal-paper--modes-active
           brutal-paper-hide-scroll-bars
           (not brutal-paper--allow-scroll-bar-mode-change))
      '(-1)
    arguments))

(defun brutal-paper--force-scroll-bar-setting-off (arguments)
  "Force an enabling `set-scroll-bar-mode' call in ARGUMENTS to nil."
  (if (and brutal-paper--modes-active
           brutal-paper-hide-scroll-bars
           (not brutal-paper--allow-scroll-bar-mode-change))
      '(nil)
    arguments))

(defun brutal-paper--activate-modes ()
  "Show the native rows used by the Brutal Paper chrome."
  (unless brutal-paper--modes-active
    (setq brutal-paper--saved-tab-bar-mode
          (bound-and-true-p tab-bar-mode)
          brutal-paper--saved-global-tab-line-mode
          (bound-and-true-p global-tab-line-mode)
          brutal-paper--saved-tool-bar-mode
          (bound-and-true-p tool-bar-mode)
          brutal-paper--saved-scroll-bar-mode
          scroll-bar-mode
          brutal-paper--saved-horizontal-scroll-bar-mode
          (bound-and-true-p horizontal-scroll-bar-mode)
          brutal-paper--saved-window-divider-mode
          (bound-and-true-p window-divider-mode)
          brutal-paper--saved-window-divider-default-right-width
          window-divider-default-right-width
          brutal-paper--saved-window-divider-default-bottom-width
          window-divider-default-bottom-width
          brutal-paper--modes-active t)
    ;; global-tab-line-mode can create buffer-local state, so capture every
    ;; existing buffer before any native mode is changed.  Native renderer
    ;; variables and faces belong to the same reversible mode transaction.
    (brutal-paper--save-variable-values)
    (brutal-paper--save-all-buffer-chrome)
    (when brutal-paper-enable-tab-line
      (brutal-paper--clear-installed-tab-line-formats))
    (brutal-paper--save-global-face-attributes)
    (dolist (frame (seq-filter #'brutal-paper--top-level-frame-p
                               (frame-list)))
      (brutal-paper--save-frame-chrome frame))
    (brutal-paper--apply-variable-values)
    (when brutal-paper-enable-tab-bar
      (tab-bar-mode 1))
    (when brutal-paper-enable-tab-line
      (global-tab-line-mode 1))
    (when brutal-paper-hide-tool-bar
      (tool-bar-mode -1))
    (when brutal-paper-hide-scroll-bars
      (scroll-bar-mode -1)
      (horizontal-scroll-bar-mode -1))))

(defun brutal-paper--deactivate ()
  "Restore the complete state captured before the current mode session."
  (when brutal-paper--modes-active
    (brutal-paper--cancel-echo-area-refresh)
    (brutal-paper--cancel-tab-status-animation)
    (when (timerp brutal-paper--focus-refresh-timer)
      (cancel-timer brutal-paper--focus-refresh-timer))
    (setq brutal-paper--focus-refresh-timer nil)
    (brutal-paper--restore-echo-area)
    ;; Restore global modes regardless of the current option values: those may
    ;; have changed while Brutal Paper was active.  Buffers are restored after
    ;; global-tab-line-mode so originally non-local values inherit correctly.
    (brutal-paper--clear-installed-tab-line-formats)
    (brutal-paper--restore-variable-values)
    (tab-bar-mode (if brutal-paper--saved-tab-bar-mode 1 -1))
    (global-tab-line-mode
     (if brutal-paper--saved-global-tab-line-mode 1 -1))
    (tool-bar-mode (if brutal-paper--saved-tool-bar-mode 1 -1))
    (let ((brutal-paper--allow-scroll-bar-mode-change t))
      (set-scroll-bar-mode brutal-paper--saved-scroll-bar-mode)
      (horizontal-scroll-bar-mode
       (if brutal-paper--saved-horizontal-scroll-bar-mode 1 -1)))
    (setq window-divider-default-right-width
          brutal-paper--saved-window-divider-default-right-width
          window-divider-default-bottom-width
          brutal-paper--saved-window-divider-default-bottom-width)
    (window-divider-mode
     (if brutal-paper--saved-window-divider-mode 1 -1))
    (brutal-paper--restore-all-buffer-chrome)
    (maphash
     (lambda (frame parameters)
       (when (frame-live-p frame)
         (dolist (entry parameters)
           (set-frame-parameter frame (car entry) (cdr entry)))))
     brutal-paper--saved-frame-chrome)
    (clrhash brutal-paper--saved-frame-chrome)
    (brutal-paper--restore-window-edges)
    (brutal-paper--restore-face-attributes)
    (force-mode-line-update t)
    (setq brutal-paper--modes-active nil
          brutal-paper--saved-tab-bar-mode nil
          brutal-paper--saved-global-tab-line-mode nil
          brutal-paper--saved-tool-bar-mode nil
          brutal-paper--saved-scroll-bar-mode nil
          brutal-paper--saved-horizontal-scroll-bar-mode nil
          brutal-paper--saved-window-divider-mode nil
          brutal-paper--saved-window-divider-default-right-width nil
          brutal-paper--saved-window-divider-default-bottom-width nil)))

(defun brutal-paper--frame-created (frame)
  "Apply paper geometry to newly created FRAME when the mode is active."
  (when (and (brutal-paper--top-level-frame-p frame)
             (brutal-paper--graphical-environment-p frame)
             brutal-paper-mode)
    (brutal-paper--apply-faces frame)
    (brutal-paper--apply-frame frame)))

(defun brutal-paper--window-configuration-changed (&optional frame)
  "Repair FRAME paper geometry after a window configuration change."
  (when brutal-paper-mode
    (let ((frame (or frame (selected-frame))))
      (dolist (window (window-list frame 'no-minibuffer))
        (brutal-paper--install-buffer-chrome (window-buffer window)))
      (brutal-paper--apply-frame frame)
      (when-let* ((window (minibuffer-window frame))
                  ((window-live-p window))
                  ((minibuffer-window-active-p window)))
        (with-current-buffer (window-buffer window)
          (brutal-paper--install-current-minibuffer-bottom-padding t))))))

(defun brutal-paper--window-selection-changed (&optional frame)
  "Refresh FRAME's title and stable lower shadow after selection changes."
  (ignore frame)
  (when brutal-paper-mode
    (force-mode-line-update t)))

(defconst brutal-paper--hook-specs
  '((enable-theme-functions brutal-paper--theme-changed)
    (disable-theme-functions brutal-paper--theme-changed)
    (after-load-functions brutal-paper--after-load)
    (after-make-frame-functions brutal-paper--frame-created)
    (window-configuration-change-hook
     brutal-paper--window-configuration-changed)
    (window-size-change-functions brutal-paper--window-configuration-changed)
    (window-selection-change-functions brutal-paper--window-selection-changed)
    (after-change-major-mode-hook brutal-paper--install-buffer-chrome)
    (window-buffer-change-functions brutal-paper--window-buffer-changed)
    (minibuffer-setup-hook brutal-paper--style-current-minibuffer)
    (minibuffer-setup-hook
     brutal-paper--install-current-minibuffer-bottom-padding 100)
    (minibuffer-exit-hook brutal-paper--schedule-echo-area-refresh)
    (echo-area-clear-hook brutal-paper--schedule-echo-area-refresh)
    (tab-bar-tab-post-select-functions brutal-paper--tab-selected)
    (tab-bar-tab-post-open-functions brutal-paper--tab-selected))
  "Hooks owned by an active Brutal Paper mode session.")

(defun brutal-paper--set-hooks (enable)
  "Install owned hooks and advice when ENABLE is non-nil; remove otherwise."
  (dolist (spec brutal-paper--hook-specs)
    (if enable
        (apply #'add-hook spec)
      (remove-hook (car spec) (cadr spec))))
  (dolist (spec '((scroll-bar-mode brutal-paper--force-scroll-bar-mode-off)
                  (set-scroll-bar-mode
                   brutal-paper--force-scroll-bar-setting-off)
                  (horizontal-scroll-bar-mode
                   brutal-paper--force-scroll-bar-mode-off)))
    (if enable
        (advice-add (car spec) :filter-args (cadr spec))
      (advice-remove (car spec) (cadr spec))))
  (if enable
      (progn
        (when (featurep 'marginalia)
          (brutal-paper--install-marginalia-alignment-advice))
        (add-function :after after-focus-change-function
                      #'brutal-paper--focus-changed))
    (advice-remove 'marginalia--align
                   #'brutal-paper--marginalia-align-around)
    (remove-function after-focus-change-function
                     #'brutal-paper--focus-changed)))

(defun brutal-paper--enable ()
  "Start one reversible Brutal Paper mode session."
  (brutal-paper--require-graphical-environment)
  (unless brutal-paper--modes-active
    (brutal-paper--activate-modes)
    (brutal-paper--set-hooks t)
    (brutal-paper--install-all-buffer-chrome)
    (brutal-paper-apply)))

(defun brutal-paper--disable ()
  "End the active Brutal Paper mode session and restore its underlay."
  (brutal-paper--set-hooks nil)
  (brutal-paper--deactivate))

(provide 'brutal-paper)
;;; brutal-paper.el ends here
