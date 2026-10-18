;;; brutal-paper-test.el --- Standalone Brutal Paper tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'svg)

(add-to-list
 'load-path
 (expand-file-name ".." (file-name-directory load-file-name)))

(load (expand-file-name "../scripts/e2e-init.el"
                        (file-name-directory load-file-name))
      nil t)

(require 'brutal-paper)

(defconst brutal-paper-test--package-load-state
  (list (memq #'brutal-paper--theme-changed enable-theme-functions)
        (memq #'brutal-paper--theme-changed disable-theme-functions)
        (memq #'brutal-paper--frame-created after-make-frame-functions)
        (advice-member-p #'brutal-paper--force-scroll-bar-mode-off
                         'scroll-bar-mode))
  "Global integration state immediately after requiring Brutal Paper.")

(deftheme brutal-paper-test-theme-a)
(custom-theme-set-variables
 'brutal-paper-test-theme-a
 '(tab-bar-border 7))
(custom-theme-set-faces
 'brutal-paper-test-theme-a
 '(tab-line ((t (:background "#111111")))))

(deftheme brutal-paper-test-theme-b)
(custom-theme-set-variables
 'brutal-paper-test-theme-b
 '(tab-bar-border 9))
(custom-theme-set-faces
 'brutal-paper-test-theme-b
 '(tab-line ((t (:background "#222222")))))

(defun brutal-paper-test--graphical-environment-p (&optional _frame)
  "Treat batch unit tests as graphical at the lifecycle boundary."
  t)

(advice-add 'brutal-paper--graphical-environment-p :override
            #'brutal-paper-test--graphical-environment-p)

(defun brutal-paper-test--e2e-theme-sequence (seed)
  "Return a deterministic E2E theme sequence produced from SEED."
  (let ((brutal-paper-e2e-theme-pool '(paper-light paper-dark paper-tinted))
        (brutal-paper-e2e-seed seed)
        (brutal-paper-e2e-index 1)
        (brutal-paper-e2e--active-colour-theme nil)
        (brutal-paper-e2e--random-state nil)
        themes)
    (cl-letf (((symbol-function 'custom-available-themes)
               (lambda () brutal-paper-e2e-theme-pool)))
      (dotimes (_ 8)
        (let ((theme (brutal-paper-e2e--next-theme)))
          (push theme themes)
          (setq brutal-paper-e2e--active-colour-theme theme))))
    (nreverse themes)))

(defun brutal-paper-test--e2e-font-sequence (seed)
  "Return a deterministic E2E font sequence produced from SEED."
  (let ((brutal-paper-e2e-font-pool '("Mono One" "Mono Two" "Mono Three"))
        (brutal-paper-e2e-seed seed)
        (brutal-paper-e2e-index 1)
        (brutal-paper-e2e--active-font nil)
        (brutal-paper-e2e--random-state nil)
        fonts)
    (cl-letf (((symbol-function 'font-family-list)
               (lambda (&optional _frame) brutal-paper-e2e-font-pool)))
      (dotimes (_ 8)
        (let ((font (brutal-paper-e2e--next-font)))
          (push font fonts)
          (setq brutal-paper-e2e--active-font font))))
    (nreverse fonts)))

(defun brutal-paper-test--e2e-title-colour-sequence (seed)
  "Return a deterministic E2E title-colour sequence produced from SEED."
  (let ((brutal-paper-e2e-title-colour-pool
         '((:name neutral) (:name cool) (:name warm)))
        (brutal-paper-e2e-seed seed)
        (brutal-paper-e2e-index 1)
        (brutal-paper-e2e--active-title-colours nil)
        (brutal-paper-e2e--random-state nil)
        colours)
    (dotimes (_ 8)
      (let ((style (brutal-paper-e2e--next-title-colours)))
        (push (plist-get style :name) colours)
        (setq brutal-paper-e2e--active-title-colours style)))
    (nreverse colours)))

(ert-deftest brutal-paper-e2e-randomizes-reproducible-presentation-changes ()
  "Vary E2E themes, fonts, and title colours with seeded replay."
  (let ((first (brutal-paper-test--e2e-theme-sequence 20260825))
        (replay (brutal-paper-test--e2e-theme-sequence 20260825))
        (first-fonts (brutal-paper-test--e2e-font-sequence 20260825))
        (replay-fonts (brutal-paper-test--e2e-font-sequence 20260825))
        (first-title-colours
         (brutal-paper-test--e2e-title-colour-sequence 20260825))
        (replay-title-colours
         (brutal-paper-test--e2e-title-colour-sequence 20260825)))
    (should (equal first replay))
    (should (equal first-fonts replay-fonts))
    (should (equal first-title-colours replay-title-colours))
    (should (> (length (delete-dups (copy-sequence first))) 1))
    (should (> (length (delete-dups (copy-sequence first-fonts))) 1))
    (should
     (> (length (delete-dups (copy-sequence first-title-colours))) 1))
    (cl-loop for (left right) on first
             while right
             do (should-not (eq left right)))
    (cl-loop for (left right) on first-fonts
             while right
             do (should-not (equal left right)))
    (cl-loop for (left right) on first-title-colours
             while right
             do (should-not (eq left right)))))

(ert-deftest brutal-paper-e2e-applies-active-and-inactive-title-colours ()
  "Apply both title surfaces and refresh the fixture immediately."
  (let* ((style '(:name "test"
                  :active (:light "gray85" :dark "gray25")
                  :inactive (:light "gray95" :dark "gray15")))
         (brutal-paper-e2e--active-title-colours nil)
         (brutal-paper-window-title-active-background nil)
         (brutal-paper-window-title-inactive-background nil)
         applied
         refreshed)
    (cl-letf (((symbol-function 'brutal-paper-apply)
               (lambda (&optional frame) (setq applied frame)))
              ((symbol-function 'brutal-paper-e2e--refresh-labels)
               (lambda () (setq refreshed t)))
              ((symbol-function 'message) #'ignore))
      (brutal-paper-e2e--apply-title-colours style 'frame))
    (should (eq applied 'frame))
    (should refreshed)
    (should
     (equal brutal-paper-window-title-active-background
            '(:light "gray85" :dark "gray25")))
    (should
     (equal brutal-paper-window-title-inactive-background
            '(:light "gray95" :dark "gray15")))))

(defun brutal-paper-test--svg-image (svg &rest properties)
  "Serialize SVG into an image spec without requiring an image backend."
  (let ((data (with-temp-buffer
                (svg-print svg)
                (buffer-string))))
    `(image :type svg :data ,data :brutal-paper-test-dom ,svg
            ,@properties :transform-smoothing t)))

(defun brutal-paper-test--canvas-pixel (image x y)
  "Return IMAGE's ARGB32 pixel at X, Y."
  (aref (image-property image :data)
        (+ x (* y (image-property image :data-width)))))

(defun brutal-paper-test--image-dom (image)
  "Return IMAGE's SVG DOM retained by the test serializer."
  (image-property image :brutal-paper-test-dom))

(defun brutal-paper-test--image-dimension (image dimension)
  "Return IMAGE's pixel DIMENSION."
  (or (image-property image
                      (if (eq dimension 'width) :data-width :data-height))
      (let ((value (dom-attr (brutal-paper-test--image-dom image) dimension)))
        (if (stringp value) (string-to-number value) value))))

(defun brutal-paper-test--structural-pixel (image x y)
  "Return structural IMAGE's ARGB32 pixel at X, Y."
  (if (eq (image-property image :type) 'canvas)
      (brutal-paper-test--canvas-pixel image x y)
    (let (pixel)
      (dolist (rectangle
               (dom-by-tag (brutal-paper-test--image-dom image) 'rect))
        (let ((left (or (dom-attr rectangle 'x) 0))
              (top (or (dom-attr rectangle 'y) 0))
              (width (dom-attr rectangle 'width))
              (height (dom-attr rectangle 'height)))
          (when (and (<= left x) (< x (+ left width))
                     (<= top y) (< y (+ top height)))
            (setq pixel
                  (brutal-paper--argb32 (dom-attr rectangle 'fill))))))
      pixel)))

(defun brutal-paper-test--structural-image-type ()
  "Return the structural image backend available to this Emacs."
  (if (image-type-available-p 'canvas) 'canvas 'svg))

(defun brutal-paper-test--contrast-ratio (foreground background)
  "Return the WCAG contrast ratio between FOREGROUND and BACKGROUND."
  (cl-labels
      ((linear (value)
         (if (<= value 0.04045)
             (/ value 12.92)
           (expt (/ (+ value 0.055) 1.055) 2.4)))
       (luminance (colour)
         (pcase-let ((`(,red ,green ,blue) (brutal-paper--rgb colour)))
           (+ (* 0.2126 (linear red))
              (* 0.7152 (linear green))
              (* 0.0722 (linear blue))))))
    (let ((foreground-luminance (luminance foreground))
          (background-luminance (luminance background)))
      (/ (+ (max foreground-luminance background-luminance) 0.05)
         (+ (min foreground-luminance background-luminance) 0.05)))))

;; These tests assert on generated SVG markup, not host rendering support.
(advice-add 'svg-image :override #'brutal-paper-test--svg-image)

(ert-deftest brutal-paper-canvas-image-refreshes-in-place ()
  "Repaint an existing Emacs 32 canvas without replacing its image spec."
  (skip-unless (image-type-available-p 'canvas))
  (let ((brutal-paper--canvas-image-cache (make-hash-table :test #'equal))
        (brutal-paper--canvas-image-signatures (make-hash-table :test #'eq))
        refreshed)
    (cl-letf (((symbol-function 'canvas-refresh)
               (lambda (image &optional reload-data)
                 (setq refreshed (list image reload-data)))))
      (let* ((image
              (brutal-paper--canvas-image
               'fixture 2 1 "#000000" '((1 0 1 1 "#ffffff"))))
             (data (image-property image :data))
             (updated
              (brutal-paper--canvas-image
               'fixture 2 1 "#ffffff" '((1 0 1 1 "#000000")))))
        (should (eq (image-property image :type) 'canvas))
        (should (eq image updated))
        (should (eq data (image-property updated :data)))
        (should (equal refreshed (list image 'reload-data)))
        (should (= (brutal-paper-test--canvas-pixel updated 0 0)
                   #xffffffff))
        (should (= (brutal-paper-test--canvas-pixel updated 1 0)
                   #xff000000))))))

(ert-deftest brutal-paper-canvas-image-falls-back-to-svg ()
  "Keep structural images available before Emacs 32 introduced Canvas."
  (let ((brutal-paper--canvas-image-cache (make-hash-table :test #'equal))
        (brutal-paper--canvas-image-signatures (make-hash-table :test #'eq)))
    (cl-letf (((symbol-function 'image-type-available-p)
               (lambda (type) (eq type 'svg))))
      (let ((image
             (brutal-paper--canvas-image
              'fixture 2 1 "#000000" '((1 0 1 1 "#ffffff")))))
        (should (eq (image-property image :type) 'svg))))))

(defun brutal-paper-test--fringe-displays (string)
  "Return every fringe display specification carried by STRING."
  (let (displays)
    (dotimes (position (length string) (nreverse displays))
      (when-let* ((display (get-text-property position 'display string))
                  ((consp display))
                  ((memq (car display) '(left-fringe right-fringe))))
        (push display displays)))))

(ert-deftest brutal-paper-reload-preserves-minibuffer-state-sentinel ()
  "Keep existing minibuffer locals recognizable across a theme reload."
  (let ((sentinel brutal-paper--unset-minibuffer-cursor-state))
    (load (locate-library "brutal-paper") nil t)
    (should (eq brutal-paper--unset-minibuffer-cursor-state sentinel))
    (should
     (eq (default-value 'brutal-paper--saved-minibuffer-cursor-state)
         sentinel))))

(ert-deftest brutal-paper-preserves-user-font-faces ()
  "Enabling the mode must not assign a font family or height."
  (load-theme 'modus-operandi t)
  (let ((tab-family (face-attribute 'tab-bar :family nil nil))
        (tab-height (face-attribute 'tab-bar :height nil nil))
        (default-family (face-attribute 'default :family nil nil))
        (default-height (face-attribute 'default :height nil nil)))
    (unwind-protect
        (progn
          (brutal-paper-mode 1)
          (should (equal (face-attribute 'tab-bar :family nil nil)
                         tab-family))
          (should (equal (face-attribute 'tab-bar :height nil nil)
                         tab-height))
          (should (equal (face-attribute 'default :family nil nil)
                         default-family))
          (should (equal (face-attribute 'default :height nil nil)
                         default-height))
          (dolist (face '(brutal-paper-tab-bar
                          brutal-paper-tab-current
                          brutal-paper-tab-inactive
                          brutal-paper-window-line
                          brutal-paper-footer-active
                          brutal-paper-footer-inactive))
            (should (eq (face-attribute face :family nil nil) 'unspecified))
            (should (eq (face-attribute face :height nil nil) 'unspecified))))
      (brutal-paper-mode -1))))

(ert-deftest brutal-paper-visual-style-is-customizable ()
  "Expose palette, typography, and geometry through Custom variables."
  (dolist (variable
           '(brutal-paper-tab-colors
             brutal-paper-tab-bar-background
             brutal-paper-window-title-active-background
             brutal-paper-tab-model-function
             brutal-paper-tab-statuses
             brutal-paper-current-tab-font
             brutal-paper-inactive-tab-font
             brutal-paper-current-sub-tab-font
             brutal-paper-inactive-sub-tab-font
             brutal-paper-current-title-font
             brutal-paper-inactive-title-font
             brutal-paper-tab-font-size
             brutal-paper-minibuffer-right-padding
             brutal-paper-tab-left-padding
             brutal-paper-tab-right-padding
             brutal-paper-tab-corner-radius
             brutal-paper-tab-row-height
             brutal-paper-tab-junction-width
             brutal-paper-sub-tab-row-height
             brutal-paper-sub-tab-font-size
             brutal-paper-sub-tab-subtitle-font-size
             brutal-paper-sub-tab-subtitle-color-mix
             brutal-paper-sub-tab-horizontal-padding
             brutal-paper-sub-tab-order-gap
             brutal-paper-sub-tab-subtitle-gap
             brutal-paper-sub-tab-pill-inset
             brutal-paper-sub-tab-separator-height
             brutal-paper-sub-tab-separator-color-mix
             brutal-paper-svg-text-fallback-baseline-ratio
             brutal-paper-svg-text-optical-bias-ratio
             brutal-paper-show-logo
             brutal-paper-logo-tab-gap
             brutal-paper-window-title-height
             brutal-paper-window-footer-gap-height))
    (should (custom-variable-p variable)))
  (should (= brutal-paper-tab-row-height 41))
  (should (= brutal-paper-tab-current-top 9))
  (should (= brutal-paper-tab-inactive-top 13))
  (should (= brutal-paper-window-title-height 45))
  (should (= brutal-paper-shadow-depth 4))
  (dolist (variable '(brutal-paper-canvas-background
                      brutal-paper-tab-bar-background
                      brutal-paper-accent-color
                      brutal-paper-tab-colors
                      brutal-paper-window-background-fallback
                      brutal-paper-foreground-color-fallback
                      brutal-paper-default-accent-color
                      brutal-paper-light-ink-color
                      brutal-paper-dark-ink-color
                      brutal-paper-window-title-active-background
                      brutal-paper-window-title-inactive-background
                      brutal-paper-shadow-color))
    (should
     (memq 'brutal-paper-color
           (flatten-tree (get variable 'custom-type))))))

(ert-deftest brutal-paper-colors-accept-single-or-appearance-paired-values ()
  "Resolve one colour directly or select one side of a light/dark pair."
  (should (equal (brutal-paper--resolve-color "#123456") "#123456"))
  (cl-letf (((symbol-function 'brutal-paper--dark-appearance-p)
             (lambda (&optional _) nil)))
    (should
     (equal
      (brutal-paper--resolve-color
       '(:light "#eeeeee" :dark "#222222"))
      "#eeeeee")))
  (cl-letf (((symbol-function 'brutal-paper--dark-appearance-p)
             (lambda (&optional _) t)))
    (should
     (equal
      (brutal-paper--resolve-color
       '(:light "#eeeeee" :dark "#222222"))
      "#222222"))))

(ert-deftest brutal-paper-colors-normalize-every-emacs-format-for-svg ()
  "Convert frame-resolved Emacs colours to portable six-digit SVG colours."
  (cl-letf (((symbol-function 'color-values)
             (lambda (colour &optional _frame)
               (pcase colour
                 ("gray20" '(13107 13107 13107))
                 ("rgb:ff/00/80" '(65535 0 32896))
                 ("rgbi:0/1/0" '(0 65535 0))))))
    (should (equal (brutal-paper--resolve-color "#abc") "#aabbcc"))
    (should (equal (brutal-paper--resolve-color "#123456") "#123456"))
    (should (equal (brutal-paper--resolve-color "gray20") "#333333"))
    (should
     (equal (brutal-paper--resolve-color "rgb:ff/00/80") "#ff0080"))
    (should (equal (brutal-paper--resolve-color "rgbi:0/1/0") "#00ff00"))
    (should-not (brutal-paper--resolve-color "not-an-emacs-colour"))))

(ert-deftest brutal-paper-theme-face-colors-are-safe-for-svg ()
  "Do not pass active-theme X11 colour names directly to SVG renderers."
  (cl-letf (((symbol-function 'facep) (lambda (_face) t))
            ((symbol-function 'face-attribute)
             (lambda (&rest _) "gray20"))
            ((symbol-function 'color-values)
             (lambda (_colour &optional _frame) '(13107 13107 13107))))
    (should
     (equal (brutal-paper--face-color 'default :background) "#333333"))))

(ert-deftest brutal-paper-window-title-resolves-dark-background-pairs ()
  "Render readable active and inactive title surfaces in a dark appearance."
  (let ((active t)
        (brutal-paper-window-title-active-background
         '(:light "#e0e0e0" :dark "gray20"))
        (brutal-paper-window-title-inactive-background
         '(:light "#f0f0f0" :dark "#242424"))
        (brutal-paper--tab-line-image-cache
         (make-hash-table :test #'equal)))
    (cl-letf (((symbol-function 'display-images-p) (lambda (&rest _) t))
              ((symbol-function 'image-type-available-p)
               (lambda (type) (eq type 'svg)))
              ((symbol-function 'selected-window) (lambda () 'window))
              ((symbol-function 'window-frame) (lambda (_window) 'frame))
              ((symbol-function 'brutal-paper--dark-appearance-p)
               (lambda (&optional _) t))
              ((symbol-function 'color-values)
               (lambda (_colour &optional _frame) '(13107 13107 13107)))
              ((symbol-function 'brutal-paper--font-spec)
               (lambda (&rest _)
                 '(:family "monospace" :weight normal :slant normal)))
              ((symbol-function 'mode-line-window-selected-p)
               (lambda () active))
              ((symbol-function 'brutal-paper--window-order)
               (lambda (&optional _window) '(1 . 1)))
              ((symbol-function 'buffer-name) (lambda (&optional _) "buffer"))
              ((symbol-function 'brutal-paper--line-position)
               (lambda () "1/1"))
              ((symbol-function 'brutal-paper--buffer-status)
               (lambda () "--"))
              ((symbol-function 'format-mode-line) (lambda (&rest _) "Text"))
              ((symbol-function 'brutal-paper--window-body-pixel-width)
               (lambda (&optional _window) 600))
              ((symbol-function 'brutal-paper--window-background)
               (lambda (&optional _frame) "#1c1c1c"))
              ((symbol-function 'brutal-paper--foreground-color)
               (lambda (&optional _frame) "#ffffff"))
              ((symbol-function 'brutal-paper--accent)
               (lambda (&optional _frame) "#57e561"))
              ((symbol-function 'brutal-paper--svg-text-width)
               (lambda (&rest _) 40))
              ((symbol-function 'brutal-paper--svg-centered-glyph-text-y)
               (lambda (&rest _)
                 (ert-fail "Title centering must use the SVG renderer")))
              ((symbol-function 'brutal-paper--svg-centered-visible-text-y)
               (lambda (center text size &rest _)
                 (should (= center (brutal-paper--window-title-center-y)))
                 (pcase text
                   ("1/1 -- TEXT"
                    (should (= size brutal-paper-window-meta-font-size))
                    27.25)
                   (_ (ert-fail (format "Unexpected centered text: %S" text)))))))
      (let* ((image (brutal-paper--window-title-image))
             (svg (plist-get (cdr image) :data)))
        (should (string-match-p
                 "<rect[^>]+x=\"0\"[^>]+fill=\"#333333\"" svg))
        (should (string-match-p
                 (concat "<text[^>]+fill=\"#ffffff\"[^>]*>"
                         "[[:space:]]*buffer</text>")
                 svg))
        (should (string-match-p
                 (concat "<text[^>]+dominant-baseline=\"middle\"[^>]+"
                         "y=\"25.5\"[^>]*>"
                         "[[:space:]]*1</text>")
                 svg))
        (should (string-match-p
                 (concat "<text[^>]+dominant-baseline=\"middle\"[^>]+"
                         "y=\"25.5\"[^>]*>"
                         "[[:space:]]*buffer</text>")
                 svg)))
      (setq active nil)
      (clrhash brutal-paper--tab-line-image-cache)
      (let* ((image (brutal-paper--window-title-image))
             (svg (plist-get (cdr image) :data)))
        (should (string-match-p
                 "<rect[^>]+x=\"0\"[^>]+fill=\"#242424\"" svg)))
      (setq active t
            brutal-paper-show-window-title-metadata nil)
      (clrhash brutal-paper--tab-line-image-cache)
      (let* ((image (brutal-paper--window-title-image))
             (dom (brutal-paper-test--image-dom image)))
        (should (= (length (dom-by-tag dom 'text)) 2))
        (should-not (dom-by-tag dom 'line))))))

(ert-deftest brutal-paper-dark-window-title-defaults-remain-readable ()
  "Keep active and muted title ink readable on a neutral dark theme."
  (cl-letf (((symbol-function 'brutal-paper--dark-appearance-p)
             (lambda (&optional _) t)))
    (let* ((paper "#1C1C1C")
           (ink "#CECECE")
           (quiet-ink
            (brutal-paper--mix
             ink paper brutal-paper-window-muted-ink-mix))
           (active-background
            (brutal-paper--resolve-color
             brutal-paper-window-title-active-background))
           (inactive-background
            (brutal-paper--resolve-color
             brutal-paper-window-title-inactive-background)))
      (should
       (>= (brutal-paper-test--contrast-ratio ink active-background) 4.5))
      (should
       (>= (brutal-paper-test--contrast-ratio
            quiet-ink inactive-background)
           4.5)))))

(ert-deftest brutal-paper-current-and-inactive-fonts-accept-family-or-face ()
  "Resolve separate current and inactive tab and title font sources."
  (let ((brutal-paper-current-tab-font 'tab-source)
        (brutal-paper-inactive-tab-font "Tab Sans")
        (brutal-paper-current-title-font "Title Sans")
        (brutal-paper-inactive-title-font 'title-source))
    (cl-letf (((symbol-function 'facep)
               (lambda (face) (memq face '(tab-source title-source))))
              ((symbol-function 'face-attribute)
               (lambda (face attribute &rest _)
                 (pcase (list face attribute)
                   (`(tab-source :family) "Tab Serif")
                   (`(tab-source :weight) 'bold)
                   (`(tab-source :slant) 'normal)
                   (`(title-source :family) "Title Serif")
                   (`(title-source :weight) 'light)
                   (`(title-source :slant) 'italic)))))
      (should
       (equal (brutal-paper--tab-font-spec t)
              '(:family "Tab Serif" :weight bold :slant normal)))
      (should
       (equal (brutal-paper--tab-font-spec nil)
              '(:family "Tab Sans" :weight normal :slant normal)))
      (should
       (equal (brutal-paper--title-font-spec t)
              '(:family "Title Sans" :weight normal :slant normal)))
      (should
       (equal (brutal-paper--title-font-spec nil)
              '(:family "Title Serif" :weight light :slant italic))))))

(ert-deftest brutal-paper-canvas-mix-is-configurable ()
  "Blend the selected tab colour without changing the solid default."
  (cl-letf (((symbol-function 'brutal-paper--window-background)
             (lambda (&optional _frame) "#ffffff"))
            ((symbol-function 'brutal-paper--tab-base-color)
             (lambda (&rest _) "#57E561"))
            ((symbol-function 'brutal-paper--current-tab-index)
             (lambda (&optional _frame) 0)))
    (let ((brutal-paper-canvas-background nil)
          (brutal-paper-canvas-color-function nil)
          (brutal-paper-canvas-mix 1.0))
      (should (equal (brutal-paper-canvas-color) "#57E561")))
    (let ((brutal-paper-canvas-background nil)
          (brutal-paper-canvas-color-function nil)
          (brutal-paper-canvas-mix 0.0))
      (should (equal (brutal-paper-canvas-color) "#ffffff")))))

(ert-deftest brutal-paper-dark-tab-surfaces-stay-distinct-from-paper ()
  "Keep every dark tab and its Canvas visibly separate from dark paper."
  (let ((paper "#1C1C1C")
        (brutal-paper-canvas-background nil)
        (brutal-paper-canvas-color-function nil)
        (brutal-paper-canvas-mix 1.0))
    (cl-letf (((symbol-function 'brutal-paper--dark-appearance-p)
               (lambda (&optional _) t))
              ((symbol-function 'brutal-paper--window-background)
               (lambda (&optional _) paper)))
      (cl-loop
       for index below (length brutal-paper-tab-colors)
       do (dolist (current '(t nil))
            (let ((surface
                   (plist-get
                    (brutal-paper--tab-color-spec index current)
                    :background)))
              (should
               (>= (brutal-paper-test--contrast-ratio surface paper)
                   1.2)))))
      (cl-letf (((symbol-function 'brutal-paper--current-tab-index)
                 (lambda (&optional _) 4)))
        (should
         (>= (brutal-paper-test--contrast-ratio
              (brutal-paper-canvas-color) paper)
             1.2))))))

(ert-deftest brutal-paper-visual-option-refreshes-rendered-chrome ()
  "A Custom change must reapply live chrome."
  (let ((brutal-paper-mode t)
        applied forced)
    (unwind-protect
        (cl-letf (((symbol-function 'brutal-paper-apply)
                   (lambda (&optional _frame) (setq applied t)))
                  ((symbol-function 'force-mode-line-update)
                   (lambda (&optional _all) (setq forced t))))
          (brutal-paper--set-visual-option
           'brutal-paper-test--visual-option 17)
          (should (= (default-value 'brutal-paper-test--visual-option) 17))
          (should applied)
          (should forced))
      (makunbound 'brutal-paper-test--visual-option))))

(ert-deftest brutal-paper-disabled-visual-option-only-invalidates-caches ()
  "Customizing an inactive theme must not mutate faces or frame geometry."
  (let ((brutal-paper-mode nil)
        applied cleared forced)
    (unwind-protect
        (cl-letf (((symbol-function 'brutal-paper-apply)
                   (lambda (&optional _frame) (setq applied t)))
                  ((symbol-function 'brutal-paper--clear-image-caches)
                   (lambda () (setq cleared t)))
                  ((symbol-function 'force-mode-line-update)
                   (lambda (&optional _all) (setq forced t))))
          (brutal-paper--set-visual-option
           'brutal-paper-test--inactive-visual-option 23)
          (should-not applied)
          (should cleared)
          (should forced))
      (makunbound 'brutal-paper-test--inactive-visual-option))))

(ert-deftest brutal-paper-mode-line-format-replaces-live-footer-exactly ()
  "Apply a complete user format without wrapping it in the built-in footer."
  (let ((buffer (generate-new-buffer " *brutal-paper-mode-line-format*"))
        (original '("native" mode-line-buffer-identification))
        (custom '((:eval (format "custom:%s" (buffer-name)))))
        (old-default (default-value 'brutal-paper-mode-line-format))
        (brutal-paper-mode t)
        (brutal-paper-enable-tab-line nil)
        forced)
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (setq-local mode-line-format original)
            (brutal-paper--install-buffer-chrome))
          (cl-letf (((symbol-function 'buffer-list)
                     (lambda (&rest _) (list buffer)))
                    ((symbol-function 'force-mode-line-update)
                     (lambda (&optional all) (setq forced all))))
            (brutal-paper--set-line-format-option
             'brutal-paper-mode-line-format custom)
            (with-current-buffer buffer
              (should (equal mode-line-format custom))
              (should
               (equal (cdr brutal-paper--saved-local-mode-line) original)))
            (should forced)
            (brutal-paper--restore-all-buffer-chrome)
            (with-current-buffer buffer
              (should (equal mode-line-format original)))))
      (set-default 'brutal-paper-mode-line-format old-default)
      (kill-buffer buffer))))

(ert-deftest brutal-paper-mode-snapshots-native-state-only-once ()
  "Repeated activation must preserve state from before the first enable."
  (let ((brutal-paper--modes-active nil)
        (brutal-paper--saved-face-attributes nil)
        (brutal-paper-enable-tab-bar nil)
        (brutal-paper-enable-tab-line nil)
        (brutal-paper-hide-tool-bar nil)
        (brutal-paper-hide-scroll-bars nil)
        (tab-bar-mode nil)
        (global-tab-line-mode t)
        (tool-bar-mode t)
        (scroll-bar-mode 'right)
        (horizontal-scroll-bar-mode nil)
        (window-divider-mode t)
        (window-divider-default-right-width 7)
        (window-divider-default-bottom-width 9)
        (snapshot-count 0))
    (cl-letf (((symbol-function 'brutal-paper--save-all-buffer-chrome)
               (lambda () (cl-incf snapshot-count)))
              ((symbol-function 'brutal-paper--save-variable-values) #'ignore)
              ((symbol-function 'brutal-paper--apply-variable-values) #'ignore))
      (brutal-paper--activate-modes)
      (setq tab-bar-mode t
            global-tab-line-mode nil
            tool-bar-mode nil
            scroll-bar-mode nil
            horizontal-scroll-bar-mode t
            window-divider-mode nil
            window-divider-default-right-width 70
            window-divider-default-bottom-width 90)
      (brutal-paper--activate-modes)
      (should (= snapshot-count 1))
      (should-not brutal-paper--saved-tab-bar-mode)
      (should brutal-paper--saved-global-tab-line-mode)
      (should brutal-paper--saved-tool-bar-mode)
      (should (eq brutal-paper--saved-scroll-bar-mode 'right))
      (should-not brutal-paper--saved-horizontal-scroll-bar-mode)
      (should brutal-paper--saved-window-divider-mode)
      (should (= brutal-paper--saved-window-divider-default-right-width 7))
      (should (= brutal-paper--saved-window-divider-default-bottom-width 9)))))

(ert-deftest brutal-paper-mode-rejects-a-terminal-without-side-effects ()
  "Refuse to install structural UI state on a non-graphical frame."
  (let (calls)
    (cl-letf (((symbol-function 'brutal-paper--graphical-environment-p)
               (lambda (&optional _frame) nil))
              ((symbol-function 'brutal-paper--activate-modes)
               (lambda () (push 'activate-modes calls)))
              ((symbol-function 'brutal-paper-apply)
               (lambda (&rest _) (push 'apply calls))))
      (should-error (brutal-paper-mode 1) :type 'user-error)
      (should-not brutal-paper-mode)
      (should-not calls))))

(ert-deftest brutal-paper-package-load-is-inert ()
  "Requiring the package must not install mode-owned global integration."
  (should (equal brutal-paper-test--package-load-state '(nil nil nil nil)))
  (should-not (custom-theme-p 'brutal-paper))
  (should-not (fboundp 'brutal-paper-enable))
  (should-not (fboundp 'brutal-paper-disable)))

(ert-deftest brutal-paper-theme-switch-updates-the-disable-underlay ()
  "Disable to the latest colour theme rather than the pre-enable theme."
  (when brutal-paper-mode
    (brutal-paper-mode -1))
  (let ((original-format (default-value 'tab-bar-format)))
    (unwind-protect
        (progn
          (enable-theme 'brutal-paper-test-theme-a)
          (brutal-paper-mode 1)
          (should
           (equal tab-bar-format
                  '(brutal-paper--tab-bar-format-logo
                    brutal-paper--tab-bar-format-tabs
                    brutal-paper--tab-bar-format-fill
                    brutal-paper--tab-bar-format-sub-tabs)))
          (enable-theme 'brutal-paper-test-theme-b)
          (should (zerop tab-bar-border))
          (brutal-paper-mode -1)
          (should (= tab-bar-border 9))
          (should (equal tab-bar-format original-format))
          (should
           (equal (face-attribute 'tab-line :background nil nil) "#222222")))
      (when brutal-paper-mode
        (brutal-paper-mode -1))
      (when (memq 'brutal-paper-test-theme-b custom-enabled-themes)
        (disable-theme 'brutal-paper-test-theme-b))
      (when (memq 'brutal-paper-test-theme-a custom-enabled-themes)
        (disable-theme 'brutal-paper-test-theme-a)))))

(ert-deftest brutal-paper-native-mode-activation-is-idempotent ()
  "Do not re-enter native modes during repeated activation."
  (let ((brutal-paper--modes-active nil)
        (brutal-paper--saved-face-attributes nil)
        (brutal-paper-enable-tab-bar t)
        (brutal-paper-enable-tab-line t)
        (brutal-paper-hide-tool-bar t)
        (brutal-paper-hide-scroll-bars t)
        (tab-bar-mode nil)
        (global-tab-line-mode nil)
        (tool-bar-mode t)
        (scroll-bar-mode 'right)
        (horizontal-scroll-bar-mode t)
        calls)
    (cl-letf (((symbol-function 'brutal-paper--save-all-buffer-chrome)
               #'ignore)
              ((symbol-function 'brutal-paper--clear-installed-tab-line-formats)
               #'ignore)
              ((symbol-function 'brutal-paper--save-global-face-attributes)
               #'ignore)
              ((symbol-function 'brutal-paper--save-variable-values) #'ignore)
              ((symbol-function 'brutal-paper--apply-variable-values) #'ignore)
              ((symbol-function 'frame-list) (lambda () nil))
              ((symbol-function 'tab-bar-mode)
               (lambda (argument) (push (cons 'tab-bar argument) calls)))
              ((symbol-function 'global-tab-line-mode)
               (lambda (argument) (push (cons 'tab-line argument) calls)))
              ((symbol-function 'tool-bar-mode)
               (lambda (argument) (push (cons 'tool-bar argument) calls)))
              ((symbol-function 'scroll-bar-mode)
               (lambda (argument) (push (cons 'scroll-bar argument) calls)))
              ((symbol-function 'horizontal-scroll-bar-mode)
               (lambda (argument)
                 (push (cons 'horizontal-scroll-bar argument) calls))))
      (brutal-paper--activate-modes)
      (brutal-paper--activate-modes))
    (should
     (equal (nreverse calls)
            '((tab-bar . 1)
              (tab-line . 1)
              (tool-bar . -1)
              (scroll-bar . -1)
              (horizontal-scroll-bar . -1))))))

(ert-deftest brutal-paper-theme-change-refreshes-active-isearch-prompt ()
  "Reissue a live isearch prompt after its theme face changes."
  (require 'isearch)
  (let ((buffer (generate-new-buffer " *brutal-paper-isearch*"))
        (brutal-paper-mode t)
        refreshed)
    (unwind-protect
        (let ((isearch--current-buffer buffer))
          (with-current-buffer buffer
            (setq-local isearch-mode t))
          (cl-letf (((symbol-function 'brutal-paper-apply) #'ignore)
                    ((symbol-function 'isearch-update)
                     (lambda () (setq refreshed (current-buffer)))))
            (brutal-paper--theme-changed 'wombat))
          (should (eq refreshed buffer)))
      (kill-buffer buffer))))

(ert-deftest brutal-paper-theme-change-updates-the-managed-underlay ()
  "Preserve a colour theme's native variable value beneath the mode."
  (let ((brutal-paper-mode t)
        (brutal-paper--saved-variable-values
         '((tab-bar-border t 7)))
        (brutal-paper--saved-face-attributes nil)
        (theme 'brutal-paper-test-underlay)
        (original (default-value 'tab-bar-border))
        applied)
    (unwind-protect
        (progn
          (put theme 'theme-settings
               `((theme-value tab-bar-border ,theme 11)))
          (set-default 'tab-bar-border 11)
          (cl-letf (((symbol-function 'brutal-paper--apply-variable-values)
                     (lambda () (set-default 'tab-bar-border 0)))
                    ((symbol-function 'brutal-paper-apply)
                     (lambda (&optional _frame) (setq applied t)))
                    ((symbol-function
                      'brutal-paper--refresh-active-isearch-prompt)
                     #'ignore))
            (brutal-paper--theme-changed theme))
          (should applied)
          (should (= (caddr (assq 'tab-bar-border
                                  brutal-paper--saved-variable-values))
                     11))
          (should (zerop tab-bar-border)))
      (put theme 'theme-settings nil)
      (set-default 'tab-bar-border original))))

(ert-deftest brutal-paper-theme-apply-defers-live-isearch-echo-restyling ()
  "Leave a read-only isearch message intact until it can be reissued."
  (require 'isearch)
  (let ((buffer (generate-new-buffer " *brutal-paper-isearch-echo*"))
        styled)
    (unwind-protect
        (let ((isearch--current-buffer buffer))
          (with-current-buffer buffer
            (setq-local isearch-mode t))
          (cl-letf (((symbol-function 'brutal-paper--style-echo-area)
                     (lambda (&optional frame) (setq styled frame))))
            (brutal-paper--style-echo-area-unless-isearch 'frame)
            (should-not styled)
            (with-current-buffer buffer
              (setq-local isearch-mode nil))
            (brutal-paper--style-echo-area-unless-isearch 'frame)
            (should (eq styled 'frame))))
      (kill-buffer buffer))))

(ert-deftest brutal-paper-skips-a-face-unavailable-during-early-init ()
  "Do not abort startup when a registered face is not realized yet."
  (let ((brutal-paper--modes-active t)
        (brutal-paper--saved-face-attributes nil))
    (cl-letf (((symbol-function 'facep) (lambda (&rest _) t))
              ((symbol-function 'face-attribute)
               (lambda (&rest _) (error "Invalid face: tab-line"))))
      (should-not (brutal-paper--save-face-attributes 'tab-line))
      (should-not brutal-paper--saved-face-attributes))))

(ert-deftest brutal-paper-mode-restores-state-after-options-change ()
  "Restore the snapshot even when embedding code changes options while active."
  (let ((brutal-paper--modes-active t)
        (brutal-paper-enable-tab-bar nil)
        (brutal-paper-enable-tab-line nil)
        (brutal-paper-hide-tool-bar nil)
        (brutal-paper-hide-scroll-bars nil)
        (brutal-paper--saved-tab-bar-mode t)
        (brutal-paper--saved-global-tab-line-mode nil)
        (brutal-paper--saved-tool-bar-mode t)
        (brutal-paper--saved-scroll-bar-mode 'right)
        (brutal-paper--saved-horizontal-scroll-bar-mode nil)
        (brutal-paper--saved-window-divider-mode t)
        (brutal-paper--saved-window-divider-default-right-width 7)
        (brutal-paper--saved-window-divider-default-bottom-width 9)
        (brutal-paper--saved-frame-chrome (make-hash-table :test #'eq))
        (window-divider-default-right-width 70)
        (window-divider-default-bottom-width 90)
        calls restored-buffers restored-faces)
    (puthash 'frame '((internal-border-width . 6)
                      (tab-bar-lines . 0)
                      (tab-bar-lines-keep-state . before))
             brutal-paper--saved-frame-chrome)
    (cl-letf (((symbol-function 'brutal-paper--restore-echo-area) #'ignore)
              ((symbol-function 'brutal-paper--restore-window-edges) #'ignore)
              ((symbol-function 'brutal-paper--restore-all-buffer-chrome)
               (lambda () (setq restored-buffers t)))
              ((symbol-function 'brutal-paper--restore-face-attributes)
               (lambda () (setq restored-faces t)))
              ((symbol-function 'force-mode-line-update) #'ignore)
              ((symbol-function 'frame-live-p) (lambda (_frame) t))
              ((symbol-function 'set-frame-parameter)
               (lambda (_frame parameter value)
                 (push (cons parameter value) calls)))
              ((symbol-function 'tab-bar-mode)
               (lambda (argument) (push (cons 'tab-bar argument) calls)))
              ((symbol-function 'global-tab-line-mode)
               (lambda (argument) (push (cons 'tab-line argument) calls)))
              ((symbol-function 'tool-bar-mode)
               (lambda (argument) (push (cons 'tool-bar argument) calls)))
              ((symbol-function 'set-scroll-bar-mode)
               (lambda (value) (push (cons 'scroll-bar value) calls)))
              ((symbol-function 'horizontal-scroll-bar-mode)
               (lambda (argument)
                 (push (cons 'horizontal-scroll-bar argument) calls)))
              ((symbol-function 'window-divider-mode)
               (lambda (argument)
                 (push (cons 'window-divider argument) calls))))
      (brutal-paper--deactivate)
      (should (equal (alist-get 'tab-bar calls) 1))
      (should (equal (alist-get 'tab-line calls) -1))
      (should (equal (alist-get 'tool-bar calls) 1))
      (should (eq (alist-get 'scroll-bar calls) 'right))
      (should (equal (alist-get 'horizontal-scroll-bar calls) -1))
      (should (equal (alist-get 'window-divider calls) 1))
      (should (equal (alist-get 'internal-border-width calls) 6))
      (should (equal (alist-get 'tab-bar-lines calls) 0))
      (should (eq (alist-get 'tab-bar-lines-keep-state calls) 'before))
      (should (= window-divider-default-right-width 7))
      (should (= window-divider-default-bottom-width 9))
      (should restored-buffers)
      (should restored-faces)
      (should-not brutal-paper--modes-active))))

(ert-deftest brutal-paper-window-divider-option-restores-live-native-state ()
  "Stop owning native divider state as soon as its option is disabled."
  (let ((brutal-paper-window-divider-mode nil)
        (brutal-paper--saved-window-divider-mode nil)
        (brutal-paper--saved-window-divider-default-right-width 7)
        (brutal-paper--saved-window-divider-default-bottom-width 9)
        (window-divider-mode t)
        (window-divider-default-right-width 70)
        (window-divider-default-bottom-width 90)
        calls)
    (cl-letf (((symbol-function 'window-divider-mode)
               (lambda (argument)
                 (setq window-divider-mode (> argument 0))
                 (push argument calls))))
      (brutal-paper--apply-window-divider-state 12))
    (should (equal calls '(-1)))
    (should-not window-divider-mode)
    (should (= window-divider-default-right-width 7))
    (should (= window-divider-default-bottom-width 9))))

(ert-deftest brutal-paper-disable-restores-buffer-local-chrome ()
  "Restore local formats and tab-line-mode exactly after disabling."
  (let ((buffer (generate-new-buffer " *brutal-paper-state-test*"))
        diagnostic)
    (unwind-protect
        (with-current-buffer buffer
          (setq-local tab-line-mode nil
                      tab-line-format '(before-tab-line)
                      mode-line-format '(before-mode-line))
          (brutal-paper--save-buffer-chrome)
          (setq-local tab-line-mode t
                      tab-line-format '(brutal-tab-line)
                      mode-line-format '(brutal-mode-line))
          (cl-letf (((symbol-function 'buffer-list)
                     (lambda (&optional _frame) (list buffer)))
                    ((symbol-function 'message)
                     (lambda (format-string &rest arguments)
                       (when (and (stringp format-string)
                                  (string-prefix-p
                                   "tab-line-format set outside"
                                   format-string))
                         (setq diagnostic
                               (apply #'format format-string arguments))))))
            (brutal-paper--restore-all-buffer-chrome))
          (should-not diagnostic)
          (should-not tab-line-mode)
          (should (local-variable-p 'tab-line-mode))
          (should (equal tab-line-format '(before-tab-line)))
          (should (equal mode-line-format '(before-mode-line)))
          (should-not brutal-paper--buffer-chrome-installed))
      (kill-buffer buffer))))

(ert-deftest brutal-paper-mode-restores-pre-enable-face-values ()
  "Restore built-in faces captured before mode activation."
  (when brutal-paper-mode
    (brutal-paper-mode -1))
  (let ((attributes
         (mapcar
          (lambda (attribute)
            (cons attribute (face-attribute 'tab-line attribute nil nil)))
          brutal-paper--mutated-face-attributes)))
    (unwind-protect
        (progn
          (brutal-paper-mode 1)
          (brutal-paper-mode 1)
          (brutal-paper-mode -1)
          (dolist (entry attributes)
            (should
             (equal (face-attribute 'tab-line (car entry) nil nil)
                    (cdr entry)))))
      (when brutal-paper-mode
        (brutal-paper-mode -1)))))

(ert-deftest brutal-paper-keeps-user-enabled-scroll-bars ()
  "Preserve native scroll bars when their hiding option is disabled."
  (let ((brutal-paper--modes-active nil)
        (brutal-paper--saved-face-attributes nil)
        (brutal-paper-enable-tab-bar nil)
        (brutal-paper-enable-tab-line nil)
        (brutal-paper-hide-tool-bar nil)
        (brutal-paper-hide-scroll-bars nil)
        (scroll-bar-mode 'right)
        (horizontal-scroll-bar-mode t)
        calls)
    (cl-letf (((symbol-function 'brutal-paper--save-all-buffer-chrome)
               #'ignore)
              ((symbol-function 'brutal-paper--save-global-face-attributes)
               #'ignore)
              ((symbol-function 'scroll-bar-mode)
               (lambda (argument) (push (cons 'vertical argument) calls)))
              ((symbol-function 'horizontal-scroll-bar-mode)
               (lambda (argument) (push (cons 'horizontal argument) calls))))
      (brutal-paper--activate-modes)
      (should-not calls)
      (should (eq brutal-paper--saved-scroll-bar-mode 'right))
      (should brutal-paper--saved-horizontal-scroll-bar-mode))))

(ert-deftest brutal-paper-blocks-scroll-bar-mode-enabling-while-active ()
  "Keep native scroll bars off while their hiding option remains enabled."
  (let ((brutal-paper--modes-active t)
        (brutal-paper-hide-scroll-bars t))
    (should
     (equal (brutal-paper--force-scroll-bar-mode-off '(1)) '(-1)))
    (should
     (equal (brutal-paper--force-scroll-bar-mode-off '(toggle)) '(-1)))
    (should
     (equal (brutal-paper--force-scroll-bar-setting-off '(right)) '(nil)))
    (let ((brutal-paper--allow-scroll-bar-mode-change t))
      (should
       (equal (brutal-paper--force-scroll-bar-mode-off '(1)) '(1)))
      (should
       (equal (brutal-paper--force-scroll-bar-setting-off '(left))
              '(left))))))

(ert-deftest brutal-paper-canvas-margins-follow-outer-pixel-edges ()
  "Only windows touching a frame edge receive that Canvas margin."
  (let* ((frame (selected-frame))
         (scroll-bars (frame-parameter frame 'vertical-scroll-bars)))
    (unwind-protect
        (save-window-excursion
          ;; An earlier test can leave a scroll bar setting on the frame.  A
          ;; scroll bar removes the margin on its side, so remove the setting.
          (set-frame-parameter frame 'vertical-scroll-bars nil)
          (delete-other-windows)
          (let* ((left (selected-window))
                 (right (split-window-right))
                 (root-edges
                  (window-pixel-edges (frame-root-window frame))))
            (should (equal
                     (brutal-paper--window-canvas-outer-edge-margins
                      left root-edges)
                     (cons (brutal-paper--outer-edge-margin-columns
                            (window-frame left))
                           nil)))
            (should (equal
                     (brutal-paper--window-canvas-outer-edge-margins
                      right root-edges)
                     (cons nil
                           (brutal-paper--outer-edge-margin-columns
                            (window-frame right)))))))
      (set-frame-parameter frame 'vertical-scroll-bars scroll-bars))))

(ert-deftest brutal-paper-outer-scroll-bar-stays-adjacent-to-paper ()
  "Do not insert an outer Canvas margin before a native scroll bar."
  (let ((brutal-paper-window-gap 10)
        (root-edges '(0 0 100 100))
        scroll-bar-side
        frame-scroll-bar-side)
    (cl-letf (((symbol-function 'window-pixel-edges)
               (lambda (window)
                 (pcase window
                   ('left '(0 0 50 100))
                   ('right '(50 0 100 100)))))
              ((symbol-function 'window-frame) (lambda (_window) 'frame))
              ((symbol-function 'frame-char-width) (lambda (_frame) 10))
              ((symbol-function 'frame-parameter)
               (lambda (_frame parameter)
                 (and (eq parameter 'vertical-scroll-bars)
                      frame-scroll-bar-side)))
              ((symbol-function 'window-scroll-bars)
               (lambda (_window)
                 (list 12 1 scroll-bar-side nil nil nil nil))))
      (setq scroll-bar-side 'right)
      (should
       (equal (brutal-paper--window-canvas-outer-edge-margins
               'right root-edges)
              '(nil)))
      (should
       (equal (brutal-paper--window-canvas-outer-edge-margins
               'left root-edges)
              '(1)))
      (setq scroll-bar-side 'left)
      (should
       (equal (brutal-paper--window-canvas-outer-edge-margins
               'left root-edges)
              '(nil)))
      ;; A t value inherits the side from the frame rather than reporting
      ;; `left' or `right' directly.
      (setq scroll-bar-side t
            frame-scroll-bar-side 'right)
      (should
       (equal (brutal-paper--window-canvas-outer-edge-margins
               'right root-edges)
              '(nil))))))

(ert-deftest brutal-paper-canvas-margins-do-not-inset-the-frame ()
  "Keep outer Canvas columns in window margins, not the frame border."
  (let ((brutal-paper-enable-window-margins t)
        (brutal-paper-window-gap 10))
    (cl-letf (((symbol-function 'frame-char-width) (lambda (_frame) 10))
              ((symbol-function 'window-frame) (lambda (_window) 'frame))
              ((symbol-function 'window-pixel-edges)
               (lambda (_window) '(0 0 100 100)))
              ((symbol-function 'window-scroll-bars)
               (lambda (_window) '(0 0 nil nil nil nil nil))))
      (should (equal
               (brutal-paper--window-canvas-outer-edge-margins
                'window '(0 0 100 100))
               '(1 . 1))))))
(ert-deftest brutal-paper--mode-line-native-edges-use-canvas ()
  "Native mode-line regions outside the SVG must use the Canvas colour."
  (unwind-protect
      (progn
        (brutal-paper-mode 1)
        (let ((canvas (brutal-paper-canvas-color)))
          (dolist (face '(mode-line mode-line-active mode-line-inactive))
            (should (equal (face-background face nil t) canvas)))))
    (brutal-paper-mode -1)))

(ert-deftest brutal-paper-tab-bar-native-edges-use-configured-background ()
  "Cover native pixels outside the SVG row with its configured background."
  (let ((original-background (face-attribute 'tab-bar :background nil nil))
        (brutal-paper-canvas-background "#57e561")
        (brutal-paper-tab-bar-background "#123456")
        (brutal-paper-tab-colors '("#80e272")))
    (unwind-protect
        (progn
          (brutal-paper-mode 1)
          (set-face-attribute 'tab-bar nil :background "#dfdfdf")
          (brutal-paper--apply-faces)
          (let ((surface
                 (plist-get
                  (brutal-paper--tab-color-spec
                   (brutal-paper--current-tab-index) t)
                  :background)))
            (should (equal (face-background 'tab-bar nil t) "#123456"))
            (should
             (equal (face-background 'brutal-paper-tab-bar nil t) "#123456"))
            (should-not (equal (face-background 'tab-bar nil t) surface))))
      (brutal-paper-mode -1)
      (set-face-attribute 'tab-bar nil :background original-background))))

(ert-deftest brutal-paper-current-tab-opening-uses-canvas-between-rows ()
  "Keep Emacs 32's native inter-row pixel out of the current-tab opening."
  (let ((original-background (face-attribute 'tab-bar :background nil nil))
        (brutal-paper-canvas-background "#57e561")
        (brutal-paper-tab-bar-background "#123456")
        (brutal-paper-tab-model-function
         (lambda (_frame)
           '(:tabs ((:id parent :name "Parent" :current t))
             :sub-tabs ((:id main :name "main" :current t)
                        (:id review :name "review" :select ignore)))))
        (brutal-paper--tab-model-cache (make-hash-table :test #'eq)))
    (unwind-protect
        (progn
          (brutal-paper-mode 1)
          (brutal-paper--apply-faces)
          (should (equal (face-background 'tab-bar nil t) "#57e561")))
      (brutal-paper-mode -1)
      (set-face-attribute 'tab-bar nil :background original-background))))

(ert-deftest brutal-paper-frame-internal-border-is-zero-and-saved ()
  "Hide the internal border while retaining its pre-mode width."
  (let ((brutal-paper-rounded-frame-chrome nil)
        (brutal-paper--applying nil)
        (brutal-paper--saved-frame-chrome (make-hash-table :test #'eq))
        parameters)
    (cl-letf (((symbol-function 'brutal-paper--top-level-frame-p)
               (lambda (_frame) t))
              ((symbol-function 'display-graphic-p) (lambda (&optional _) t))
              ((symbol-function 'brutal-paper--effective-window-gap)
               (lambda (&optional _frame) 10))
              ((symbol-function 'minibuffer-window) (lambda (_frame) nil))
              ((symbol-function 'window-list) (lambda (&rest _) nil))
              ((symbol-function 'frame-parameter)
               (lambda (_frame parameter)
                 (and (eq parameter 'internal-border-width) 6)))
              ((symbol-function 'set-frame-parameter)
               (lambda (_frame parameter value)
                 (push (cons parameter value) parameters)))
              ((symbol-function 'brutal-paper--apply-window-divider-state)
               #'ignore)
              ((symbol-function 'brutal-paper-canvas-color)
               (lambda (&optional _frame) "#57e561"))
              ((symbol-function 'brutal-paper--style-echo-area-unless-isearch)
               #'ignore)
              ((symbol-function 'brutal-paper--normalize-window-edges)
               #'ignore))
      (brutal-paper--apply-frame 'frame))
    (should (equal (alist-get 'internal-border-width parameters) 0))
    (should
     (equal
      (alist-get 'internal-border-width
                 (gethash 'frame brutal-paper--saved-frame-chrome))
      6))))

(ert-deftest brutal-paper-tab-bar-background-follows-paper-or-current-tab ()
  "Resolve a fixed background or call its function with the current tab."
  (let ((brutal-paper-tab-bar-background nil)
        (brutal-paper-tab-model-function
         (lambda (_frame)
           '(:tabs ((:id notes :name "Notes" :select ignore)
                    (:id project :name "Project" :current t)))))
        (brutal-paper--tab-model-cache (make-hash-table :test #'eq))
        received)
    (cl-letf (((symbol-function 'brutal-paper--window-background)
               (lambda (&optional _frame) "#abcdef")))
      (should (equal (brutal-paper--tab-bar-background 'frame) "#abcdef"))
      (setq brutal-paper-tab-bar-background "#123456")
      (should (equal (brutal-paper--tab-bar-background 'frame) "#123456"))
      (setq brutal-paper-tab-bar-background
            (lambda (current-tab)
              (setq received current-tab)
              "#654321"))
      (should (equal (brutal-paper--tab-bar-background 'frame) "#654321"))
      (should (eq (plist-get received :id) 'project)))))

(ert-deftest brutal-paper-tab-bar-background-fills-the-complete-svg-row ()
  "Paint the configured background across the complete parent-row width."
  (let (rectangle)
    (cl-letf (((symbol-function 'brutal-paper--tab-bar-background)
               (lambda (&optional _frame) "#123456"))
              ((symbol-function 'brutal-paper-canvas-color)
               (lambda (&optional _frame) "#abcdef"))
              ((symbol-function 'svg-rectangle)
               (lambda (_svg x y width height &rest properties)
                 (setq rectangle (list x y width height properties)))))
      (brutal-paper--paint-tab-row 'svg 320 41 0))
    (should (equal (seq-take rectangle 4) '(0 0 320 41)))
    (should (equal (plist-get (nth 4 rectangle) :fill) "#123456"))))

(ert-deftest brutal-paper--tab-line-native-padding-uses-paper ()
  "Native tab-line regions outside the body SVG remain paper padding."
  (unwind-protect
      (progn
        (brutal-paper-mode 1)
        (let ((paper (brutal-paper--window-background)))
          (should (equal (face-background 'tab-line nil t) paper))
          (should (equal (face-background 'fringe nil t) paper))))
    (brutal-paper-mode -1)))

(ert-deftest brutal-paper-window-title-does-not-repeat-outer-margins ()
  "The body-width title SVG must start at its own first drawable pixel."
  (let ((brutal-paper--tab-line-image-cache
         (make-hash-table :test #'equal)))
    (cl-letf (((symbol-function 'display-images-p) (lambda (&rest _) t))
              ((symbol-function 'image-type-available-p)
               (lambda (type) (eq type 'svg)))
              ((symbol-function 'selected-window) (lambda () 'window))
              ((symbol-function 'window-frame) (lambda (_window) 'frame))
              ((symbol-function 'brutal-paper--font-spec)
               (lambda (&rest _)
                 '(:family "monospace" :weight normal :slant normal)))
              ((symbol-function 'mode-line-window-selected-p) (lambda () t))
              ((symbol-function 'brutal-paper--window-order)
               (lambda (&optional _window) '(1 . 1)))
              ((symbol-function 'buffer-name) (lambda (&optional _) "buffer"))
              ((symbol-function 'brutal-paper--line-position)
               (lambda () "1/1"))
              ((symbol-function 'brutal-paper--buffer-status)
               (lambda () "--"))
              ((symbol-function 'format-mode-line) (lambda (&rest _) "Text"))
              ((symbol-function 'brutal-paper--window-body-pixel-width)
               (lambda (&optional _window) 600))
              ((symbol-function 'brutal-paper--window-background)
               (lambda (&optional _frame) "#ffffff"))
              ((symbol-function 'brutal-paper--foreground-color)
               (lambda (&optional _frame) "#000000"))
              ((symbol-function 'brutal-paper--accent)
               (lambda (&optional _frame) "#3378c6"))
              ((symbol-function 'brutal-paper--svg-text-width)
               (lambda (&rest _) 40)))
      (let* ((image (brutal-paper--window-title-image))
             (svg (plist-get (cdr image) :data)))
        (should (string-match-p
                 "<rect[^>]+x=\"0\"[^>]+fill=\"#e0e0e0\"" svg))
        (should-not
         (string-match-p
          "<rect[^>]+x=\"0\"[^>]+fill=\"#80e272\"" svg))))))

(ert-deftest brutal-paper-window-title-fits-narrow-window ()
  "Long titles must end before the compact menu, including their padding."
  (let ((brutal-paper--tab-line-image-cache
         (make-hash-table :test #'equal)))
    (cl-letf (((symbol-function 'display-images-p) (lambda (&rest _) t))
              ((symbol-function 'image-type-available-p)
               (lambda (type) (eq type 'svg)))
              ((symbol-function 'selected-window) (lambda () 'window))
              ((symbol-function 'window-frame) (lambda (_window) 'frame))
              ((symbol-function 'brutal-paper--font-spec)
               (lambda (&rest _)
                 '(:family "monospace" :weight normal :slant normal)))
              ((symbol-function 'mode-line-window-selected-p) (lambda () t))
              ((symbol-function 'brutal-paper--window-order)
               (lambda (&optional _window) '(1 . 1)))
              ((symbol-function 'buffer-name) (lambda (&optional _) "*iSim: iPhone 18 Pro · CHMate Neue*"))
              ((symbol-function 'brutal-paper--line-position)
               (lambda () "1/1"))
              ((symbol-function 'brutal-paper--buffer-status)
               (lambda () "--"))
              ((symbol-function 'format-mode-line) (lambda (&rest _) "Text"))
              ((symbol-function 'brutal-paper--window-body-pixel-width)
               (lambda (&optional _window) 300))
              ((symbol-function 'brutal-paper--window-background)
               (lambda (&optional _frame) "#ffffff"))
              ((symbol-function 'brutal-paper--foreground-color)
               (lambda (&optional _frame) "#000000"))
              ((symbol-function 'brutal-paper--accent)
               (lambda (&optional _frame) "#3378c6"))
              ((symbol-function 'brutal-paper--svg-text-width)
               (lambda (text &rest _) (* 10 (length text)))))
      (let* ((image (brutal-paper--window-title-image))
             (svg (plist-get (cdr image) :data)))
        (should (string-match "<text[^>]+x=\"\\([0-9.]+\\)\"[^>]*>\\([^<]+\\)</text>" svg))
        ;; The second text node is the title (the first is the window order).
        (let* ((end (match-end 0)))
          (should (string-match "<text[^>]+x=\"\\([0-9.]+\\)\"[^>]*>\\([^<]+\\)</text>" svg end))
          (let ((x (string-to-number (match-string 1 svg)))
                (name (replace-regexp-in-string
                       "&#8230;" "…"
                       (replace-regexp-in-string "&#183;" "·"
                                                 (match-string 2 svg)))))
            (should (string-suffix-p "…" name))
            (should (<= (+ x (* 10 (length name))
                           brutal-paper-window-title-padding)
                        (- 300 brutal-paper-window-menu-width)))))))))

(ert-deftest brutal-paper--tab-line-caps-canvas-outside-paper-fringes ()
  "Paint outer Canvas margins without recolouring either paper fringe."
  (cl-letf (((symbol-function 'selected-window) (lambda () 'window))
            ((symbol-function 'window-live-p) (lambda (_window) t))
            ((symbol-function 'window-margins) (lambda (_window) '(1 . 1)))
            ((symbol-function 'window-font-width)
             (lambda (&optional _window _face) 10))
            ((symbol-function 'frame-char-width) (lambda (_frame) 10))
            ((symbol-function 'window-frame) (lambda (_window) 'frame))
            ((symbol-function 'brutal-paper-canvas-color)
             (lambda (&optional _frame) "#canvas"))
            ((symbol-function 'brutal-paper--window-title-image)
             (lambda () 'title-image)))
    (let* ((format (brutal-paper--tab-line))
           (left (car format))
           (right (car (last format))))
      (should (= (length format) 3))
      (should (equal (get-text-property 0 'display left)
                     '(space :width (10))))
      (should (equal (get-text-property 1 'display left)
                     '(space :align-to 0)))
      (should (equal (get-text-property 0 'display right)
                     '(space :align-to right-margin)))
      (should (equal (get-text-property 1 'display right)
                     '(space :width (10)))))))

(ert-deftest brutal-paper-fringe-indicators-use-muted-paper-ink ()
  "Keep continuation markers visible without using the editor's black ink."
  (load-theme 'modus-operandi t)
  (unwind-protect
      (progn
        (brutal-paper-mode 1)
        (let* ((paper (brutal-paper--window-background))
               (foreground (brutal-paper--foreground-color))
               (muted (brutal-paper--mix foreground paper 0.45)))
          (should (equal (face-foreground 'fringe nil t) muted))
          (should-not (equal (face-foreground 'fringe nil t) foreground))))
    (brutal-paper-mode -1)))

(ert-deftest brutal-paper-footer-shadow-uses-complete-window-geometry ()
  "Offset the shadow without extending beyond the paper's right edge."
  (let ((brutal-paper-enable-window-shadow t))
    (should
     (equal
      (brutal-paper--window-footer-shadow-geometry 100 12 12 10 0 10)
      '(:x 14 :y 12 :width 76 :height 4)))
    (should-not
     (brutal-paper--window-footer-shadow-geometry 100 12 3 10 0 10)))
  (let ((brutal-paper-enable-window-shadow nil))
    (should-not
     (brutal-paper--window-footer-shadow-geometry 100 12 12 10 0 10))))

(ert-deftest brutal-paper-hard-shadow-chooses-the-visible-polarity ()
  "Keep hard shadows distinct from both Paper and Canvas appearances."
  (let ((brutal-paper-shadow-color nil)
        (brutal-paper-shadow-mix '(:light 0.38 :dark 0.16))
        (canvas "#2a2b32")
        (background "#1c1c1c")
        (dark t))
    (cl-letf (((symbol-function 'brutal-paper-canvas-color)
               (lambda (&optional _) canvas))
              ((symbol-function 'brutal-paper--window-background)
               (lambda (&optional _) background))
              ((symbol-function 'brutal-paper--dark-appearance-p)
               (lambda (&optional _) dark)))
      (let ((shadow (brutal-paper-hard-shadow)))
        (should
         (>= (brutal-paper-test--contrast-ratio shadow background) 1.5))
        (should
         (>= (brutal-paper-test--contrast-ratio shadow canvas) 1.5))
        (should (> (brutal-paper--relative-luminance shadow)
                   (brutal-paper--relative-luminance canvas))))
      (setq dark nil
            background "#ffffff"
            canvas "#57e561")
      (let ((shadow (brutal-paper-hard-shadow)))
        (should (< (brutal-paper--relative-luminance shadow)
                   (brutal-paper--relative-luminance canvas)))))))

(ert-deftest brutal-paper-window-gutters-share-one-realized-pixel-width ()
  "Quantize every Canvas gutter to the native outer-margin grid."
  (let ((brutal-paper-enable-window-margins t)
        (brutal-paper-window-gap 10))
    (cl-letf (((symbol-function 'frame-char-width) (lambda (_frame) 7))
              ((symbol-function 'brutal-paper--sub-tabs-visible-p)
               (lambda (&optional _frame) nil)))
      (should (= (brutal-paper--outer-edge-margin-columns 'frame) 1))
      (should (= (brutal-paper--effective-window-gap 'frame) 7))
      (should (= (brutal-paper--main-tab-row-gap 'frame) 7)))))

(ert-deftest brutal-paper-footer-shadow-belongs-only-to-current-window ()
  "Keep inactive footer gaps clear while the current window casts a shadow."
  (let ((brutal-paper--mode-line-image-cache
         (make-hash-table :test #'equal))
        (brutal-paper--canvas-image-cache (make-hash-table :test #'equal))
        (brutal-paper--canvas-image-signatures (make-hash-table :test #'eq))
        active)
    (cl-letf (((symbol-function 'display-images-p) (lambda (&rest _) t))
              ((symbol-function 'selected-window) (lambda () 'window))
              ((symbol-function 'window-frame) (lambda (_window) 'frame))
              ((symbol-function 'brutal-paper--window-complete-pixel-width)
               (lambda (_window) 200))
              ((symbol-function 'brutal-paper--window-edge-widths)
               (lambda (_window) '(10 . 10)))
              ((symbol-function 'window-right-divider-width)
               (lambda (_window) 10))
              ((symbol-function 'facep) (lambda (_face) t))
              ((symbol-function 'face-attribute)
               (lambda (&rest _) "gray20"))
              ((symbol-function 'color-values)
               (lambda (_colour &optional _frame) '(13107 13107 13107)))
              ((symbol-function 'brutal-paper-canvas-color)
               (lambda (&optional _frame) "#57e561"))
              ((symbol-function 'brutal-paper-hard-shadow)
               (lambda (&optional _frame) "#447b93"))
              ((symbol-function 'mode-line-window-selected-p)
               (lambda () active)))
      (let* ((inactive (brutal-paper--window-footer-image))
             (surface brutal-paper-window-footer-surface-height))
        (should (eq (image-property inactive :type)
                    (brutal-paper-test--structural-image-type)))
        (should (= (brutal-paper-test--structural-pixel inactive 10 0)
                   #xff333333))
        (should (= (brutal-paper-test--structural-pixel inactive 14 surface)
                   #xff57e561)))
      (setq active t)
      (let* ((current (brutal-paper--window-footer-image))
             (surface brutal-paper-window-footer-surface-height))
        (should (= (brutal-paper-test--structural-pixel current 14 surface)
                   #xff447b93))))))

(ert-deftest brutal-paper-shadow-follows-window-selection ()
  "Own the selection callback only during an active mode session."
  (let ((window-selection-change-functions nil))
    (unwind-protect
        (progn
          (brutal-paper--set-hooks t)
          (should
           (memq #'brutal-paper--window-selection-changed
                 window-selection-change-functions)))
      (brutal-paper--set-hooks nil))
    (should-not
     (memq #'brutal-paper--window-selection-changed
           window-selection-change-functions))))
(ert-deftest brutal-paper-shadow-does-not-follow-buffer-scrolling ()
  "Keep footer refresh hooks out of content-only scrolling."
  (should-not
   (seq-some
    (lambda (function)
      (and (symbolp function)
           (string-prefix-p "brutal-paper" (symbol-name function))))
    window-scroll-functions)))
(ert-deftest brutal-paper-footer-measures-the-complete-split-window ()
  "Include both fringes when sizing a split window's footer SVG."
  (cl-letf (((symbol-function 'window-live-p) (lambda (_window) t))
            ((symbol-function 'window-pixel-width)
             (lambda (&optional _window) 200))
            ((symbol-function 'window-body-width)
             (lambda (&optional _window _pixelwise) 150))
            ((symbol-function 'window-margins)
             (lambda (&optional _window) '(1)))
            ((symbol-function 'window-font-width)
             (lambda (&optional _window _face) 10)))
    (should (= (brutal-paper--window-complete-pixel-width 'window) 200))
    (should (equal (brutal-paper--window-edge-widths 'window) '(10 . 0)))))

(ert-deftest brutal-paper-footer-ignores-buffer-local-font-scaling ()
  "Measure native margin columns with the frame font, not remapped text."
  (cl-letf (((symbol-function 'window-live-p) (lambda (_window) t))
            ((symbol-function 'window-margins)
             (lambda (&optional _window) '(1 . 1)))
            ((symbol-function 'window-frame) (lambda (_window) 'frame))
            ((symbol-function 'frame-char-width) (lambda (_frame) 10))
            ((symbol-function 'window-font-width)
             (lambda (&optional _window _face) 20)))
    (should (equal (brutal-paper--window-edge-widths 'window) '(10 . 10)))))

(ert-deftest brutal-paper-apply-cleans-disabled-echo-and-margins ()
  "Remove disabled echo and margin features through the public entry."
  (let ((brutal-paper-mode t)
        (brutal-paper-enable-echo-area nil)
        (brutal-paper-enable-window-margins nil)
        actions)
    (cl-letf (((symbol-function 'brutal-paper--restore-echo-area)
               (lambda () (push 'echo actions)))
              ((symbol-function 'brutal-paper--restore-window-edges)
               (lambda () (push 'edges actions)))
              ((symbol-function 'brutal-paper--apply-faces)
               (lambda (&optional frame) (push (list 'faces frame) actions)))
              ((symbol-function 'brutal-paper--apply-frame)
               (lambda (&optional frame) (push (list 'frame frame) actions))))
      (brutal-paper-apply 'target-frame))
    (should
     (equal (nreverse actions)
            '(echo edges
              (faces target-frame)
              (frame target-frame))))))

(ert-deftest brutal-paper-apply-refreshes-tab-bar-immediately ()
  "Invalidate cached tab displays and redraw the requested frame in apply."
  (let ((brutal-paper-mode t)
        cleared installed forced synchronized redrawn)
    (cl-letf (((symbol-function 'brutal-paper--clear-image-caches)
               (lambda () (setq cleared t)))
              ((symbol-function 'brutal-paper--install-all-buffer-chrome)
               (lambda () (setq installed t)))
              ((symbol-function 'brutal-paper--apply-faces) #'ignore)
              ((symbol-function 'brutal-paper--apply-frame) #'ignore)
              ((symbol-function 'force-mode-line-update)
               (lambda (&optional all) (setq forced (or all t))))
              ((symbol-function 'frame-live-p) (lambda (_frame) t))
              ((symbol-function 'brutal-paper--top-level-frame-p)
               (lambda (_frame) t))
              ((symbol-function 'brutal-paper--sync-canvas-faces) #'ignore)
              ((symbol-function 'brutal-paper--sync-tab-bar-lines)
               (lambda (frame) (push frame synchronized)))
              ((symbol-function 'redraw-frame)
               (lambda (frame) (push frame redrawn))))
      (brutal-paper-apply 'target-frame))
    (should cleared)
    (should installed)
    (should forced)
    (should (equal synchronized '(target-frame)))
    (should (equal redrawn '(target-frame)))))

(ert-deftest brutal-paper-apply-is-inert-while-disabled ()
  "The public apply command must not mutate an inactive theme."
  (let ((brutal-paper-mode nil)
        calls)
    (cl-letf (((symbol-function 'brutal-paper--clear-image-caches)
               (lambda () (push 'cache calls)))
              ((symbol-function 'brutal-paper--install-all-buffer-chrome)
               (lambda () (push 'buffers calls)))
              ((symbol-function 'brutal-paper--apply-faces)
               (lambda (&optional _frame) (push 'faces calls)))
              ((symbol-function 'brutal-paper--apply-frame)
               (lambda (&optional _frame) (push 'frame calls))))
      (brutal-paper-apply 'target-frame))
    (should-not calls)))

(ert-deftest brutal-paper-refresh-redraws-without-reapplying-geometry ()
  "Let consumers refresh native tab data without touching frame geometry."
  (let (cleared refreshed applied)
    (cl-letf (((symbol-function 'brutal-paper--clear-image-caches)
               (lambda () (setq cleared t)))
              ((symbol-function 'brutal-paper--refresh-rendered-chrome)
               (lambda (&optional frame) (setq refreshed frame)))
              ((symbol-function 'brutal-paper--apply-frame)
               (lambda (&rest _) (setq applied t))))
      (brutal-paper-refresh 'target-frame))
    (should cleared)
    (should (eq refreshed 'target-frame))
    (should-not applied)))

(ert-deftest brutal-paper-consumer-model-renders-parent-and-sub-tabs ()
  "Render consumer data without exposing tab presentation to the consumer."
  (let* ((selected nil)
         (calls 0)
         (frame (selected-frame))
         (brutal-paper-window-gap 10)
         (brutal-paper--tab-model-cache
          (make-hash-table :test #'eq :weakness 'key))
         (brutal-paper-tab-model-function
          (lambda (candidate)
            (should (eq candidate frame))
            (cl-incf calls)
            (list
             :tabs
             (list (list :id 'general :name "Notes" :current nil
                         :select (lambda () (setq selected 'general)))
                   (list :id 'project :name "Widget" :current t))
             :sub-tabs
             (list (list :id 'main :name "main" :current t)
                   (list :id 'qa :name "qa" :subtitle "Verify release"
                         :current nil
                         :select (lambda () (setq selected 'qa))))))))
    (cl-letf (((symbol-function 'display-images-p) (lambda (&rest _) nil))
              ((symbol-function 'brutal-paper--sub-tab-row-spacer)
               (lambda (&rest _) nil))
              ((symbol-function 'frame-inner-width) (lambda (&rest _) 800))
              ((symbol-function 'brutal-paper--frame-paper-left-offset)
               (lambda (&rest _) 10)))
      (let ((parents (brutal-paper--tab-bar-format-tabs))
            (children (brutal-paper--tab-bar-format-sub-tabs)))
        (should (= (length parents) 2))
        (should (= (length children) 2))
        (should (string-search "Notes" (nth 2 (car parents))))
        (should (string-search "qa" (nth 2 (cadr children))))
        (funcall (nth 3 (car parents)))
        (should (eq selected 'general))
        (funcall (nth 3 (cadr children)))
        (should (eq selected 'qa))
        (should (zerop (brutal-paper--main-tab-row-gap frame)))
        (should (= calls 1))))))

(ert-deftest brutal-paper-sub-tab-row-omits-the-last-separator ()
  "Never draw a trailing separator after the final secondary tab."
  (let ((items (list (list :id 'first :name "first" :current t)
                     (list :id 'middle :name "middle")
                     (list :id 'last :name "last")))
        captured)
    (cl-letf (((symbol-function 'selected-frame) (lambda () 'frame))
              ((symbol-function 'brutal-paper--sub-tabs-visible-p)
               (lambda (&optional _) t))
              ((symbol-function 'brutal-paper--tab-model-items)
               (lambda (_key _frame) items))
              ((symbol-function 'brutal-paper--sub-tab-target-widths)
               (lambda (_items _frame) '(100 100 100)))
              ((symbol-function 'brutal-paper--frame-paper-left-offset)
               (lambda (_frame) 0))
              ((symbol-function 'brutal-paper--sub-tab-row-spacer)
               (lambda (&rest _) nil))
              ((symbol-function 'frame-inner-width) (lambda (_frame) 300))
              ((symbol-function 'brutal-paper--sub-tab-label)
               (lambda (item _index _width suppress-divider _frame)
                 (push (cons (plist-get item :id) suppress-divider) captured)
                 "label"))
              ((symbol-function 'brutal-paper--tab-menu-item)
               (lambda (_item index _label _kind) index)))
      (brutal-paper--tab-bar-format-sub-tabs))
    (should (equal (nreverse captured)
                   '((first . t) (middle) (last . t))))))

(ert-deftest brutal-paper-parent-sub-tab-junction-skips-current-tab ()
  "Draw the parent-row junction everywhere except below the open tab."
  (let ((brutal-paper-tab-model-function
         (lambda (_frame)
           (list
            :tabs
            (list (list :id 'general :name "general" :select #'ignore)
                  (list :id 'theme :name "theme" :select #'ignore)
                  (list :id 'config :name "config" :select #'ignore)
                  (list :id 'demo :name "demo" :current t))
            :sub-tabs
            (list (list :id 'main :name "main" :current t)
                  (list :id 'review :name "review" :select #'ignore)))))
        (brutal-paper--tab-model-cache (make-hash-table :test #'eq))
        (brutal-paper-tab-junction-width 1))
    (cl-letf (((symbol-function 'brutal-paper--tab-base-color)
               (lambda (index &optional _frame)
                 (if (zerop index) "#80e272" "#ffdc62")))
              ((symbol-function 'brutal-paper--tab-marker-color)
               (lambda (&rest _) "#003e2d"))
              ((symbol-function 'brutal-paper--mix)
               (lambda (&rest _) "#225522"))
              ((symbol-function 'brutal-paper--window-background)
               (lambda (&optional _) "#ffffff"))
              ((symbol-function 'brutal-paper-canvas-color)
               (lambda (&optional _) "#80e272"))
              ((symbol-function 'brutal-paper--font-spec)
               (lambda (&rest _)
                 '(:family "monospace" :weight normal :slant normal)))
              ((symbol-function 'brutal-paper--svg-text-width)
               (lambda (&rest _) 20)))
      (let* ((current-svg
              (brutal-paper--tab-svg
               '(current-tab (name . "Demo")) 4))
             (inactive-svgs
              (list (brutal-paper--tab-svg '(tab (name . "General")) 1)
                    (brutal-paper--tab-svg '(tab (name . "Theme")) 2)
                    (brutal-paper--tab-svg '(tab (name . "Config")) 3)))
             (current-junction
              (seq-find
               (lambda (rectangle)
                 (equal (dom-attr rectangle 'class)
                        "brutal-paper-tab-junction"))
               (dom-by-tag current-svg 'rect)))
             (inactive-junctions
              (mapcar
               (lambda (svg)
                 (seq-find
                  (lambda (rectangle)
                    (equal (dom-attr rectangle 'class)
                           "brutal-paper-tab-junction"))
                  (dom-by-tag svg 'rect)))
               inactive-svgs))
             (current-outline
              (seq-find (lambda (path) (dom-attr path 'stroke))
                        (dom-by-tag current-svg 'path))))
        (should current-junction)
        (should (cl-every #'identity inactive-junctions))
        (should current-outline)
        (should (> (dom-attr current-junction 'x) 0))
        (dolist (junction inactive-junctions)
          (should (= (dom-attr junction 'x) 0)))
        (should
         (equal (dom-attr current-junction 'fill)
                (dom-attr current-outline 'stroke)))
        (dolist (junction inactive-junctions)
          (should
           (equal (dom-attr junction 'fill)
                  (dom-attr current-outline 'stroke))))
        (dolist (junction (cons current-junction inactive-junctions))
          (should (= (dom-attr junction 'height) 1))
          (should
           (= (+ (dom-attr junction 'y)
                 (dom-attr junction 'height))
              brutal-paper-tab-row-height)))))))

(ert-deftest brutal-paper-parent-row-junction-does-not-require-sub-tabs ()
  "Keep the parent-row rule visible when no secondary row is present."
  (let ((brutal-paper-tab-model-function nil)
        (brutal-paper-tab-junction-width 1)
        rectangles)
    (cl-letf (((symbol-function 'svg-rectangle)
               (lambda (_svg x y width height &rest properties)
                 (push (list x y width height properties) rectangles))))
      (brutal-paper--paint-tab-junction 'svg 0 120))
    (should (= (length rectangles) 1))
    (should (= (nth 0 (car rectangles)) 0))
    (should (= (nth 2 (car rectangles)) 120))
    (should
     (equal (plist-get (nth 4 (car rectangles)) :class)
            "brutal-paper-tab-junction"))))

(ert-deftest brutal-paper-parent-fill-uses-only-the-unoccupied-row-width ()
  "Complete the parent row without wrapping a filler onto its own line."
  (let ((items '((:id one :name "one" :current t)
                 (:id two :name "two" :select ignore)))
        rendered-width)
    (cl-letf (((symbol-function 'selected-frame) (lambda () 'frame))
              ((symbol-function 'frame-inner-width)
               (lambda (&optional _) 260))
              ((symbol-function 'brutal-paper--tab-model-items)
               (lambda (_kind _frame) items))
              ((symbol-function 'brutal-paper--parent-row-leading-width)
               (lambda (_frame) 60))
              ((symbol-function 'brutal-paper--parent-tab-layout)
               (lambda (_items _frame)
                 '((:width 40) (:width 70))))
              ((symbol-function 'brutal-paper--fill-image)
               (lambda (width &optional _frame)
                 (setq rendered-width width)
                 'fill-image)))
      (brutal-paper--tab-bar-format-fill)
      (should (= rendered-width 90)))))

(ert-deftest brutal-paper-parent-global-status-reserves-space-and-uses-the-fill ()
  "Keep native global status visible at the right edge of the parent row."
  (let ((items '((:id one :name "one" :current t)
                 (:id two :name "two")))
        rendered-status)
    (cl-letf (((symbol-function 'tab-bar-format-global)
               (lambda () '((global menu-item " Ace - Window " ignore))))
              ((symbol-function 'frame-inner-width) (lambda (&rest _) 260))
              ((symbol-function 'brutal-paper--parent-row-leading-width)
               (lambda (&rest _) 60))
              ((symbol-function 'brutal-paper--parent-tab-widths)
               (lambda (&rest _) '(40 120)))
              ((symbol-function 'brutal-paper--tab-bar-global-status-width)
               (lambda (&rest _) 80))
              ((symbol-function 'svg-text)
               (lambda (_svg text &rest _) (setq rendered-status text))))
      (should
       (= (apply #'+
                 (mapcar (lambda (entry) (plist-get entry :width))
                         (brutal-paper--parent-tab-layout items 'frame)))
          120))
      (clrhash brutal-paper--tab-fill-image-cache)
      (brutal-paper--fill-image 120)
      (should (equal rendered-status "Ace - Window")))))

(ert-deftest brutal-paper-parent-tabs-use-neutral-menu-cell-face ()
  "Keep native per-tab faces from covering the SVG junction baseline."
  (cl-letf (((symbol-function 'brutal-paper--tab-image)
             (lambda (&rest _) 'parent-image)))
    (let ((fill (brutal-paper--static-tab-cell 'fill-image "fill"))
          (current
           (brutal-paper--tab-name-format
            '(current-tab (name . "Current")) 1))
          (inactive
           (brutal-paper--tab-name-format
            '(tab (name . "Inactive")) 2)))
      (should (eq (get-text-property 0 'face fill) 'tab-bar))
      (should (eq (get-text-property 0 'face current) 'tab-bar))
      (should (eq (get-text-property 0 'face inactive) 'tab-bar)))))

(ert-deftest brutal-paper-tab-cell-identities-separate-consumer-rows ()
  "Give parent and secondary rows distinct native menu identities."
  (cl-letf (((symbol-function 'brutal-paper--tab-image)
             (lambda (&rest _) 'parent-image))
            ((symbol-function 'brutal-paper--sub-tab-image)
             (lambda (&rest _) 'sub-image))
            ((symbol-function 'brutal-paper--window-background)
             (lambda (&optional _) "#ffffff")))
    (let ((parent
           (brutal-paper--tab-name-format
            '(current-tab (name . "Theme")) 1))
          (sub
           (brutal-paper--sub-tab-label
            '(:id main :name "main" :current t) 1 100 t)))
      (should-not
       (equal (substring-no-properties parent)
              (substring-no-properties sub))))))

(ert-deftest brutal-paper-tab-hover-keeps-svg-outline-free ()
  "Keep native hover decoration outside complete SVG tab cells."
  (cl-letf (((symbol-function 'brutal-paper--tab-image)
             (lambda (&rest _) 'parent-image))
            ((symbol-function 'brutal-paper--sub-tab-image)
             (lambda (&rest _) 'sub-image))
            ((symbol-function 'brutal-paper--window-background)
             (lambda (&optional _) "#ffffff")))
    (let ((parent
           (brutal-paper--tab-name-format
            '(current-tab (name . "Theme")) 1))
          (sub
           (brutal-paper--sub-tab-label
            '(:id main :name "main" :current t) 1 100 t))
          (parent-static
           (brutal-paper--static-tab-cell 'parent-image "parent"))
          (sub-static
           (brutal-paper--static-tab-cell
            'sub-image "sub" 'brutal-paper-sub-tab-hover)))
      (should
       (eq (get-text-property 0 'mouse-face parent)
           'brutal-paper-tab-hover))
      (should
       (eq (get-text-property 0 'mouse-face sub)
           'brutal-paper-sub-tab-hover))
      (should
       (eq (get-text-property 0 'mouse-face parent-static)
           'brutal-paper-tab-hover))
      (should
       (eq (get-text-property 0 'mouse-face sub-static)
           'brutal-paper-sub-tab-hover)))))

(ert-deftest brutal-paper-hover-face-bypasses-native-highlight-box ()
  "Use an unboxed hover face without consuming the user's native face."
  (let ((native-face-p (facep 'tab-bar-tab-highlight))
        (original-box
         (and (facep 'tab-bar-tab-highlight)
              (face-attribute 'tab-bar-tab-highlight :box nil nil)))
        (user-box '(:line-width 2 :style released-button)))
    (unwind-protect
        (progn
          (when native-face-p
            (set-face-attribute 'tab-bar-tab-highlight nil
                                :box user-box))
          (brutal-paper-mode 1)
          (brutal-paper--apply-faces)
          (should-not
           (face-attribute 'brutal-paper-tab-hover :box nil nil))
          (should-not
           (face-attribute 'brutal-paper-sub-tab-hover :box nil nil))
          (should
           (equal (face-background 'brutal-paper-tab-hover nil t)
                  (brutal-paper--window-background)))
          (should
           (equal (face-background 'brutal-paper-sub-tab-hover nil t)
                  (brutal-paper-canvas-color)))
          (when native-face-p
            (should
             (equal (face-attribute
                     'tab-bar-tab-highlight :box nil nil)
                    user-box))))
      (brutal-paper-mode -1)
      (when native-face-p
        (set-face-attribute 'tab-bar-tab-highlight nil
                            :box original-box)))))

(ert-deftest brutal-paper-sub-tabs-center-content-and-mute-separators ()
  "Center the complete secondary row and keep its dividers subordinate."
  (let ((brutal-paper-window-gap 10)
        (brutal-paper-sub-tab-row-height 24)
        (brutal-paper-sub-tab-pill-inset 2)
        (brutal-paper-sub-tab-separator-height 8)
        (brutal-paper-sub-tab-separator-color-mix 0.12))
    (cl-letf (((symbol-function 'brutal-paper-canvas-color)
               (lambda (&optional _) "#57e561"))
              ((symbol-function 'brutal-paper--tab-marker-color)
               (lambda (&rest _) "#118833"))
              ((symbol-function 'brutal-paper--readable-ink)
               (lambda (&rest _) "#111111"))
              ((symbol-function 'brutal-paper--svg-centered-visible-text-y)
               (lambda (&rest _)
                 (ert-fail "Sub-tab centering must use the SVG renderer"))))
      (let* ((svg
              (brutal-paper--sub-tab-svg
               '(:id current :name "currentCase" :current t) 1 180 t))
             (rectangles (dom-by-tag svg 'rect))
             (texts (dom-by-tag svg 'text))
             (pill (cadr rectangles)))
        (should (= (dom-attr pill 'y) 7.0))
        (should (equal (dom-text (cadr texts)) "currentCase"))
        (dolist (text texts)
          (should (equal (dom-attr text 'dominant-baseline) "middle"))
          (should (= (dom-attr text 'y) 17.0))))
      (let* ((svg
              (brutal-paper--sub-tab-svg
               '(:id inactive :name "inactive" :current nil) 2 100 nil))
             (separator (car (dom-by-tag svg 'line))))
        (should (= (dom-attr separator 'y1) 13.0))
        (should (= (dom-attr separator 'y2) 21.0))
        (should
         (equal (dom-attr separator 'stroke)
                (brutal-paper--mix "#57e561" "#111111" 0.12)))))))

(ert-deftest brutal-paper-svg-centered-text-uses-explicit-baseline ()
  "Optically balance SVG text from the selected font's metrics and size."
  (let ((font '(:family "Metric Sans" :weight normal :slant normal))
        (brutal-paper-svg-text-fallback-baseline-ratio 0.22)
        (brutal-paper-svg-text-optical-bias-ratio 0.25))
    (cl-letf (((symbol-function 'brutal-paper--svg-font-line-metrics)
               (lambda (&rest _)
                 '(:size 24 :height 36 :ascent 26 :descent 10))))
      (should
       (= (brutal-paper--svg-centered-text-y 17.0 12 font)
          22.5)))
    (cl-letf (((symbol-function 'brutal-paper--svg-font-line-metrics)
               (lambda (&rest _) nil)))
      (should
       (= (brutal-paper--svg-centered-text-y 17.0 12 font)
          19.64))))
  (should
   (= (brutal-paper--window-title-center-y)
      (+ brutal-paper-window-title-top
         (/ brutal-paper-window-title-block-height 2.0)))))

(ert-deftest brutal-paper-svg-visible-text-centers-the-realized-ink-box ()
  "Center title-like text from its realized ascender and descender."
  (let ((font '(:family "Metric Sans" :weight normal :slant normal)))
    (cl-letf (((symbol-function 'brutal-paper--svg-font-glyph-metrics)
               (lambda (text &rest _)
                 (should (equal text "1 TITLE"))
                 '(:size 24 :ascent 18 :descent 2))))
      (should
       (= (brutal-paper--svg-centered-visible-text-y
           17.0 "1 TITLE" 12 font)
          21.0)))
    (cl-letf (((symbol-function 'brutal-paper--svg-font-glyph-metrics)
               (lambda (&rest _) nil))
              ((symbol-function 'brutal-paper--svg-centered-text-y)
               (lambda (&rest _) 23.5)))
      (should
       (= (brutal-paper--svg-centered-visible-text-y
           17.0 "1 TITLE" 12 font)
          23.5)))))

(ert-deftest brutal-paper-badge-number-centers-its-own-ink-box ()
  "Center a badge number independently of the title's optical bias."
  (let ((font '(:family "Metric Sans" :weight normal :slant normal)))
    (cl-letf (((symbol-function 'brutal-paper--svg-font-glyph-metrics)
               (lambda (&rest _)
                 '(:size 24 :ascent 18 :descent 2))))
      (should
       (= (brutal-paper--svg-centered-glyph-text-y
           17.0 "1" 12 font)
          21.0)))
    (cl-letf (((symbol-function 'brutal-paper--svg-font-glyph-metrics)
               (lambda (&rest _) nil))
              ((symbol-function 'brutal-paper--svg-centered-text-y)
               (lambda (&rest _) 22.5)))
      (should
       (= (brutal-paper--svg-centered-glyph-text-y
           17.0 "1" 12 font)
          22.5)))))

(ert-deftest brutal-paper-parent-badge-and-title-share-a-visible-center ()
  "Center the badge and realized title ink on the same horizontal axis."
  (let ((font '(:family "Metric Sans" :weight normal :slant normal)))
    (cl-letf (((symbol-function 'brutal-paper--font-spec)
               (lambda (&rest _) font))
              ((symbol-function 'brutal-paper--svg-text-width)
               (lambda (&rest _) 20))
              ((symbol-function 'brutal-paper--main-tab-row-gap)
               (lambda (&optional _) 0))
              ((symbol-function 'brutal-paper--window-background)
               (lambda (&optional _) "#ffffff"))
              ((symbol-function 'brutal-paper-canvas-color)
               (lambda (&optional _) "#57e561"))
              ((symbol-function 'brutal-paper--tab-color-spec)
               (lambda (&rest _)
                 '(:background "#57e561" :foreground "#111111"
                   :qualifier "#555555" :badge "#00402a"
                   :badge-foreground "#ffffff" :border "#118833")))
              ((symbol-function 'brutal-paper--svg-centered-visible-text-y)
               (lambda (&rest _)
                 (ert-fail "Tab centering must use the SVG renderer")))
              ((symbol-function 'brutal-paper--svg-centered-glyph-text-y)
               (lambda (&rest _)
                 (ert-fail "Tab centering must use the SVG renderer"))))
      (let* ((svg
             (brutal-paper--tab-svg
               '(current-tab (name . "Theme")) 1))
             (circle (car (dom-by-tag svg 'circle)))
             (order (car (dom-by-tag svg 'text)))
             (center (brutal-paper--tab-content-center-y)))
        (should (= (dom-attr circle 'cy) center))
        (should (= (dom-attr order 'x) (dom-attr circle 'cx)))
        (dolist (text (dom-by-tag svg 'text))
          (should (= (dom-attr text 'y) center))
          (should (equal (dom-attr text 'dominant-baseline) "middle")))))))

(ert-deftest brutal-paper-current-tab-font-is-bold-by-default ()
  "Emphasize selected tabs through their independent font source."
  (should (eq brutal-paper-current-tab-font 'bold))
  (let ((brutal-paper-current-tab-font 'current-tab-source)
        (brutal-paper-inactive-tab-font 'inactive-tab-source)
        (brutal-paper-current-title-font 'current-title-source)
        (brutal-paper-inactive-title-font 'inactive-title-source))
    (cl-letf (((symbol-function 'brutal-paper--font-spec)
               (lambda (source &optional frame)
                 (list source frame))))
      (should
       (equal (brutal-paper--tab-font-spec t 'frame)
              '(current-tab-source frame)))
      (should
       (equal (brutal-paper--tab-font-spec nil 'frame)
              '(inactive-tab-source frame)))
      (should
       (equal (brutal-paper--title-font-spec t 'frame)
              '(current-title-source frame)))
      (should
       (equal (brutal-paper--title-font-spec nil 'frame)
              '(inactive-title-source frame))))))

(ert-deftest brutal-paper-sub-tab-font-follows-tabs-or-its-own-source ()
  "Resolve sub-tab fonts from the tab fonts or from their own sources."
  (should (eq brutal-paper-current-sub-tab-font :tab))
  (should (eq brutal-paper-inactive-sub-tab-font :tab))
  (let ((brutal-paper-current-tab-font 'current-tab-source)
        (brutal-paper-inactive-tab-font 'inactive-tab-source)
        (brutal-paper-current-sub-tab-font :tab)
        (brutal-paper-inactive-sub-tab-font :tab))
    (cl-letf (((symbol-function 'brutal-paper--font-spec)
               (lambda (source &optional frame)
                 (list source frame))))
      (should
       (equal (brutal-paper--sub-tab-font-spec t 'frame)
              '(current-tab-source frame)))
      (should
       (equal (brutal-paper--sub-tab-font-spec nil 'frame)
              '(inactive-tab-source frame)))
      (setq brutal-paper-current-sub-tab-font nil
            brutal-paper-inactive-sub-tab-font "Sub Sans")
      (should
       (equal (brutal-paper--sub-tab-font-spec t 'frame)
              '(nil frame)))
      (should
       (equal (brutal-paper--sub-tab-font-spec nil 'frame)
              '("Sub Sans" frame))))))

(ert-deftest brutal-paper-svg-font-weight-uses-css-values ()
  "Write face weights as values that the SVG renderer accepts."
  (should (equal (brutal-paper--svg-font-weight 'semi-bold) "600"))
  (should (equal (brutal-paper--svg-font-weight 'bold) "700"))
  (should (equal (brutal-paper--svg-font-weight 'regular) "400"))
  (should (equal (brutal-paper--svg-font-weight 'light) "300"))
  (should (equal (brutal-paper--svg-font-weight 'unknown) "400")))

(ert-deftest brutal-paper-tab-model-status-reaches-the-order-badge ()
  "Render user-defined consumer statuses without changing the tab label."
  (let ((font '(:family "Metric Sans" :weight normal :slant normal))
        (brutal-paper-tab-statuses
         '((busy :icon dots :face warning :label "...")
           (ready :icon check :face success :label "✓")
           (blocked :icon cross :face error :label "✗"))))
    (cl-letf (((symbol-function 'brutal-paper--font-spec)
               (lambda (&rest _) font))
              ((symbol-function 'brutal-paper--svg-text-width)
               (lambda (&rest _) 20))
              ((symbol-function 'brutal-paper--main-tab-row-gap)
               (lambda (&optional _) 0))
              ((symbol-function 'brutal-paper--window-background)
               (lambda (&optional _) "#ffffff"))
              ((symbol-function 'brutal-paper-canvas-color)
               (lambda (&optional _) "#57e561"))
              ((symbol-function 'brutal-paper--tab-color-spec)
               (lambda (&rest _)
                 '(:background "#57e561" :foreground "#111111"
                   :qualifier "#555555" :badge "#00402a"
                   :badge-foreground "#ffffff" :border "#118833")))
              ((symbol-function 'brutal-paper--svg-centered-visible-text-y)
               (lambda (center &rest _) (+ center 5.0)))
              ((symbol-function 'brutal-paper--svg-centered-glyph-text-y)
               (lambda (center &rest _) (+ center 5.0))))
      (dolist (spec '((busy . circle)
                      (ready . polyline)
                      (blocked . line)))
        (let* ((status (car spec))
               (item `(:id project :name "Theme" :current t
                       :status ,status))
               (svg (brutal-paper--tab-svg
                     (brutal-paper--tab-item-as-native-tab item) 1))
               (marker
                (car (dom-by-class svg "brutal-paper-tab-status-marker")))
               (icon
                (car (dom-by-class svg "brutal-paper-tab-status-icon"))))
          (should (brutal-paper--valid-tab-item-p item))
          (should marker)
          (should (eq (dom-tag icon) (cdr spec)))
          (should (equal (dom-attr marker 'data-status)
                         (symbol-name status)))))
      (should-not
       (brutal-paper--valid-tab-item-p
        '(:id unknown :name "Unknown" :current t :status missing))))))

(ert-deftest brutal-paper-animated-status-keeps-three-fixed-dot-slots ()
  "Cycle one to three dots without changing marker or fallback width."
  (let ((brutal-paper-tab-statuses
         '((busy :icon dots :face warning :label "...")))
        (brutal-paper--tab-status-phase 1)
        (brutal-paper-mode t)
        counts widths text-widths)
    (cl-letf (((symbol-function 'brutal-paper--face-color)
               (lambda (&rest _) "#ffaa00"))
              ((symbol-function 'brutal-paper--readable-ink)
               (lambda (&rest _) "#000000"))
              ((symbol-function 'brutal-paper--refresh-rendered-chrome)
               #'ignore))
      (dotimes (_ 3)
        (let ((svg (svg-create 30 30)))
          (brutal-paper--paint-tab-status svg 'busy 10 10 8 "#111111")
          (push (length (dom-by-class
                         svg "brutal-paper-tab-status-icon")) counts)
          (push (dom-attr svg 'width) widths)
          (push (string-width (brutal-paper--tab-status-label 'busy))
                text-widths))
        (brutal-paper--animate-tab-status)))
    (should (equal (nreverse counts) '(1 2 3)))
    (should (equal (nreverse widths) '(30 30 30)))
    (should (equal (nreverse text-widths) '(3 3 3)))
    (should (= brutal-paper--tab-status-phase 1))))

(ert-deftest brutal-paper-animated-status-avoids-full-frame-redraw ()
  "Refresh animated status dots without redrawing the whole frame."
  (let ((brutal-paper-mode t)
        (brutal-paper--tab-status-phase 1)
        forced redrawn)
    (cl-letf (((symbol-function 'brutal-paper--sync-tab-status-animation)
               #'ignore)
              ((symbol-function 'force-mode-line-update)
               (lambda (&optional all) (setq forced all)))
              ((symbol-function 'frame-list) (lambda () '(frame)))
              ((symbol-function 'frame-live-p) (lambda (_) t))
              ((symbol-function 'brutal-paper--top-level-frame-p)
               (lambda (_) t))
              ((symbol-function 'brutal-paper--sync-tab-bar-lines) #'ignore)
              ((symbol-function 'redraw-frame)
               (lambda (_) (setq redrawn t))))
      (brutal-paper--animate-tab-status))
    (should forced)
    (should-not redrawn)))

(ert-deftest brutal-paper-svg-line-metrics-follow-selected-font ()
  "Read line height, ascender, descender, and size from the selected font."
  (let ((brutal-paper--svg-font-metrics-cache
         (make-hash-table :test #'equal))
        seen)
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
              ((symbol-function 'selected-frame) (lambda () 'frame))
              ((symbol-function 'find-font)
               (lambda (spec frame)
                 (setq seen (list (font-get spec :family)
                                  (font-get spec :weight)
                                  (font-get spec :slant)
                                  frame))
                 'entity))
              ((symbol-function 'open-font)
               (lambda (entity size frame)
                 (should (equal (list entity size frame)
                                '(entity 12 frame)))
                 'font))
              ((symbol-function 'font-xlfd-name)
               (lambda (font &optional _fold-wildcards)
                 (should (eq font 'font))
                 "opened-font"))
              ((symbol-function 'font-info)
               (lambda (name frame)
                 (should (equal (list name frame)
                                '("opened-font" frame)))
                 ["opened-font" "Metric Sans" 12 18 0 nil nil
                  20 13 5 8 8 "/tmp/metric.ttf" (truetype)])))
      (should
       (equal
        (brutal-paper--svg-font-line-metrics
         12 '(:family "Metric Sans" :weight bold :slant italic))
        '(:size 12 :height 18 :ascent 13 :descent 5)))
      (should (equal (symbol-name (car seen)) "Metric Sans"))
      (should (equal (cdr seen) '(bold italic frame))))))

(ert-deftest brutal-paper-parent-tabs-share-one-content-baseline ()
  "Center inactive content and align selected content without changing heights."
  (let ((font '(:family "Metric Sans" :weight normal :slant normal))
        current-center)
    (cl-letf (((symbol-function 'brutal-paper--font-spec)
               (lambda (&rest _) font))
              ((symbol-function 'brutal-paper--svg-text-width)
               (lambda (&rest _) 20))
              ((symbol-function 'brutal-paper--main-tab-row-gap)
               (lambda (&optional _) 0))
              ((symbol-function 'brutal-paper--sub-tabs-visible-p)
               (lambda (&optional _) nil))
              ((symbol-function 'brutal-paper--window-background)
               (lambda (&optional _) "#ffffff"))
              ((symbol-function 'brutal-paper-canvas-color)
               (lambda (&optional _) "#57e561"))
              ((symbol-function 'brutal-paper--tab-color-spec)
               (lambda (&rest _)
                 '(:background "#57e561" :foreground "#111111"
                   :qualifier "#555555" :badge "#00402a"
                   :badge-foreground "#ffffff" :border "#118833")))
              ((symbol-function 'brutal-paper--svg-centered-glyph-text-y)
               (lambda (&rest _)
                 (ert-fail "Tab centering must use the SVG renderer")))
              ((symbol-function 'brutal-paper--svg-centered-visible-text-y)
               (lambda (&rest _)
                 (ert-fail "Tab centering must use the SVG renderer"))))
      (let* ((svg
              (brutal-paper--tab-svg
               '(current-tab (name . "[Theme](local)")) 1))
             (badge (car (dom-by-tag svg 'circle)))
             (texts (dom-by-tag svg 'text))
             (title (nth 1 texts))
             (qualifier (nth 2 texts))
             (center (dom-attr badge 'cy)))
        (setq current-center center)
        (should
         (= center
            (+ (/ (+ brutal-paper-tab-current-top
                     brutal-paper-tab-row-height)
                  2.0)
               (/ (- brutal-paper-tab-inactive-top
                     brutal-paper-tab-current-top)
                  2.0))))
        (dolist (text texts)
          (should (= (dom-attr text 'y) center))
          (should (equal (dom-attr text 'dominant-baseline) "middle")))
        (should (equal (dom-text title) "Theme"))
        (should (equal (dom-text qualifier) "&lt;local&gt;")))
      (let* ((svg
              (brutal-paper--tab-svg
               '(tab (name . "Tests")) 2))
             (badge (car (dom-by-tag svg 'circle))))
        (should
         (= (dom-attr badge 'cy)
            (/ (+ brutal-paper-tab-inactive-top
                  brutal-paper-tab-row-height)
               2.0)))
        (should (= (dom-attr badge 'cy) current-center))))))

(ert-deftest brutal-paper-parent-tab-balances-its-horizontal-ink ()
  "Give the parent tab's measured content a slightly larger trailing inset."
  (should
   (= brutal-paper-tab-right-padding
      (+ brutal-paper-tab-left-padding 6)))
  (cl-letf (((symbol-function 'brutal-paper--font-spec)
             (lambda (&rest _)
               '(:family "Metric Sans" :weight normal :slant normal)))
            ((symbol-function 'brutal-paper--svg-text-width)
             (lambda (text &rest _)
               (if (equal text "1") 8 42)))
            ((symbol-function 'brutal-paper--main-tab-row-gap)
             (lambda (&optional _) 0))
            ((symbol-function 'brutal-paper--sub-tabs-visible-p)
             (lambda (&optional _) nil))
            ((symbol-function 'brutal-paper--window-background)
             (lambda (&optional _) "#ffffff"))
            ((symbol-function 'brutal-paper-canvas-color)
             (lambda (&optional _) "#57e561"))
            ((symbol-function 'brutal-paper--tab-color-spec)
             (lambda (&rest _)
               '(:background "#57e561" :foreground "#111111"
                 :qualifier "#555555" :badge "#00402a"
                 :badge-foreground "#ffffff" :border "#118833"))))
    (let* ((svg
            (brutal-paper--tab-svg
             '(current-tab (name . "Theme")) 1))
           (circle (car (dom-by-tag svg 'circle)))
           (title (nth 1 (dom-by-tag svg 'text)))
           (content-left
            (- (dom-attr circle 'cx) (dom-attr circle 'r)))
           (content-right (+ (dom-attr title 'x) 42))
           (tab-right (- (dom-attr svg 'width) brutal-paper-tab-gap)))
      (should (= content-left brutal-paper-tab-left-padding))
      (should (= (- tab-right content-right)
                 brutal-paper-tab-right-padding)))))

(ert-deftest brutal-paper-parent-tabs-share-the-available-row-width ()
  "Shrink all parent cells together after accounting for the logo cell."
  (let ((items (list '(:id one :name "one")
                     '(:id two :name "two")
                     '(:id three :name "three"))))
    (cl-letf (((symbol-function 'frame-inner-width)
               (lambda (_frame) 260))
              ((symbol-function 'brutal-paper--parent-row-leading-width)
               (lambda (_frame) 60))
              ((symbol-function 'brutal-paper--parent-tab-widths)
               (lambda (&rest _) '(40 120))))
      (let ((widths
             (mapcar (lambda (entry) (plist-get entry :width))
                     (brutal-paper--parent-tab-layout items 'frame))))
        (should (= (apply #'+ widths) 200))
        (should (cl-every (lambda (width) (>= width 40)) widths))
        (should (cl-every (lambda (width) (< width 120)) widths))))
    (cl-letf (((symbol-function 'frame-inner-width)
               (lambda (_frame) 500))
              ((symbol-function 'brutal-paper--parent-row-leading-width)
               (lambda (_frame) 60))
              ((symbol-function 'brutal-paper--parent-tab-widths)
               (lambda (&rest _) '(40 120))))
      (should
       (equal (mapcar (lambda (entry) (plist-get entry :width))
                      (brutal-paper--parent-tab-layout items 'frame))
              '(120 120 120))))))

(ert-deftest brutal-paper-parent-tabs-hide-number-only-overflow ()
  "Hide overflow cells instead of wrapping them into the next tab-bar line."
  (let ((items (list '(:id one :name "one")
                     '(:id two :name "two")
                     '(:id three :name "three")
                     '(:id four :name "four")
                     '(:id five :name "five" :current t))))
    (cl-letf (((symbol-function 'selected-frame) (lambda () 'frame))
              ((symbol-function 'brutal-paper--tab-model-items)
               (lambda (_kind _frame) items))
              ((symbol-function 'frame-inner-width)
               (lambda (_frame) 180))
              ((symbol-function 'brutal-paper--parent-row-leading-width)
               (lambda (_frame) 30))
              ((symbol-function 'brutal-paper--parent-tab-widths)
               (lambda (&rest _) '(50 100)))
              ((symbol-function 'brutal-paper--tab-name-format)
               (lambda (_tab index _width) index))
              ((symbol-function 'brutal-paper--tab-menu-item)
               (lambda (_item index _label _kind) index)))
      (should (equal (brutal-paper--tab-bar-format-tabs) '(3 4 5))))))

(ert-deftest brutal-paper-parent-tab-truncates-then-hides-its-title ()
  "Preserve the number badge when a responsive parent cell becomes narrow."
  (let ((tab '(current-tab (name . "[ALPHABET](branch)"))))
    (cl-letf (((symbol-function 'brutal-paper--font-spec)
               (lambda (&rest _)
                 '(:family "Metric Sans" :weight normal :slant normal)))
              ((symbol-function 'brutal-paper--svg-text-width)
               (lambda (text &rest _) (* 10 (length text))))
              ((symbol-function 'brutal-paper--main-tab-row-gap)
               (lambda (&optional _) 0))
              ((symbol-function 'brutal-paper--window-background)
               (lambda (&optional _) "#ffffff"))
              ((symbol-function 'brutal-paper-canvas-color)
               (lambda (&optional _) "#57e561"))
              ((symbol-function 'brutal-paper--tab-color-spec)
               (lambda (&rest _)
                 '(:background "#57e561" :foreground "#111111"
                   :qualifier "#555555" :badge "#00402a"
                   :badge-foreground "#ffffff" :border "#118833"))))
      (pcase-let* ((`(,minimum ,natural)
                    (brutal-paper--parent-tab-widths tab 1))
                   (truncated
                    (brutal-paper--tab-svg
                     tab 1 (+ minimum brutal-paper-tab-order-gap 20)))
                   (compact (brutal-paper--tab-svg tab 1 minimum))
                   (truncated-texts (dom-by-tag truncated 'text))
                   (compact-texts (dom-by-tag compact 'text)))
        (should (> natural minimum))
        (should (= (dom-attr truncated 'width)
                   (+ minimum brutal-paper-tab-order-gap 20)))
        (should (= (length truncated-texts) 2))
        (should (equal (dom-text (cadr truncated-texts)) "A&#8230;"))
        (should (= (dom-attr compact 'width) minimum))
        (should (= (length compact-texts) 1))
        (should (equal (dom-text (car compact-texts)) "1"))))))

(ert-deftest brutal-paper-sub-tab-description-is-readable-but-subordinate ()
  "Keep descriptions close in size and distinct from faint separators."
  (should
   (= brutal-paper-sub-tab-subtitle-font-size
      (- brutal-paper-sub-tab-font-size 2)))
  (cl-letf (((symbol-function 'brutal-paper-canvas-color)
             (lambda (&optional _) "#57e561"))
            ((symbol-function 'brutal-paper--tab-marker-color)
             (lambda (&rest _) "#118833"))
            ((symbol-function 'brutal-paper--readable-ink)
             (lambda (&rest _) "#111111")))
    (let* ((svg
            (brutal-paper--sub-tab-svg
             '(:id inactive :name "inactive" :subtitle "Readable detail"
               :current nil)
             1 300 nil))
           (description (nth 2 (dom-by-tag svg 'text))))
      (should description)
      (should
       (= (dom-attr description 'font-size)
          brutal-paper-sub-tab-subtitle-font-size))
      (should
       (equal (dom-attr description 'fill)
              (brutal-paper--mix "#57e561" "#111111" 0.72))))))

(ert-deftest brutal-paper-refresh-invalidates-the-consumer-tab-model ()
  "Let a consumer publish changed project data through the public refresh."
  (let* ((calls 0)
         (brutal-paper--tab-model-cache
          (make-hash-table :test #'eq :weakness 'key))
         (brutal-paper-tab-model-function
          (lambda (_frame)
            (cl-incf calls)
            (list :tabs (list (list :id 'only :name "Only" :current t))))))
    (brutal-paper--consumer-tab-model)
    (brutal-paper--consumer-tab-model)
    (should (= calls 1))
    (cl-letf (((symbol-function 'force-mode-line-update) #'ignore)
              ((symbol-function 'redraw-frame) #'ignore)
              ((symbol-function 'brutal-paper--top-level-frame-p)
               (lambda (&rest _) t)))
      (brutal-paper-refresh))
    (brutal-paper--consumer-tab-model)
    (should (= calls 2))))

(ert-deftest brutal-paper-refresh-fixes-sub-tab-line-count ()
  "Make a consumer sub-tab row explicit instead of relying on menu wrapping."
  (let ((brutal-paper-mode t)
        (brutal-paper-enable-tab-bar t)
        (brutal-paper-tab-model-function
         (lambda (_frame)
           (list
            :tabs (list (list :id 'theme :name "theme" :current t))
            :sub-tabs
            (list (list :id 'main :name "main" :current t)
                  (list :id 'review :name "review" :select #'ignore)))))
        (brutal-paper--tab-model-cache (make-hash-table :test #'eq))
        (brutal-paper--saved-frame-chrome (make-hash-table :test #'eq))
        changes
        background)
    (cl-letf (((symbol-function 'frame-live-p) (lambda (_frame) t))
              ((symbol-function 'brutal-paper--top-level-frame-p)
               (lambda (_frame) t))
              ((symbol-function 'facep) (lambda (_face) t))
              ((symbol-function 'brutal-paper--sync-canvas-faces) #'ignore)
              ((symbol-function 'brutal-paper--native-tab-bar-background)
               (lambda (&optional _frame) "#57e561"))
              ((symbol-function 'set-face-attribute)
               (lambda (_face _frame attribute value &rest _)
                 (when (eq attribute :background)
                   (setq background value))))
              ((symbol-function 'frame-parameter)
               (lambda (_frame parameter)
                 (if (eq parameter 'tab-bar-lines) 1 0)))
              ((symbol-function 'set-frame-parameter)
               (lambda (_frame parameter value)
                 (push (cons parameter value) changes)))
              ((symbol-function 'force-mode-line-update) #'ignore)
              ((symbol-function 'redraw-frame) #'ignore))
      (brutal-paper-refresh 'frame))
    (should (equal (alist-get 'tab-bar-lines changes) 2))
    (should (equal background "#57e561"))
    (should
     (= (alist-get 'tab-bar-lines
                   (gethash 'frame brutal-paper--saved-frame-chrome))
        1))))

(ert-deftest brutal-paper-refresh-reapplies-faces-after-canvas-change ()
  "Repaint margins and dividers when the current tab gets another colour."
  (let ((brutal-paper-mode t)
        (brutal-paper--applied-canvas-colors (make-hash-table :test #'eq))
        (canvas "#57e561")
        applied)
    (cl-letf (((symbol-function 'frame-live-p) (lambda (_frame) t))
              ((symbol-function 'brutal-paper--top-level-frame-p)
               (lambda (_frame) t))
              ((symbol-function 'brutal-paper-canvas-color)
               (lambda (&optional _frame) canvas))
              ((symbol-function 'brutal-paper--apply-faces)
               (lambda (frame)
                 (push frame applied)
                 (puthash frame canvas brutal-paper--applied-canvas-colors)))
              ((symbol-function 'brutal-paper--sync-tab-bar-lines) #'ignore)
              ((symbol-function 'brutal-paper--sync-tab-status-animation)
               #'ignore)
              ((symbol-function 'force-mode-line-update) #'ignore)
              ((symbol-function 'redraw-frame) #'ignore))
      (puthash 'frame canvas brutal-paper--applied-canvas-colors)
      (brutal-paper-refresh 'frame)
      (should-not applied)
      (setq canvas "#4dd1fb")
      (brutal-paper-refresh 'frame)
      (should (equal applied '(frame)))
      (brutal-paper-refresh 'frame)
      (should (equal applied '(frame)))
      (let ((brutal-paper-mode nil))
        (setq canvas "#fed413")
        (brutal-paper-refresh 'frame)
        (should (equal applied '(frame)))))))

(ert-deftest brutal-paper-keeps-the-sub-tab-row-after-native-update ()
  "Keep an explicit secondary row through native tab-bar recalculation."
  (require 'tab-bar)
  (let* ((frame (selected-frame))
         (old-lines (frame-parameter frame 'tab-bar-lines))
         (old-keep-state
          (frame-parameter frame 'tab-bar-lines-keep-state))
         (brutal-paper-mode t)
         (brutal-paper-enable-tab-bar t)
         (brutal-paper-tab-model-function
          (lambda (_frame)
            (list
             :tabs (list (list :id 'theme :name "theme" :current t))
             :sub-tabs
             (list (list :id 'main :name "main" :current t)
                   (list :id 'review :name "review" :select #'ignore)))))
         (brutal-paper--tab-model-cache (make-hash-table :test #'eq))
         (brutal-paper--saved-frame-chrome (make-hash-table :test #'eq))
         (tab-bar-mode t)
         (tab-bar-show t)
         (auto-resize-tab-bars nil))
    (unwind-protect
        (progn
          (set-frame-parameter frame 'tab-bar-lines 1)
          (set-frame-parameter frame 'tab-bar-lines-keep-state nil)
          (brutal-paper--sync-tab-bar-lines frame)
          (ert-info ("Brutal Paper installs the second row")
            (should (= (frame-parameter frame 'tab-bar-lines) 2)))
          (tab-bar--update-tab-bar-lines (list frame))
          (ert-info ("Emacs preserves the explicit second row")
            (should (= (frame-parameter frame 'tab-bar-lines) 2))))
      (set-frame-parameter frame 'tab-bar-lines old-lines)
      (set-frame-parameter
       frame 'tab-bar-lines-keep-state old-keep-state))))

(ert-deftest brutal-paper-logo-is-user-customizable ()
  "Use the configured SVG and padding with automatic dimensions."
  (let ((brutal-paper-show-logo t)
        (brutal-paper-logo-file "/tmp/custom-brutal-paper.svg")
        (brutal-paper-logo-horizontal-padding 7)
        (brutal-paper-logo-tab-gap 4)
        created embedded)
    (cl-letf (((symbol-function 'display-images-p) (lambda () t))
              ((symbol-function 'image-type-available-p)
               (lambda (type) (eq type 'svg)))
              ((symbol-function 'file-readable-p) (lambda (_file) t))
              ((symbol-function 'svg-create)
               (lambda (width height &rest _)
                 (setq created (list width height))
                 'logo-svg))
              ((symbol-function 'frame-focus-state) (lambda (_frame) t))
              ((symbol-function 'brutal-paper--logo-intrinsic-aspect-ratio)
               (lambda (_file) 1.5))
              ((symbol-function 'brutal-paper--paint-tab-row)
               (lambda (&rest _)))
              ((symbol-function 'brutal-paper--paint-tab-junction)
               (lambda (&rest _)))
              ((symbol-function 'brutal-paper-hard-shadow)
               (lambda (&optional _frame) "#shadow"))
              ((symbol-function 'svg-embed)
               (lambda (&rest arguments) (setq embedded arguments)))
              ((symbol-function 'svg-image)
               (lambda (svg &rest _) svg)))
      (should (eq (brutal-paper--logo-image 'frame) 'logo-svg)))
    (should (= (car created) 44))
    (should
     (equal embedded
            '(logo-svg "/tmp/custom-brutal-paper.svg" "image/svg+xml" nil
              :x 7 :y 15.0 :width 33 :height 22)))
    (let ((brutal-paper-show-logo nil))
      (should-not (brutal-paper--logo-image)))))

(ert-deftest brutal-paper-hidden-logo-aligns-first-tab-with-paper ()
  "Replace hidden artwork with exactly the paper's left Canvas inset."
  (let ((brutal-paper-show-logo nil)
        (brutal-paper--canvas-image-cache (make-hash-table :test #'equal))
        (brutal-paper--canvas-image-signatures (make-hash-table :test #'eq)))
    (cl-letf (((symbol-function 'display-images-p) (lambda () t))
              ((symbol-function 'brutal-paper--frame-paper-left-offset)
               (lambda (&optional _frame) 8))
              ((symbol-function 'brutal-paper--tab-bar-background)
               (lambda (&optional _frame) "#ffffff"))
              ((symbol-function 'brutal-paper-canvas-color)
               (lambda (&optional _frame) "#57e561"))
              ((symbol-function 'brutal-paper--tab-junction-color)
               (lambda (&optional _frame) "#118833")))
      (let* ((cell (brutal-paper--tab-bar-format-logo))
             (image (get-text-property 0 'display cell)))
        (should (eq (image-property image :type)
                    (brutal-paper-test--structural-image-type)))
        (when (eq (image-property image :type) 'canvas)
          (should (eq (image-property image :scale) 'default)))
        (should (= (brutal-paper-test--image-dimension image 'width) 8))
        (should (= (brutal-paper-test--image-dimension image 'height) 51))))))

(ert-deftest brutal-paper-logo-follows-the-svg-intrinsic-aspect-ratio ()
  "Size custom logo cells from their SVG viewBox by default."
  (let ((artwork
         (make-temp-file
          "brutal-paper-logo-" nil ".svg"
          "<svg viewBox=\"0 0 120 40\"></svg>"))
        (brutal-paper-show-logo t)
        (brutal-paper-logo-horizontal-padding 4)
        created embedded)
    (unwind-protect
        (cl-letf (((symbol-function 'display-images-p) (lambda () t))
                  ((symbol-function 'image-type-available-p)
                   (lambda (type) (eq type 'svg)))
                  ((symbol-function 'frame-focus-state) (lambda (_frame) t))
                  ((symbol-function 'svg-create)
                   (lambda (width height &rest _)
                     (setq created (list width height))
                     'logo-svg))
                  ((symbol-function 'brutal-paper--paint-tab-row)
                   (lambda (&rest _)))
                  ((symbol-function 'brutal-paper--paint-tab-junction)
                   (lambda (&rest _)))
                  ((symbol-function 'brutal-paper-hard-shadow)
                   (lambda (&optional _frame) "#shadow"))
                  ((symbol-function 'svg-embed)
                   (lambda (&rest arguments) (setq embedded arguments)))
                  ((symbol-function 'svg-image) (lambda (svg &rest _) svg)))
          (let ((brutal-paper-logo-file artwork))
            (should (eq (brutal-paper--logo-image 'frame) 'logo-svg))))
      (delete-file artwork))
    (should (= (car created) 74))
    (should (= (plist-get (nthcdr 4 embedded) :width) 66))))

(ert-deftest brutal-paper-logo-height-cannot-exceed-inactive-tab ()
  "Cap automatic logo height at the inactive tab's exact height."
  (let ((brutal-paper-tab-row-height 18)
        (brutal-paper-tab-inactive-top 4))
    (cl-letf (((symbol-function 'brutal-paper--logo-intrinsic-aspect-ratio)
               (lambda (_file) 3.0)))
      (should
       (equal (brutal-paper--logo-artwork-layout "unused.svg")
              '(:cell-width 42 :art-width 42 :art-height 14 :art-x 0))))))

(ert-deftest brutal-paper-default-logo-clears-the-workspace-rule ()
  "Keep the smaller default artwork clear of the workspace-row baseline."
  (let ((brutal-paper-show-logo t)
        (brutal-paper-logo-file nil)
        (brutal-paper-logo-horizontal-padding 10)
        embedded)
    (cl-letf (((symbol-function 'display-images-p) (lambda () t))
              ((symbol-function 'image-type-available-p)
               (lambda (type) (eq type 'svg)))
              ((symbol-function 'file-readable-p) (lambda (_file) t))
              ((symbol-function 'frame-focus-state) (lambda (_frame) t))
              ((symbol-function 'svg-create) (lambda (&rest _) 'logo-svg))
              ((symbol-function 'brutal-paper--paint-tab-row)
               (lambda (&rest _)))
              ((symbol-function 'brutal-paper--paint-tab-junction)
               (lambda (&rest _)))
              ((symbol-function 'brutal-paper-hard-shadow)
               (lambda (&optional _frame) "#shadow"))
              ((symbol-function 'svg-embed)
               (lambda (&rest arguments) (setq embedded arguments)))
              ((symbol-function 'svg-image) (lambda (svg &rest _) svg)))
      (brutal-paper--logo-image 'frame))
    (should
     (equal embedded
            `(logo-svg ,brutal-paper--default-logo-artwork
              "image/svg+xml" nil
              :x 10 :y 15.0 :width 44 :height 22)))
    (should (< (+ (plist-get (nthcdr 4 embedded) :y)
                  (plist-get (nthcdr 4 embedded) :height))
               brutal-paper-tab-row-height))))

(ert-deftest brutal-paper-unfocused-logo-is-grayscale ()
  "Desaturate only the logo artwork when its frame loses focus."
  (let ((brutal-paper-show-logo t)
        (brutal-paper-logo-file nil)
        source)
    (cl-letf (((symbol-function 'display-images-p) (lambda () t))
              ((symbol-function 'image-type-available-p)
               (lambda (type) (eq type 'svg)))
              ((symbol-function 'frame-focus-state) (lambda (_frame) nil))
              ((symbol-function 'brutal-paper--paint-tab-row)
               (lambda (&rest _)))
              ((symbol-function 'brutal-paper--paint-tab-junction)
               (lambda (&rest _)))
              ((symbol-function 'brutal-paper-hard-shadow)
               (lambda (&optional _frame) "#shadow"))
              ((symbol-function 'svg-image)
               (lambda (svg &rest _)
                 (with-temp-buffer
                   (svg-print svg)
                   (buffer-string)))))
      (setq source (brutal-paper--logo-image 'frame)))
    (should (string-search "id=\"brutal-paper-logo-grayscale\"" source))
    (should (string-search "type=\"saturate\" values=\"0\"" source))
    (should
     (string-search
      "filter=\"url(#brutal-paper-logo-grayscale)\"" source))))

(ert-deftest brutal-paper-logo-cell-identity-follows-frame-focus ()
  "Give focused and unfocused logo cells distinct menu identities."
  (let ((focused nil))
    (cl-letf (((symbol-function 'selected-frame) (lambda () 'frame))
              ((symbol-function 'brutal-paper--frame-focused-p)
               (lambda (&optional _frame) focused))
              ((symbol-function 'brutal-paper--logo-image)
               (lambda (&optional _frame) 'logo-image)))
      (let ((unfocused-cell (brutal-paper--tab-bar-format-logo)))
        (setq focused t)
        (let ((focused-cell (brutal-paper--tab-bar-format-logo)))
          (should-not
           (equal (substring-no-properties unfocused-cell)
                  (substring-no-properties focused-cell)))
          (should (eq (get-text-property 0 'display unfocused-cell)
                      'logo-image))
          (should (eq (get-text-property 0 'display focused-cell)
                      'logo-image)))))))

(ert-deftest brutal-paper-focus-refresh-redraws-top-level-frames ()
  "Redisplay workspace rows after a coalesced focus notification."
  (let ((brutal-paper-mode t)
        cleared updated redrawn)
    (cl-letf (((symbol-function 'brutal-paper--clear-image-caches)
               (lambda () (setq cleared t)))
              ((symbol-function 'force-mode-line-update)
               (lambda (all) (setq updated all)))
              ((symbol-function 'frame-list)
               (lambda () '(parent child)))
              ((symbol-function 'brutal-paper--top-level-frame-p)
               (lambda (frame) (eq frame 'parent)))
              ((symbol-function 'frame-live-p) (lambda (_frame) t))
              ((symbol-function 'redraw-frame)
               (lambda (frame) (push frame redrawn))))
      (brutal-paper--refresh-focus-appearance))
    (should cleared)
    (should updated)
    (should (equal redrawn '(parent)))))

(ert-deftest brutal-paper-bundled-logo-uses-circular-page-mark ()
  "Keep the bundled mark borderless with an exact circular page arc."
  (with-temp-buffer
    (insert-file-contents brutal-paper--default-logo-artwork)
    (let ((source (buffer-string)))
      (dolist (color '("#FFA55B" "#FED413" "#57E561"))
        (should (string-search color source)))
      (should (string-search "viewBox=\"0 0 96 48\"" source))
      (should (string-search "id=\"paper-mark\"" source))
      (should
       (string-search
        "<path d=\"M17 44A40 40 0 0 1 57 4V44Z\" fill=\"#57E561\"/>"
        source))
      (should
       (string-search
        "<rect x=\"61\" y=\"4\" width=\"8\" height=\"40\" fill=\"#FFA55B\"/>"
        source))
      (should
       (string-search
        "<rect x=\"73\" y=\"4\" width=\"6\" height=\"40\" fill=\"#FED413\"/>"
        source))
      (should-not (string-search "stroke=" source))
      (should-not (string-search "id=\"hard-shadow\"" source)))))

(ert-deftest brutal-paper-new-tabs-refresh-the-structural-canvas ()
  "Opening a selected tab must run the same refresh as selecting one."
  (let (applied)
    (unwind-protect
        (cl-letf (((symbol-function 'brutal-paper-apply)
                   (lambda (&optional frame) (setq applied frame))))
          (brutal-paper-mode 1)
          (setq applied nil)
          (run-hook-with-args 'tab-bar-tab-post-open-functions 'new-tab)
          (should applied))
      (brutal-paper-mode -1))))

(ert-deftest brutal-paper-tab-selection-refreshes-resolved-canvas ()
  "Resolve an embedding configuration's Canvas after the selected tab changes."
  (let* (resolved-frame
         resolved-canvas
         (brutal-paper-canvas-background nil)
         (brutal-paper-canvas-color-function
          (lambda (frame)
            (setq resolved-frame frame)
            "#123456"))
         (brutal-paper-mode t))
    (cl-letf (((symbol-function 'selected-frame) (lambda () 'frame))
              ((symbol-function 'brutal-paper-apply)
               (lambda (&optional frame)
                 (setq resolved-canvas
                       (brutal-paper-canvas-color frame))))
              ((symbol-function 'force-mode-line-update) #'ignore))
      (brutal-paper--tab-selected))
    (should (eq resolved-frame 'frame))
    (should (equal resolved-canvas "#123456"))))

(ert-deftest brutal-paper-tab-menu-item-updates-its-action-in-place ()
  "Use one stable menu key while deriving the current item action."
  (let* ((current (brutal-paper--tab-menu-item
                   '(:id theme :name "Theme" :current t)
                   1 "Theme" 'tab))
         (inactive (brutal-paper--tab-menu-item
                    '(:id theme :name "Theme" :select forward-char)
                    1 "Theme" 'tab)))
    (should (eq (car current) (car inactive)))
    (should (eq (nth 3 current) #'ignore))
    (should (eq (nth 3 inactive) #'forward-char))))

(ert-deftest brutal-paper-installs-chrome-in-a-bare-buffer ()
  "A newly displayed buffer must not expose either native line format."
  (unwind-protect
      (progn
        (brutal-paper-mode 1)
        (with-temp-buffer
          (tab-line-mode -1)
          (brutal-paper--install-buffer-chrome)
          (should tab-line-mode)
          (should (local-variable-p 'tab-line-format))
          (should (equal tab-line-format brutal-paper-tab-line-format))
          (should (local-variable-p 'mode-line-format))
          (should (equal mode-line-format brutal-paper-mode-line-format))))
    (brutal-paper-mode -1)))

(ert-deftest brutal-paper-inactive-echo-footer-uses-a-separate-structural-row ()
  "Keep Canvas padding from stretching boxed echo text."
  (let ((brutal-paper-window-gap 10))
    (let* ((footer (brutal-paper--inactive-echo-bottom-gap-string
                    "#57e561"))
           (gap-position
            (text-property-not-all
             0 (length footer) 'display nil footer))
           (display (get-text-property gap-position 'display footer)))
      (should (string-prefix-p "\n" footer))
      (should (= (seq-count (lambda (character) (= character ?\n)) footer)
                 1))
      (should (= (plist-get (cdr display) :ascent) 100))
      (should (get-text-property
               gap-position 'brutal-paper-echo-bottom-gap footer))
      (should-not (text-property-not-all
                   0 (length footer) 'line-height nil footer))
      (should (eq (image-property display :type)
                  (brutal-paper-test--structural-image-type)))
      (should (= (brutal-paper-test--image-dimension display 'height) 9)))))

(ert-deftest brutal-paper-inactive-echo-keeps-one-bottom-gap ()
  "Replace an orphaned footer instead of accumulating Canvas gaps."
  (with-temp-buffer
    (brutal-paper--install-inactive-echo-bottom-gap "#111111")
    (kill-all-local-variables)
    (brutal-paper--install-inactive-echo-bottom-gap "#222222")
    (should
     (= 1
        (seq-count
         (lambda (overlay)
           (when-let* ((after-string (overlay-get overlay 'after-string))
                       ((stringp after-string))
                       ((> (length after-string) 0)))
             (get-text-property
              0 'brutal-paper-echo-bottom-gap after-string)))
         (overlays-in (point-min) (point-max)))))))

(ert-deftest brutal-paper-inactive-echo-keeps-canvas-fringe-surface ()
  "Keep inactive echo text inside the same Canvas grid as active input."
  (let ((brutal-paper-window-gap 0))
    (with-temp-buffer
      (cl-letf (((symbol-function 'brutal-paper--echo-area-buffer-p)
                 (lambda (_buffer) t))
                ((symbol-function 'brutal-paper--readable-ink)
                 (lambda (_background) "#ink")))
        (brutal-paper--style-echo-area-buffer
         (current-buffer) "#canvas" t)
        (should brutal-paper--minibuffer-fringe-remap-cookie)
        (should
         (brutal-paper--echo-area-face-remap-live-p
          brutal-paper--minibuffer-fringe-remap-cookie 'fringe))))))

(ert-deftest brutal-paper-active-minibuffer-padding-keeps-native-input-row ()
  "Keep vertical padding separate from the prompt's horizontal inset."
  (let ((brutal-paper-fringe-width 12)
        (brutal-paper-window-gap 16)
        (hscroll-margin 0))
    (cl-letf (((symbol-function 'frame-char-width) (lambda (_frame) 8)))
      (with-temp-buffer
        (insert (propertize "M-x " 'field 'prompt))
        (brutal-paper--install-minibuffer-input-inset "#ffffff")
        (should (equal (buffer-string) "M-x "))
        (let* ((prefix (get-text-property (point-min) 'line-prefix))
               (display (get-text-property 0 'display prefix))
               (face (get-text-property 0 'face prefix)))
          (should-not (string-match-p "\n" prefix))
          (should (eq (car-safe display) 'image))
          (should (eq (image-property display :type)
                      (brutal-paper-test--structural-image-type)))
          (should (= (brutal-paper-test--image-dimension display 'width) 12))
          (should (= (brutal-paper-test--image-dimension display 'height) 1))
          ;; This width-only strut is also displayed on the preceding spacer
          ;; row, so it must not impose the default font's full line height.
          (should (= (plist-get face :height) 1))
          (should-not (get-text-property 0 'line-height prefix))
          (should-not (get-text-property 0 'line-spacing prefix))
          (should (get-text-property 0 'cursor-intangible prefix))
          (should-not (brutal-paper-test--fringe-displays prefix)))
        (should (boundp 'brutal-paper--active-minibuffer-top-padding-overlay))
        (should (overlayp brutal-paper--active-minibuffer-top-padding-overlay))
        (should-not (overlay-get
                     brutal-paper--active-minibuffer-top-padding-overlay
                     'priority))
        (let ((row (overlay-get
                    brutal-paper--active-minibuffer-top-padding-overlay
                    'before-string)))
          (should (string-match-p "\n" row))
          (let* ((newline (string-match "\n" row))
                 (face (get-text-property newline 'face row)))
            (should (= (plist-get face :height) 1))
            (should (eq (get-text-property newline 'line-height row) t)))
          (should (text-property-any
                   0 (length row) 'brutal-paper-echo-top-spacer t row))
          (should-not (text-property-not-all
                       0 (length row) 'line-spacing nil row)))
        (should (get-text-property
                 (point-min) 'brutal-paper-minibuffer-input-inset))
        (should (= hscroll-margin 2))
        (let ((old-overlay
               brutal-paper--active-minibuffer-top-padding-overlay))
          (brutal-paper--install-minibuffer-input-inset "#ffffff")
          (should-not (overlay-start old-overlay)))
        (should (get-text-property (point-min) 'line-prefix))
        (should (equal (buffer-string) "M-x "))
        (let ((top-overlay
               brutal-paper--active-minibuffer-top-padding-overlay))
          (setq-local brutal-paper--active-minibuffer-top-padding-overlay nil)
          (brutal-paper--remove-minibuffer-input-inset)
          (should-not (overlay-start top-overlay)))
        (should-not brutal-paper--active-minibuffer-top-padding-overlay)
        (should (= hscroll-margin 0))
        (should-not (get-text-property (point-min) 'line-prefix))
        (should-not (get-text-property
                     (point-min) 'brutal-paper-minibuffer-input-inset))))))

(ert-deftest brutal-paper-minibuffer-input-inset-restores-user-prefix ()
  "Restore a pre-existing prompt prefix after removing the paper inset."
  (let ((brutal-paper-fringe-width 12))
    (with-temp-buffer
      (insert "M-x ")
      (put-text-property (point-min) (1+ (point-min))
                         'line-prefix "user-prefix")
      (brutal-paper--install-minibuffer-input-inset "#ffffff")
      (should-not (equal (get-text-property (point-min) 'line-prefix)
                         "user-prefix"))
      (brutal-paper--remove-minibuffer-input-inset)
      (should (equal (get-text-property (point-min) 'line-prefix)
                     "user-prefix")))))

(ert-deftest brutal-paper-minibuffer-vertical-padding-follows-visual-font-size ()
  "Use half the font pixelsize independently of horizontal fringe width."
  (let ((brutal-paper-fringe-width 2))
    (cl-letf (((symbol-function 'face-font)
               (lambda (&rest _) "font"))
              ((symbol-function 'font-info)
               (lambda (&rest _)
                 [nil nil 16 24 nil nil nil nil 17 7 nil nil nil nil])))
      (let* ((row (brutal-paper--minibuffer-top-padding-row "#ffffff"))
             (display (get-text-property 0 'display row))
             (newline (string-match "\n" row)))
        (should (= (brutal-paper--minibuffer-vertical-padding-height) 8))
        (should (eq (image-property display :type)
                    (brutal-paper-test--structural-image-type)))
        (should (= (brutal-paper-test--image-dimension display 'height) 8))
        (should (eq (get-text-property newline 'line-height row) t))))))

(ert-deftest brutal-paper-minibuffer-fringes-follow-paper-pixel-edges ()
  "Derive asymmetric minibuffer insets from outer Paper window edges."
  (cl-letf (((symbol-function 'window-list)
             (lambda (&rest _arguments) '(left-window right-window)))
            ((symbol-function 'window-live-p) (lambda (_window) t))
            ((symbol-function 'window-pixel-edges)
             (lambda (window)
               (pcase window
                 ('minibuffer-window '(0 700 824 770))
                 ('left-window '(0 50 412 700))
                 ('right-window '(412 50 824 700)))))
            ((symbol-function 'window-body-pixel-edges)
             (lambda (window)
               (pcase window
                 ('left-window '(22 80 400 680))
                 ('right-window '(424 80 798 680)))))
            ((symbol-function 'window-fringes)
             (lambda (_window) '(12 12 nil nil))))
    (should
     (equal
      (brutal-paper--minibuffer-paper-edge-fringes
       'frame 'minibuffer-window)
      '(10 . 14)))))

(ert-deftest brutal-paper-minibuffer-uses-fixed-canvas-fringes ()
  "Keep active input and inactive echo text inside stable Canvas fringes."
  (let ((brutal-paper-fringe-width 12)
        (brutal-paper-enable-echo-area t)
        (active t)
        applied)
    (cl-letf (((symbol-function 'minibuffer-window)
               (lambda (_frame) 'minibuffer-window))
              ((symbol-function 'window-live-p) (lambda (_window) t))
              ((symbol-function 'minibuffer-window-active-p)
               (lambda (_window) active))
              ((symbol-function 'brutal-paper--minibuffer-paper-edge-fringes)
               (lambda (_frame _window) '(10 . 10)))
              ((symbol-function 'brutal-paper--set-window-edges)
               (lambda (window margins fringe-width)
                 (setq applied (list window margins fringe-width)))))
      (brutal-paper--normalize-minibuffer-edges 'frame)
      (should (equal applied '(minibuffer-window (nil) (10 . 10))))
      (setq active nil)
      (brutal-paper--normalize-minibuffer-edges 'frame)
      (should (equal applied '(minibuffer-window (nil) (10 . 10)))))))

(ert-deftest brutal-paper-minibuffer-right-padding-follows-font-width ()
  "Express the Paper inset as text columns without a native window margin."
  (let ((brutal-paper-fringe-width 12)
        (brutal-paper-minibuffer-right-padding 'auto))
    (cl-letf (((symbol-function 'brutal-paper--default-font-space-width)
               (lambda (&optional _frame) 8)))
      (should (= (brutal-paper--minibuffer-right-padding-columns 'frame) 2)))
    (let ((brutal-paper-minibuffer-right-padding 3))
      (should (= (brutal-paper--minibuffer-right-padding-columns 'frame) 3)))))

(ert-deftest brutal-paper-marginalia-right-padding-does-not-change-window-edges ()
  "Inset right-aligned annotations at the text layer only."
  (let ((brutal-paper-enable-echo-area t)
        (brutal-paper-mode t)
        observed)
    (cl-progv '(marginalia-align marginalia-align-offset) '(right 0)
      (cl-letf (((symbol-function 'active-minibuffer-window)
                 (lambda () 'minibuffer-window))
                ((symbol-function 'window-live-p) (lambda (_window) t))
                ((symbol-function 'window-frame) (lambda (_window) 'frame))
                ((symbol-function
                  'brutal-paper--minibuffer-right-padding-columns)
                 (lambda (&optional _frame) 2)))
        (brutal-paper--marginalia-align-around
         (lambda (_candidates)
           (setq observed (symbol-value 'marginalia-align-offset)))
         nil)))
    (should (= observed -2))))

(ert-deftest brutal-paper-active-minibuffer-uses-one-composite-footer-row ()
  "Stack matching font-relative Paper padding and Canvas in one display row."
  (let ((brutal-paper-fringe-width 2)
        (brutal-paper-window-gap 10))
    (cl-letf (((symbol-function
                'brutal-paper--minibuffer-vertical-padding-height)
               (lambda (&optional _frame) 8)))
      (let* ((spacing
              (brutal-paper--minibuffer-bottom-spacing
               "#ffffff" "#57e561" 320))
             (padding-position
              (text-property-any
               0 (length spacing) 'brutal-paper-echo-bottom-spacer t spacing))
             (gap-position
              (text-property-any
               0 (length spacing) 'brutal-paper-echo-bottom-gap t spacing)))
        (should padding-position)
        (should (string-prefix-p "\n" spacing))
        (should (= (seq-count (lambda (character) (= character ?\n)) spacing)
                   1))
        (should (equal (plist-get (get-text-property 0 'face spacing)
                                  :background)
                       "#ffffff"))
        (should-not (string-suffix-p "\n" spacing))
        (let* ((display (get-text-property padding-position 'display spacing))
               (fallback-face
                (get-text-property padding-position 'face spacing)))
          (should (eq (car-safe display) 'image))
          (should (eq (image-property display :type)
                      (brutal-paper-test--structural-image-type)))
          (should (= (brutal-paper-test--image-dimension display 'width) 320))
          (should (= (brutal-paper-test--image-dimension display 'height) 18))
          (should (= (brutal-paper-test--structural-pixel display 0 7)
                     #xffffffff))
          (should (= (brutal-paper-test--structural-pixel display 0 8)
                     #xff57e561))
          (should (equal (plist-get fallback-face :background) "#ffffff")))
        (should gap-position)
        (should (= padding-position gap-position))
        (should-not (brutal-paper-test--fringe-displays spacing))
        (should
         (get-text-property gap-position 'cursor-intangible spacing))))))

(ert-deftest brutal-paper-active-minibuffer-defers-footer-until-redisplay ()
  "Do not place an unrealized structural image on the prompt's first frame."
  (let ((brutal-paper-fringe-width 12)
        (brutal-paper-window-gap 10))
    (let ((spacing
           (brutal-paper--minibuffer-bottom-spacing
            "#ffffff" "#57e561" 320 t)))
      (should (equal spacing "\n"))
      (should-not (text-property-any
                   0 (length spacing)
                   'brutal-paper-echo-bottom-spacer t spacing))
      (should-not (text-property-any
                   0 (length spacing)
                   'brutal-paper-echo-bottom-gap t spacing))
      (should (string-suffix-p "\n" spacing)))))

(ert-deftest brutal-paper-completion-overlay-realizes-a-body-only-footer ()
  "Defer a completion footer, then realize it without fringe geometry."
  (let ((brutal-paper-fringe-width 12)
        (brutal-paper-window-gap 10))
    (with-temp-buffer
      (let ((candidates (make-overlay (point-min) (point-min))))
        (overlay-put candidates 'before-string "\ncandidate")
        (cl-progv '(vertico--candidates-ov) (list candidates)
          (brutal-paper--install-active-minibuffer-bottom-padding
           "#ffffff" "#57e561" 320 t)
          (let ((spacing (overlay-get candidates 'after-string)))
            (should (equal spacing ""))
            (should-not (text-property-any
                         0 (length spacing)
                         'brutal-paper-echo-bottom-gap t spacing)))
          (brutal-paper--install-active-minibuffer-bottom-padding
           "#ffffff" "#57e561" 320)
          (let* ((spacing (overlay-get candidates 'after-string))
                 (gap-position
                  (text-property-any
                   0 (length spacing)
                   'brutal-paper-echo-bottom-gap t spacing))
                 (display (get-text-property gap-position 'display spacing)))
            (should gap-position)
            (should (= (seq-count
                        (lambda (character) (= character ?\n)) spacing)
                       0))
            (should (eq (car-safe display) 'image))
            (should (eq (image-property display :type)
                        (brutal-paper-test--structural-image-type)))
            (should (= (brutal-paper-test--image-dimension display 'width) 320))
            (should (= (brutal-paper-test--structural-pixel display 0 0)
                       #xffffffff))
            (should (= (brutal-paper-test--structural-pixel
                        display 0
                        (1- (brutal-paper-test--image-dimension
                             display 'height)))
                       #xff57e561))
            (should-not (brutal-paper-test--fringe-displays spacing))))))))

(ert-deftest brutal-paper-empty-completion-keeps-footer-below-input-row ()
  "Keep a zero-candidate completion footer out of the prompt row."
  (let ((brutal-paper-fringe-width 12)
        (brutal-paper-window-gap 10))
    (with-temp-buffer
      (insert "Find file: ~/.config/no-match")
      (let ((candidates (make-overlay (point-max) (point-max))))
        ;; Vertico keeps its candidates overlay when the result set is empty,
        ;; but its display then contains only the synthetic cursor cell and no
        ;; candidate row beginning with a newline.
        (overlay-put candidates 'before-string
                     (propertize " " 'cursor t))
        (cl-progv '(vertico--candidates-ov) (list candidates)
          (brutal-paper--install-active-minibuffer-bottom-padding
           "#ffffff" "#57e561" 320)
          (let ((spacing (overlay-get candidates 'after-string)))
            (should (string-prefix-p "\n" spacing))
            (should (= (seq-count (lambda (character) (= character ?\n))
                                  spacing)
                       1))))))))

(ert-deftest brutal-paper-native-minibuffer-keeps-one-bottom-spacing-overlay ()
  "Reuse one native after-string owner when Vertico is absent."
  (let ((cursor-type '(bar . 2)))
    (with-temp-buffer
      (insert "M-x ")
      (brutal-paper--install-active-minibuffer-bottom-padding
       "#ffffff" "#57e561" 320 t)
      (let ((overlay brutal-paper--active-minibuffer-bottom-padding-overlay))
        (should (overlayp overlay))
        (should-not cursor-type)
        (should brutal-paper--native-minibuffer-canvas-remap-cookie)
        (should brutal-paper--minibuffer-fringe-remap-cookie)
        (should (overlayp brutal-paper--native-minibuffer-paper-overlay))
        (should (equal
                 (plist-get
                  (overlay-get brutal-paper--native-minibuffer-paper-overlay
                               'face)
                  :background)
                 "#ffffff"))
        (let ((spacing (overlay-get overlay 'after-string)))
          (should (stringp spacing))
          (should (eq (get-text-property 0 'face spacing) 'cursor))
          (should-not (brutal-paper-test--fringe-displays spacing))
          (should (string-suffix-p "\n" spacing))
          (should (= (seq-count (lambda (character) (= character ?\n))
                                spacing)
                     1))
          (should-not (text-property-any
                       0 (length spacing)
                       'brutal-paper-echo-bottom-gap t spacing)))
        (brutal-paper--install-active-minibuffer-bottom-padding
         "#ffffff" "#57e561" 320)
        (should (eq overlay
                    brutal-paper--active-minibuffer-bottom-padding-overlay))
        (let* ((spacing (overlay-get overlay 'after-string))
               (footer-position
                (text-property-any
                 0 (length spacing)
                 'brutal-paper-echo-bottom-gap t spacing))
               (display
                (get-text-property footer-position 'display spacing)))
          (should footer-position)
          (should (= (seq-count (lambda (character) (= character ?\n))
                                spacing)
                     1))
          (should (eq (car-safe display) 'image)))
        (brutal-paper--remove-active-minibuffer-bottom-padding)
        (should-not brutal-paper--minibuffer-fringe-remap-cookie)
        (should-not brutal-paper--native-minibuffer-canvas-remap-cookie)
        (should-not brutal-paper--native-minibuffer-paper-overlay)
        (should (equal cursor-type '(bar . 2)))))))

(ert-deftest brutal-paper-active-minibuffer-height-keeps-prompt-visible ()
  "Keep the native cursor cell on the prompt line instead of adding a row."
  (let ((brutal-paper-fringe-width 12)
        (brutal-paper-window-gap 10))
    (with-temp-buffer
      (setq-local brutal-paper--active-minibuffer-bottom-padding-overlay
                  (make-overlay (point-min) (point-min)))
      (cl-letf (((symbol-function 'default-line-height) (lambda () 14))
                ((symbol-function
                  'brutal-paper--minibuffer-vertical-padding-height)
                 (lambda (&optional _frame) 7)))
        (should (= (brutal-paper--active-minibuffer-target-pixel-height)
                   38))))))

(ert-deftest brutal-paper-vertico-minibuffer-height-follows-visible-rows ()
  "Do not reserve a hidden native footer row for Vertico-style spacing."
  (let ((brutal-paper-fringe-width 12)
        (brutal-paper-window-gap 10))
    (with-temp-buffer
      (cl-letf (((symbol-function 'default-line-height) (lambda () 24))
                ((symbol-function
                  'brutal-paper--minibuffer-vertical-padding-height)
                 (lambda (&optional _frame) 7)))
        (should (= (brutal-paper--active-minibuffer-target-pixel-height)
                   48))))))

(ert-deftest brutal-paper-window-resize-refreshes-active-minibuffer-footer ()
  "Rebuild the full-width Canvas footer after minibuffer geometry changes."
  (let ((brutal-paper-mode t)
        (buffer (generate-new-buffer " *brutal-paper-resized-minibuffer*"))
        refreshed)
    (unwind-protect
        (cl-letf (((symbol-function 'window-list) (lambda (&rest _) nil))
                  ((symbol-function 'brutal-paper--apply-frame) #'ignore)
                  ((symbol-function 'minibuffer-window)
                   (lambda (_frame) 'minibuffer-window))
                  ((symbol-function 'window-live-p) (lambda (_window) t))
                  ((symbol-function 'minibuffer-window-active-p)
                   (lambda (_window) t))
                  ((symbol-function 'window-buffer)
                   (lambda (_window) buffer))
                  ((symbol-function
                    'brutal-paper--install-current-minibuffer-bottom-padding)
                   (lambda (&optional realize-footer)
                     (setq refreshed
                           (list (current-buffer) realize-footer)))))
          (brutal-paper--window-configuration-changed 'frame)
          (should (equal refreshed (list buffer t))))
      (kill-buffer buffer))))

(ert-deftest brutal-paper-inactive-echo-height-includes-canvas-gap ()
  "Reserve the exact bottom gap without adding a complete text row."
  (let ((brutal-paper-window-gap 10))
    (with-temp-buffer
      (cl-letf (((symbol-function 'window-live-p) (lambda (_window) t))
                ((symbol-function 'window-frame) (lambda (_window) 'frame))
                ((symbol-function 'frame-char-width) (lambda (_frame) 10))
                ((symbol-function 'window-buffer)
                 (lambda (_window) (current-buffer)))
                ((symbol-function 'minibuffer-window-active-p)
                 (lambda (_window) nil))
                ((symbol-function 'current-message) (lambda () "Done"))
                ((symbol-function 'default-line-height) (lambda () 24))
                ((symbol-function 'window-body-width)
                 (lambda (_window &optional _pixelwise) 320))
                ((symbol-function 'string-pixel-width)
                 (lambda (_string) 40)))
        (should
         (= (brutal-paper--echo-area-target-pixel-height 'echo-window)
            34))))))

(ert-deftest brutal-paper-echo-resize-refreshes-native-footer ()
  "Refresh the native footer after the echo area changes height."
  (let ((pixel-height 24)
        resized redisplayed)
    (cl-letf (((symbol-function 'window-live-p) (lambda (_window) t))
              ((symbol-function 'window-frame) (lambda (_window) 'frame))
              ((symbol-function 'display-graphic-p) (lambda (_frame) t))
              ((symbol-function 'brutal-paper--echo-area-target-pixel-height)
               (lambda (_window) 34))
              ((symbol-function 'window-body-height)
               (lambda (_window &optional _pixelwise) 24))
              ((symbol-function 'window-pixel-height)
               (lambda (_window) pixel-height))
              ((symbol-function 'window-resize)
               (lambda (window delta &rest _)
                 (setq resized (list window delta)
                       pixel-height (+ pixel-height delta))))
              ((symbol-function 'force-mode-line-update)
               (lambda (&optional all) (setq redisplayed all))))
      (brutal-paper--reconcile-echo-area-window-height 'echo-window)
      (should (equal resized '(echo-window 10)))
      (should redisplayed))))

(ert-deftest brutal-paper-echo-clear-hook-does-not-style-synchronously ()
  "Do not mutate read-only echo text inside `echo-area-clear-hook'."
  (let ((brutal-paper-mode t)
        (brutal-paper-enable-echo-area t)
        (brutal-paper--applying nil)
        (brutal-paper--echo-area-refresh-timer nil)
        (brutal-paper--pending-echo-area-frames nil)
        (brutal-paper--refreshing-echo-area nil)
        scheduled styled)
    (cl-letf (((symbol-function 'selected-frame) (lambda () 'frame))
              ((symbol-function 'run-at-time)
               (lambda (&rest arguments)
                 (setq scheduled arguments)
                 'timer))
              ((symbol-function 'brutal-paper--style-echo-area)
               (lambda (&optional _frame)
                 (setq styled t)
                 (signal 'text-read-only nil))))
      (brutal-paper--schedule-echo-area-refresh)
      (should scheduled)
      (should-not styled))))

(ert-deftest brutal-paper-pre-redisplay-does-not-style-synchronously ()
  "Do not install mutating echo work in `pre-redisplay-functions'."
  (should-not
   (memq #'brutal-paper--style-echo-area-before-redisplay
         pre-redisplay-functions)))

(ert-deftest brutal-paper-deferred-echo-refresh-coalesces-and-runs ()
  "Refresh each pending frame once after the unsafe transaction ends."
  (let ((brutal-paper-mode t)
        (brutal-paper-enable-echo-area t)
        (brutal-paper--echo-area-refresh-timer nil)
        (brutal-paper--pending-echo-area-frames nil)
        (brutal-paper--refreshing-echo-area nil)
        (scheduled 0) callback styled)
    (cl-letf (((symbol-function 'run-at-time)
               (lambda (_delay _repeat function &rest _arguments)
                 (cl-incf scheduled)
                 (setq callback function)
                 'echo-timer))
              ((symbol-function 'timerp)
               (lambda (object) (eq object 'echo-timer)))
              ((symbol-function 'frame-live-p) (lambda (_frame) t))
              ((symbol-function 'minibuffer-window)
               (lambda (_frame) 'echo-window))
              ((symbol-function 'window-live-p) (lambda (_window) t))
              ((symbol-function 'minibuffer-window-active-p)
               (lambda (_window) nil))
              ((symbol-function 'brutal-paper--style-echo-area)
               (lambda (&optional frame) (push frame styled))))
      (brutal-paper--schedule-echo-area-refresh 'frame)
      (brutal-paper--schedule-echo-area-refresh 'frame)
      (should (= scheduled 1))
      (funcall callback)
      (should (equal styled '(frame)))
      (should-not brutal-paper--echo-area-refresh-timer)
      (should-not brutal-paper--pending-echo-area-frames)
      (should-not brutal-paper--refreshing-echo-area))))

(ert-deftest brutal-paper-deferred-echo-refresh-skips-live-isearch ()
  "Leave isearch's read-only echo message untouched when its timer fires."
  (require 'isearch)
  (let ((buffer (generate-new-buffer " *brutal-paper-isearch-timer*"))
        (brutal-paper-mode t)
        (brutal-paper-enable-echo-area t)
        (brutal-paper--echo-area-refresh-timer nil)
        (brutal-paper--pending-echo-area-frames nil)
        (brutal-paper--refreshing-echo-area nil)
        callback styled)
    (unwind-protect
        (let ((isearch--current-buffer buffer))
          (with-current-buffer buffer
            (setq-local isearch-mode t))
          (cl-letf (((symbol-function 'run-at-time)
                     (lambda (_delay _repeat function &rest _arguments)
                       (setq callback function)
                       'echo-timer))
                    ((symbol-function 'timerp)
                     (lambda (object) (eq object 'echo-timer)))
                    ((symbol-function 'frame-live-p) (lambda (_frame) t))
                    ((symbol-function 'minibuffer-window)
                     (lambda (_frame) 'echo-window))
                    ((symbol-function 'window-live-p) (lambda (_window) t))
                    ((symbol-function 'minibuffer-window-active-p)
                     (lambda (_window) nil))
                    ((symbol-function 'brutal-paper--style-echo-area)
                     (lambda (&optional _frame)
                       (setq styled t)
                       (signal 'text-read-only nil))))
            (brutal-paper--schedule-echo-area-refresh 'frame)
            (funcall callback)
            (should-not styled)))
      (kill-buffer buffer))))

(ert-deftest brutal-paper-active-echo-refresh-does-not-reenter-redisplay ()
  "Let the command loop redisplay a realized active minibuffer footer."
  (let ((brutal-paper-mode t)
        (brutal-paper-enable-echo-area t)
        (brutal-paper--echo-area-refresh-timer 'timer)
        (brutal-paper--pending-echo-area-frames '(frame))
        (brutal-paper--refreshing-echo-area nil)
        (buffer (generate-new-buffer " *brutal-paper-active-echo*"))
        installed reconciled redisplayed)
    (unwind-protect
        (cl-letf (((symbol-function 'frame-live-p) (lambda (_frame) t))
                  ((symbol-function 'minibuffer-window)
                   (lambda (_frame) 'echo-window))
                  ((symbol-function 'window-live-p) (lambda (_window) t))
                  ((symbol-function 'minibuffer-window-active-p)
                   (lambda (_window) t))
                  ((symbol-function 'window-buffer)
                   (lambda (_window) buffer))
                  ((symbol-function
                    'brutal-paper--install-current-minibuffer-bottom-padding)
                   (lambda (&optional realize-footer)
                     (setq installed realize-footer)))
                  ((symbol-function
                    'brutal-paper--reconcile-active-minibuffer-window-height)
                   (lambda (window) (setq reconciled window)))
                  ((symbol-function 'redisplay)
                   (lambda (&rest _) (setq redisplayed t))))
          (brutal-paper--run-echo-area-refresh)
          (should installed)
          (should (eq reconciled 'echo-window))
          (should-not redisplayed))
      (kill-buffer buffer))))

(ert-deftest brutal-paper-noop-echo-resize-keeps-current-footer ()
  "Do not refresh the footer when native minibuffer height cannot change."
  (let (redisplayed)
    (cl-letf (((symbol-function 'window-live-p) (lambda (_window) t))
              ((symbol-function 'window-frame) (lambda (_window) 'frame))
              ((symbol-function 'display-graphic-p) (lambda (_frame) t))
              ((symbol-function 'brutal-paper--echo-area-target-pixel-height)
               (lambda (_window) 24))
              ((symbol-function 'window-body-height)
               (lambda (_window &optional _pixelwise) 14))
              ((symbol-function 'window-pixel-height)
               (lambda (_window) 14))
              ((symbol-function 'window-resize) (lambda (&rest _)))
              ((symbol-function 'force-mode-line-update)
               (lambda (&optional _all) (setq redisplayed t))))
      (brutal-paper--reconcile-echo-area-window-height 'echo-window)
      (should-not redisplayed))))

;;; Public interface for other packages

(ert-deftest brutal-paper-window-style-matches-the-title-row ()
  "The public window style reports the colours and geometry titles use."
  (let ((brutal-paper-window-title-active-background "#e0e0e0")
        (brutal-paper-window-title-inactive-background "#f0f0f0")
        (brutal-paper-window-muted-ink-mix 0.5)
        (brutal-paper-window-title-height 45)
        (brutal-paper-window-title-top 12)
        (brutal-paper-window-title-block-height 27)
        active)
    (cl-letf (((symbol-function 'mode-line-window-selected-p) (lambda () active))
              ((symbol-function 'brutal-paper--foreground-color)
               (lambda (&optional _frame) "#000000"))
              ((symbol-function 'brutal-paper--window-background)
               (lambda (&optional _frame) "#ffffff"))
              ((symbol-function 'brutal-paper-canvas-color)
               (lambda (&optional _frame) "#cccccc")))
      (setq active t)
      (let ((style (brutal-paper-window-style)))
        (should (eq (plist-get style :active) t))
        (should (equal (plist-get style :paper) "#ffffff"))
        (should (equal (plist-get style :canvas) "#cccccc"))
        (should (equal (plist-get style :title-background)
                       (brutal-paper--resolve-color "#e0e0e0")))
        (should (equal (plist-get style :title-ink) "#000000"))
        (should (= (plist-get style :title-block-height) 27))
        (should (= (plist-get style :title-bottom-inset) 6))
        (should (equal (cons (plist-get style :title-background)
                             (plist-get style :title-ink))
                       (brutal-paper--window-title-colors t))))
      (setq active nil)
      (let ((style (brutal-paper-window-style)))
        (should-not (plist-get style :active))
        (should (equal (plist-get style :title-background)
                       (brutal-paper--resolve-color "#f0f0f0")))
        (should (equal (plist-get style :title-ink)
                       (brutal-paper--mix "#000000" "#ffffff" 0.5)))))))

(ert-deftest brutal-paper-window-style-reads-the-given-window ()
  "A window other than the selected one is measured as that window."
  (let (seen)
    (cl-letf (((symbol-function 'mode-line-window-selected-p)
               (lambda () (setq seen (selected-window)) nil)))
      (save-window-excursion
        (delete-other-windows)
        (let ((other (split-window)))
          (brutal-paper-window-style other)
          (should (eq seen other))
          (should-not (eq (selected-window) other)))))))

(ert-deftest brutal-paper-window-footer-image-is-the-default-footer ()
  "The public footer image is the one the default footer format shows."
  (cl-letf (((symbol-function 'brutal-paper--window-footer-image)
             (lambda () (list 'image :window (selected-window)))))
    (should (equal (brutal-paper-window-footer-image)
                   (list 'image :window (selected-window))))
    (save-window-excursion
      (delete-other-windows)
      (let ((other (split-window)))
        (should (equal (brutal-paper-window-footer-image other)
                       (list 'image :window other)))))))

(provide 'brutal-paper-test)
;;; brutal-paper-test.el ends here
