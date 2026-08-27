;;; e2e-init.el --- Visual Brutal Paper acceptance fixture -*- lexical-binding: t; -*-

(require 'seq)

(defvar brutal-paper-e2e-index 0
  "Zero-based screen slot assigned to this E2E frame.")

(defvar brutal-paper-e2e-count 1
  "Number of Emacs frames participating in this E2E run.")

(defvar brutal-paper-e2e-label emacs-version
  "Short Emacs version shown by this E2E frame.")

(defvar brutal-paper-e2e-seed 0
  "Reproducible random seed supplied by the E2E launcher.")

(defvar brutal-paper-e2e-ready-file nil
  "File written after the E2E fixture has completed startup.")

(defvar brutal-paper-e2e-presentation-interval 10.0
  "Seconds between E2E colour-theme and font changes.")

(defconst brutal-paper-e2e-theme-pool
  '(modus-operandi
    modus-vivendi
    modus-operandi-tinted
    modus-vivendi-tinted
    leuven
    leuven-dark
    tango
    tango-dark
    tsdh-light
    tsdh-dark
    adwaita
    wombat)
  "Built-in colour themes sampled by the visual acceptance fixture.")

(defconst brutal-paper-e2e-font-pool
  '("Altium Stroke CJK"
    "Nokia Cellphone FC CJK"
    "SF Mono"
    "Menlo"
    "Monaco"
    "Berkeley Mono"
    "JetBrains Mono"
    "Iosevka"
    "Fira Code"
    "Source Code Pro"
    "IBM Plex Mono"
    "DejaVu Sans Mono")
  "Monospaced font families sampled by the visual acceptance fixture.")

(defconst brutal-paper-e2e-title-colour-pool
  '((:name "neutral"
     :active (:light "#e0e0e0" :dark "#303030")
     :inactive (:light "#f0f0f0" :dark "#242424"))
    (:name "cool"
     :active (:light "#d7e5f0" :dark "#34495e")
     :inactive (:light "#edf3f7" :dark "#263746"))
    (:name "warm"
     :active (:light "#eadccc" :dark "#574334")
     :inactive (:light "#f6eee6" :dark "#3b3028"))
    (:name "named"
     :active (:light "gray85" :dark "gray25")
     :inactive (:light "gray95" :dark "gray15")))
  "Active/inactive title pairs sampled by the visual acceptance fixture.")

(defvar brutal-paper-e2e--active-colour-theme nil
  "Colour theme currently selected by the E2E fixture.")

(defvar brutal-paper-e2e--active-font nil
  "Font family currently selected by the E2E fixture.")

(defvar brutal-paper-e2e--active-title-colours nil
  "Title-colour style currently selected by the E2E fixture.")

(defvar brutal-paper-e2e--random-state nil
  "Integer state for reproducible E2E presentation changes.")

(defvar brutal-paper-e2e--presentation-timer nil
  "Timer that rotates the E2E theme, font, and title colours.")

(defconst brutal-paper-e2e--project-directory
  (expand-file-name ".." (file-name-directory load-file-name))
  "Brutal Paper checkout exercised by this fixture.")

(defun brutal-paper-e2e--random-index (limit)
  "Return a reproducible pseudo-random integer below LIMIT."
  (unless brutal-paper-e2e--random-state
    (setq brutal-paper-e2e--random-state
          (logand #x7fffffff
                  (+ brutal-paper-e2e-seed
                     (* (1+ brutal-paper-e2e-index) 2654435761)))))
  (setq brutal-paper-e2e--random-state
        (logand #x7fffffff
                (+ (* brutal-paper-e2e--random-state 1103515245)
                   12345)))
  (% brutal-paper-e2e--random-state limit))

(defun brutal-paper-e2e--available-themes ()
  "Return available themes from `brutal-paper-e2e-theme-pool'."
  (let ((available (custom-available-themes)))
    (seq-filter (lambda (theme) (memq theme available))
                brutal-paper-e2e-theme-pool)))

(defun brutal-paper-e2e--next-theme ()
  "Return a random available colour theme other than the current one."
  (let* ((available (brutal-paper-e2e--available-themes))
         (candidates
          (delq brutal-paper-e2e--active-colour-theme
                (copy-sequence available))))
    (cond
     (candidates
      (nth (brutal-paper-e2e--random-index (length candidates))
           candidates))
     (brutal-paper-e2e--active-colour-theme)
     (available (car available))
     (t (user-error "No E2E colour themes are available")))))

(defun brutal-paper-e2e--available-fonts (&optional frame)
  "Return installed fonts from `brutal-paper-e2e-font-pool' on FRAME."
  (let ((available (font-family-list frame)))
    (seq-filter (lambda (family) (member family available))
                brutal-paper-e2e-font-pool)))

(defun brutal-paper-e2e--next-font (&optional frame)
  "Return a random available font other than the current one on FRAME."
  (let* ((available (brutal-paper-e2e--available-fonts frame))
         (candidates
          (delete brutal-paper-e2e--active-font
                  (copy-sequence available))))
    (cond
     (candidates
      (nth (brutal-paper-e2e--random-index (length candidates))
           candidates))
     (brutal-paper-e2e--active-font)
     (available (car available))
     (t (user-error "No E2E fonts are available")))))

(defun brutal-paper-e2e--next-title-colours ()
  "Return a random title-colour style other than the current one."
  (let ((candidates
         (delete brutal-paper-e2e--active-title-colours
                 (copy-sequence brutal-paper-e2e-title-colour-pool))))
    (or (and candidates
             (nth (brutal-paper-e2e--random-index (length candidates))
                  candidates))
        brutal-paper-e2e--active-title-colours
        (car brutal-paper-e2e-title-colour-pool)
        (user-error "No E2E title colours are available"))))

(defun brutal-paper-e2e--frame-title ()
  "Return the E2E frame title, including its active presentation values."
  (format "Brutal Paper E2E — Emacs %s — %s — %s — %s"
          brutal-paper-e2e-label
          (or brutal-paper-e2e--active-colour-theme "no theme")
          (or brutal-paper-e2e--active-font "no font")
          (or (plist-get brutal-paper-e2e--active-title-colours :name)
              "no title colours")))

(defun brutal-paper-e2e--tile-frame ()
  "Place the current frame in its slot of the monitor work area."
  (when-let* ((workarea (cdr (assq 'workarea
                                   (frame-monitor-attributes))))
              ((= (length workarea) 4)))
    (let* ((screen-x (nth 0 workarea))
           (screen-y (nth 1 workarea))
           (screen-width (nth 2 workarea))
           (screen-height (nth 3 workarea))
           (slot-count (max 1 brutal-paper-e2e-count))
           (column-count (min 3 slot-count))
           (row-count (ceiling (/ (float slot-count) column-count)))
           (column (% brutal-paper-e2e-index column-count))
           (row (/ brutal-paper-e2e-index column-count))
           (slot-width (/ screen-width column-count))
           (slot-height (/ screen-height row-count))
           (x (+ screen-x (* column slot-width)))
           (y (+ screen-y (* row slot-height))))
      (set-frame-position nil (+ x 4) (+ y 4))
      (set-frame-size nil
                      (max 420 (- slot-width 8))
                      (max 320 (- slot-height 12))
                      t))))

(defun brutal-paper-e2e--info-buffer ()
  "Return a read-only buffer identifying the current E2E process."
  (let ((buffer (get-buffer-create
                 (format "*Brutal Paper E2E %s*"
                         brutal-paper-e2e-label))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize "BRUTAL PAPER\n" 'face '(:height 1.5 :weight bold)))
        (insert (format "Emacs %s\n\n" emacs-version))
        (insert (format "Colour theme  %s\n\n"
                        brutal-paper-e2e--active-colour-theme))
        (insert (format "Font          %s\n\n"
                        brutal-paper-e2e--active-font))
        (insert (format "Title colours %s\n\n"
                        (plist-get brutal-paper-e2e--active-title-colours
                                   :name)))
        (insert "Visual checks\n")
        (insert "  • workspace logo, tabs, and status badges\n")
        (insert "  • per-window identity rows\n")
        (insert "  • paper fringes and Canvas gap\n")
        (insert "  • active-window hard shadow\n")
        (insert "  • padded echo area\n"))
      (special-mode))
    buffer))

(defun brutal-paper-e2e--refresh-labels ()
  "Refresh E2E labels after a presentation change."
  (setq frame-title-format (brutal-paper-e2e--frame-title))
  (brutal-paper-e2e--info-buffer)
  (force-mode-line-update t))

(defun brutal-paper-e2e--apply-font (family frame)
  "Apply font FAMILY at 16 pt to FRAME."
  (unless (equal family brutal-paper-e2e--active-font)
    (set-frame-font (font-spec :family family :size 16)
                    t (list frame) t)
    (setq brutal-paper-e2e--active-font family)
    (brutal-paper-apply frame)
    (brutal-paper-e2e--refresh-labels)
    (message "Brutal Paper E2E font · %s · seed %d"
             family brutal-paper-e2e-seed)))

(defun brutal-paper-e2e--apply-colour-theme (theme)
  "Replace the current E2E colour theme with THEME."
  (unless (eq theme brutal-paper-e2e--active-colour-theme)
    (let ((previous brutal-paper-e2e--active-colour-theme))
      (condition-case error-data
          (progn
            (when (and previous (memq previous custom-enabled-themes))
              (disable-theme previous))
            (load-theme theme t)
            (setq brutal-paper-e2e--active-colour-theme theme)
            (brutal-paper-e2e--refresh-labels)
            (message "Brutal Paper E2E theme · %s · seed %d"
                     theme brutal-paper-e2e-seed))
        (error
         (when (and previous (not (memq previous custom-enabled-themes)))
           (load-theme previous t))
         (message "Brutal Paper E2E could not load %s: %s"
                  theme (error-message-string error-data)))))))

(defun brutal-paper-e2e--apply-title-colours (style frame)
  "Apply active/inactive title-colour STYLE to FRAME."
  (unless (equal style brutal-paper-e2e--active-title-colours)
    (setq brutal-paper-window-title-active-background
          (plist-get style :active)
          brutal-paper-window-title-inactive-background
          (plist-get style :inactive)
          brutal-paper-e2e--active-title-colours style)
    (brutal-paper-apply frame)
    (brutal-paper-e2e--refresh-labels)
    (message "Brutal Paper E2E title colours · %s · seed %d"
             (plist-get style :name) brutal-paper-e2e-seed)))

(defun brutal-paper-e2e--cycle-presentation (frame)
  "Choose and apply another E2E theme, font, and title style on FRAME."
  (when (frame-live-p frame)
    (with-selected-frame frame
      (brutal-paper-e2e--apply-font
       (brutal-paper-e2e--next-font frame) frame)
      (brutal-paper-e2e--apply-colour-theme
       (brutal-paper-e2e--next-theme))
      (brutal-paper-e2e--apply-title-colours
       (brutal-paper-e2e--next-title-colours) frame))))

(defun brutal-paper-e2e--start-presentation-timer (frame)
  "Start randomized theme, font, and title-colour rotation for FRAME."
  (when (timerp brutal-paper-e2e--presentation-timer)
    (cancel-timer brutal-paper-e2e--presentation-timer))
  (setq brutal-paper-e2e--presentation-timer
        (run-with-timer brutal-paper-e2e-presentation-interval
                        brutal-paper-e2e-presentation-interval
                        #'brutal-paper-e2e--cycle-presentation
                        frame)))

(defun brutal-paper-e2e--tab-model (frame)
  "Return a small parent/sub-tab model for visual acceptance on FRAME."
  (with-selected-frame frame
    (let ((index 0))
      (list
       :tabs
       (mapcar
        (lambda (tab)
          (setq index (1+ index))
          (let ((target index)
                (current (eq (car tab) 'current-tab)))
            (append
             (list :id target
                   :name (or (alist-get 'name tab) "")
                   :current current
                   :status (if (= target 1) 'running 'success))
             (unless current
               (list :select
                     (lambda ()
                       (interactive)
                       (with-selected-frame frame
                         (tab-bar-select-tab target))))))))
        (tab-bar-tabs frame))
       :sub-tabs
       (list (list :id 'main :name "Main Flow" :current t :status 'success)
             (list :id 'review :name "review Queue"
                   :subtitle "consumer model" :status 'error
                   :select #'ignore))))))

(defun brutal-paper-e2e--setup ()
  "Build the shared visual acceptance scene."
  (require 'brutal-paper)
  (brutal-paper-e2e--apply-font
   (brutal-paper-e2e--next-font (selected-frame))
   (selected-frame))
  (brutal-paper-e2e--apply-colour-theme
   (brutal-paper-e2e--next-theme))
  (brutal-paper-mode 1)
  (brutal-paper-e2e--apply-title-colours
   (brutal-paper-e2e--next-title-colours) (selected-frame))

  (delete-other-windows)
  (find-file (expand-file-name "brutal-paper.el"
                               brutal-paper-e2e--project-directory))
  (tab-bar-rename-tab "Theme Lab")
  (let ((info-window (split-window-below -12)))
    (set-window-buffer info-window (brutal-paper-e2e--info-buffer)))

  (tab-bar-new-tab)
  (tab-bar-rename-tab "e2e Tests")
  (find-file (expand-file-name "test/brutal-paper-test.el"
                               brutal-paper-e2e--project-directory))
  (tab-bar-switch-to-tab "Theme Lab")
  (goto-char (point-min))

  (setq brutal-paper-tab-model-function #'brutal-paper-e2e--tab-model)
  (brutal-paper-e2e--tile-frame)
  (brutal-paper-apply)
  (brutal-paper-e2e--start-presentation-timer (selected-frame))
  (unless brutal-paper-mode
    (error "Brutal Paper E2E failed to enable brutal-paper-mode"))
  (when (memq 'brutal-paper custom-enabled-themes)
    (error "Brutal Paper must not enter custom-enabled-themes"))
  (message "Brutal Paper E2E ready · Emacs %s · theme %s · font %s · title %s · seed %d · checkout %s"
           emacs-version brutal-paper-e2e--active-colour-theme
           brutal-paper-e2e--active-font
           (plist-get brutal-paper-e2e--active-title-colours :name)
           brutal-paper-e2e-seed brutal-paper-e2e--project-directory)
  (when brutal-paper-e2e-ready-file
    (with-temp-file brutal-paper-e2e-ready-file
      (insert (format "Emacs %s ready\n" emacs-version)))))

(when (display-graphic-p)
  (brutal-paper-e2e--setup))

(provide 'brutal-paper-e2e-init)
;;; e2e-init.el ends here
