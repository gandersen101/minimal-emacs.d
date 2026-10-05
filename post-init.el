;;; post-init.el --- Personal setup -*- no-byte-compile: t; lexical-binding: t; -*-

;; Hide a minor mode's mode-line indicator while leaving the mode enabled
(defun my/hide-mode-line-lighter (mode)
  "Hide MODE's lighter without disabling the mode itself."
  (let ((entry (assq mode minor-mode-alist)))
    (when entry
      ;; An empty lighter preserves the conditional mode-line construct.
      ;; Removing its cdr altogether makes Emacs render `*invalid*'.
      (setcdr entry '("")))))

;; Native compilation enhances Emacs performance by converting Elisp code into
;; native machine code, resulting in faster execution and improved
;; responsiveness.
;;
;; Ensure adding the following compile-angel code near the very beginning
;; of your `~/.emacs.d/post-init.el` file, before all other packages.
(use-package compile-angel
  :demand t
  :config
  ;; The following disables compilation of packages during installation;
  ;; compile-angel will handle it.
  (setq package-native-compile nil)

  ;; Set `compile-angel-verbose' to nil to disable compile-angel messages.
  ;; (When set to nil, compile-angel won't show which file is being compiled.)
  (setq compile-angel-verbose t)

  ;; The following directive prevents compile-angel from compiling your init
  ;; files. If you choose to remove this push to `compile-angel-excluded-files'
  ;; and compile your pre/post-init files, ensure you understand the
  ;; implications and thoroughly test your code. For example, if you're using
  ;; the `use-package' macro, you'll need to explicitly add:
  ;; (eval-when-compile (require 'use-package))
  ;; at the top of your init file.
  (push "/init.el" compile-angel-excluded-files)
  (push "/early-init.el" compile-angel-excluded-files)
  (push "/pre-init.el" compile-angel-excluded-files)
  (push "/post-init.el" compile-angel-excluded-files)
  (push "/pre-early-init.el" compile-angel-excluded-files)
  (push "/post-early-init.el" compile-angel-excluded-files)

  ;; A local mode that compiles .el files whenever the user saves them.
  ;; (add-hook 'emacs-lisp-mode-hook #'compile-angel-on-save-local-mode)

  ;; A global mode that compiles .el files prior to loading them via `load' or
  ;; `require'. Additionally, it compiles all packages that were loaded before
  ;; the mode `compile-angel-on-load-mode' was activated.
  (compile-angel-on-load-mode 1)

  ;; Its on-load state is steady and does not need permanent mode-line space.
  (my/hide-mode-line-lighter 'compile-angel-on-load-mode))

;; Each Emacs build compiles packages into its own subdirectory of the user
;; eln-cache, named after `comp-native-version-dir'. After a Homebrew upgrade,
;; the subdirectories of earlier builds stay on disk. Delete them when Emacs
;; is first idle after startup. The first entry of `native-comp-eln-load-path'
;; is the user cache; the cache in the Emacs.app bundle is not touched.
;; `delete-directory' deletes permanently here: its TRASH argument is nil, so
;; `delete-by-moving-to-trash' does not apply.
(defun my/delete-old-eln-caches ()
  "Delete the native compilation caches of other Emacs builds."
  (when (and (featurep 'native-compile)
             (boundp 'comp-native-version-dir))
    (let ((cache-dir (car native-comp-eln-load-path)))
      (when (file-directory-p cache-dir)
        (dolist (dir (directory-files cache-dir t
                                      "\\`[0-9]+_[0-9]+-[0-9a-f]+\\'"))
          (when (and (file-directory-p dir)
                     (not (equal (file-name-nondirectory dir)
                                 comp-native-version-dir)))
            (delete-directory dir t)
            (message "Deleted the native compilation cache %s"
                     (abbreviate-file-name dir))))))))

(unless noninteractive
  (run-with-idle-timer 10 nil #'my/delete-old-eln-caches))

;; Use MesloLGL Nerd Font Mono at 15 pt for graphical frames. Terminal frames
;; ignore these attributes and use the font of the terminal emulator.
;; Set the default for all frames. Emacs applies it while it creates a frame,
;; before it fixes the frame size. A daemon creates its GUI frames after
;; startup. A font change from `after-make-frame-functions' is too late,
;; because `frame-inhibit-implied-resize' keeps the pixel size of the frame.
;; The frame then gets fewer columns.
(set-face-attribute 'default nil
                    :family "MesloLGL Nerd Font Mono"
                    :height 150)

;; Upstream init.el enables `context-menu-mode' only when the startup frame is
;; graphical. A daemon starts without a frame, so its GUI client frames do not
;; get the menu. The mode is global, and terminal frames are not affected.
(when (and (daemonp)
           (memq 'context-menu minimal-emacs-ui-features)
           (fboundp 'context-menu-mode))
  (add-hook 'after-init-hook #'context-menu-mode))

;; Environment variable synchronization (macOS)
(use-package exec-path-from-shell
  :if (and (or (display-graphic-p) (daemonp))
           (eq system-type 'darwin)) ; macOS only
  :demand t
  :functions exec-path-from-shell-initialize
  :config
  (dolist (var '("TMPDIR"
                 "SSH_AUTH_SOCK"
                 "EDITOR" "VISUAL"
                 "LANG" "LC_CTYPE"))
    (add-to-list 'exec-path-from-shell-variables var))
  ;; Initialization also imports PATH and updates `exec-path'.
  (exec-path-from-shell-initialize))

;; The Emacs server allows external programs such as `emacsclient' to connect to
;; a single running instance of Emacs. This makes it possible to open files in
;; the existing session rather than starting a new Emacs process each time.
;;
;; Normally a launchd agent runs Emacs as a daemon, and the daemon starts its
;; own server (see bin/install-emacs-daemon). This block is for a standalone
;; Emacs. It starts a server only when no other Emacs runs one.
(use-package server
  :ensure nil
  :if (not (daemonp))
  :preface
  (defun my/server-start ()
    "Start the Emacs server if no server process is currently active."
    (unless (server-running-p)
      (server-start)))
  :init
  ;; Defer starting the server until after Emacs has finished initializing
  (add-hook 'emacs-startup-hook #'my/server-start))

;; Restart Emacs to load configuration changes. Keep this near the top of the
;; file, so that the command exists even when a later form fails.
(defun my/check-config-syntax ()
  "Signal an error when a personal configuration file has unbalanced parentheses."
  (let ((lisp-dir (expand-file-name "lisp" minimal-emacs-user-directory)))
    (dolist (file (append
                   (directory-files minimal-emacs-user-directory t
                                    "\\`\\(?:pre\\|post\\)-.*\\.el\\'")
                   (and (file-directory-p lisp-dir)
                        (directory-files-recursively lisp-dir "\\.el\\'"))))
      (with-temp-buffer
        (insert-file-contents file)
        (with-syntax-table emacs-lisp-mode-syntax-table
          (condition-case err
              (check-parens)
            (user-error
             (user-error "%s:%d: %s" (abbreviate-file-name file)
                         (line-number-at-pos) (error-message-string err)))))))))

;; `restart-emacs' asks to save modified buffers, and easysession saves the
;; session when Emacs exits. Emacs then starts again in the same process with
;; the same arguments, so launchd continues to manage the daemon. A daemon has
;; no frame after the restart, so scripts/reopen-emacs-frame opens one. The
;; script runs in a background subshell, so it continues after the restart.
(defun my/restart-emacs ()
  "Restart Emacs to load configuration changes.
In a daemon, open a GUI frame when the restarted daemon is ready."
  (interactive)
  (my/check-config-syntax)
  (when (y-or-n-p "Restart Emacs? ")
    (when (daemonp)
      (let ((client (or (executable-find "emacsclient")
                        (user-error "Cannot find emacsclient"))))
        (call-process "/bin/sh" nil 0 nil "-c"
                      "\"$0\" \"$@\" </dev/null >/dev/null 2>&1 &"
                      (expand-file-name "scripts/reopen-emacs-frame"
                                        minimal-emacs-user-directory)
                      client
                      (expand-file-name server-name server-socket-dir)
                      (number-to-string (float-time before-init-time)))))
    (restart-emacs)))

(global-set-key (kbd "C-c q r") #'my/restart-emacs)

;; Keep terminal and graphical Emacs in sync with the macOS clipboard.
;; GUI frames retain Emacs's native clipboard integration; terminal frames
;; use macOS's pbcopy and pbpaste commands.
(defvar my/macos-clipboard-last-text nil
  "Last clipboard text copied or imported by Emacs.")

(defun my/interprogram-cut-to-macos (text &optional _push)
  (if (display-graphic-p)
      (progn
        (gui-select-text text)
        (setq my/macos-clipboard-last-text (substring-no-properties text)))
    (with-temp-buffer
      (insert text)
      (when (eq 0 (call-process-region (point-min) (point-max) "pbcopy"))
        (setq my/macos-clipboard-last-text (substring-no-properties text))))))

(defun my/interprogram-paste-from-macos ()
  (if (display-graphic-p)
      (gui-selection-value)
    (with-temp-buffer
      (when (eq 0 (call-process "pbpaste" nil t nil))
        (let ((text (buffer-string)))
          (unless (equal text my/macos-clipboard-last-text)
            (setq my/macos-clipboard-last-text text)
            (unless (equal text "")
              text)))))))

(setq select-enable-clipboard t
      interprogram-cut-function #'my/interprogram-cut-to-macos
      interprogram-paste-function #'my/interprogram-paste-from-macos
      save-interprogram-paste-before-kill t)

;; Auto-revert in Emacs is a feature that automatically updates the
;; contents of a buffer to reflect changes made to the underlying file
;; on disk.
(use-package autorevert
  :ensure nil
  :commands (auto-revert-mode global-auto-revert-mode)
  :hook
  (after-init . global-auto-revert-mode)
  :init
  ;; (setq auto-revert-verbose t)
  (setq auto-revert-interval 3)
  (setq auto-revert-remote-files nil)
  (setq auto-revert-use-notify t)
  (setq auto-revert-avoid-polling nil))

;; Recentf is an Emacs package that maintains a list of recently
;; accessed files, making it easier to reopen files you have worked on
;; recently.
(use-package recentf
  :ensure nil
  :commands (recentf-mode recentf-cleanup)
  :hook
  (after-init . recentf-mode)

  :init
  (setq recentf-auto-cleanup (if (daemonp) 300 'never))
  (setq recentf-exclude
        (list "\\.tar$" "\\.tbz2$" "\\.tbz$" "\\.tgz$" "\\.bz2$"
              "\\.bz$" "\\.gz$" "\\.gzip$" "\\.xz$" "\\.zip$"
              "\\.7z$" "\\.rar$"
              "COMMIT_EDITMSG\\'"
              "\\.\\(?:gz\\|gif\\|svg\\|png\\|jpe?g\\|bmp\\|xpm\\)$"
              "-autoloads\\.el$" "autoload\\.el$"))

  :config
  ;; A cleanup depth of -90 ensures that `recentf-cleanup' runs before
  ;; `recentf-save-list', allowing stale entries to be removed before the list
  ;; is saved by `recentf-save-list', which is automatically added to
  ;; `kill-emacs-hook' by `recentf-mode'.
  (add-hook 'kill-emacs-hook #'recentf-cleanup -90))

;; savehist is an Emacs feature that preserves the minibuffer history between
;; sessions. It saves the history of inputs in the minibuffer, such as commands,
;; search strings, and other prompts, to a file. This allows users to retain
;; their minibuffer history across Emacs restarts.
(use-package savehist
  :ensure nil
  :commands (savehist-mode savehist-save)
  :hook
  (after-init . savehist-mode)
  :init
  (setq history-length 300)
  (setq savehist-autosave-interval 600))

;; save-place-mode enables Emacs to remember the last location within a file
;; upon reopening. This feature is particularly beneficial for resuming work at
;; the precise point where you previously left off.
(use-package saveplace
  :ensure nil
  :commands (save-place-mode save-place-local-mode)
  :hook
  (after-init . save-place-mode)
  :init
  (setq save-place-limit 400))

;; Enable `auto-save-mode' to prevent data loss. Use `recover-file' or
;; `recover-session' to restore unsaved changes.
(setq auto-save-default t)

;; Trigger an auto-save after 300 keystrokes
(setq auto-save-interval 300)

;; Trigger an auto-save 30 seconds of idle time.
(setq auto-save-timeout 30)

;; When auto-save-visited-mode is enabled, Emacs will auto-save file-visiting
;; buffers after a period of idle time.
(setq auto-save-visited-interval 5)
(auto-save-visited-mode 1)

;; Soft wrapping (Visual Line Mode)
;; Wrap prose at the window edge without changing the underlying buffer text.
;; Programming and utility buffers retain the upstream truncated-line default.
(add-hook 'text-mode-hook #'visual-line-mode)

;; Corfu enhances in-buffer completion by displaying a compact popup with
;; current candidates, positioned either below or above the point. Candidates
;; can be selected by navigating up or down.
(use-package corfu
  :commands (corfu-mode global-corfu-mode)

  :hook (after-init . global-corfu-mode)

  :custom
  ;; Hide commands in M-x which do not apply to the current mode.
  (read-extended-command-predicate #'command-completion-default-include-p)
  ;; Disable Ispell completion function. As an alternative try `cape-dict'.
  (text-mode-ispell-word-completion nil)
  (tab-always-indent 'complete))

;; `corfu-popupinfo' is bundled with Corfu.
(use-package corfu-popupinfo
  :ensure nil
  :after corfu
  :config
  (corfu-popupinfo-mode 1))

;; Cape, or Completion At Point Extensions, extends the capabilities of
;; in-buffer completion. It integrates with Corfu or the default completion UI,
;; by providing additional backends through completion-at-point-functions.
(use-package cape
  :commands (cape-dabbrev cape-file cape-elisp-block)
  :bind ("C-c p" . cape-prefix-map)
  :init
  ;; Add to the global default value of `completion-at-point-functions' which is
  ;; used by `completion-at-point'.
  (add-hook 'completion-at-point-functions #'cape-dabbrev)
  (add-hook 'completion-at-point-functions #'cape-file)
  (add-hook 'completion-at-point-functions #'cape-elisp-block))

(use-package vertico
  :config
  (vertico-mode))

(use-package orderless
  :custom
  (completion-styles '(orderless basic))
  (completion-category-defaults nil)
  (completion-category-overrides '((file (styles partial-completion)))))

(use-package marginalia
  :commands (marginalia-mode marginalia-cycle)
  :hook (after-init . marginalia-mode))

(use-package embark
  :commands (embark-act
             embark-dwim
             embark-export
             embark-collect
             embark-bindings
             embark-prefix-help-command)
  :bind
  (("C-c e" . embark-act)
   ("C-;" . embark-dwim)
   ("C-h B" . embark-bindings))
  :init
  (setq prefix-help-command #'embark-prefix-help-command)
  :config
  (add-to-list 'display-buffer-alist
               '("\\`\\*Embark Collect \\(Live\\|Completions\\)\\*"
                 nil
                 (window-parameters (mode-line-format . none)))))

(use-package embark-consult
  :ensure t
  :defer t)

(use-package consult
  :bind (;; C-c bindings in `mode-specific-map'
         ("C-c M-x" . consult-mode-command)
         ("C-c h" . consult-history)
         ("C-c k" . consult-kmacro)
         ("C-c m" . consult-man)
         ("C-c i" . consult-info)
         ([remap Info-search] . consult-info)
         ;; C-x bindings in `ctl-x-map'
         ("C-x M-:" . consult-complex-command)
         ("C-x b" . consult-buffer)
         ("C-x 4 b" . consult-buffer-other-window)
         ("C-x 5 b" . consult-buffer-other-frame)
         ("C-x t b" . consult-buffer-other-tab)
         ("C-x r b" . consult-bookmark)
         ("C-x p b" . consult-project-buffer)
         ;; Custom M-# bindings for fast register access
         ("M-#" . consult-register-load)
         ("M-'" . consult-register-store)
         ("C-M-#" . consult-register)
         ;; Other custom bindings
         ("M-y" . consult-yank-pop)
         ;; M-g bindings in `goto-map'
         ("M-g e" . consult-compile-error)
         ("M-g f" . consult-flymake)
         ("M-g g" . consult-goto-line)
         ("M-g M-g" . consult-goto-line)
         ("M-g o" . consult-outline)
         ("M-g m" . consult-mark)
         ("M-g k" . consult-global-mark)
         ("M-g i" . consult-imenu)
         ("M-g I" . consult-imenu-multi)
         ;; M-s bindings in `search-map'
         ("M-s d" . consult-find)
         ("M-s c" . consult-locate)
         ("M-s g" . consult-grep)
         ("M-s G" . consult-git-grep)
         ("M-s r" . consult-ripgrep)
         ("M-s l" . consult-line)
         ("M-s L" . consult-line-multi)
         ("M-s k" . consult-keep-lines)
         ("M-s u" . consult-focus-lines)
         ;; Isearch integration
         ("M-s e" . consult-isearch-history)
         :map isearch-mode-map
         ("M-e" . consult-isearch-history)
         ("M-s e" . consult-isearch-history)
         ("M-s l" . consult-line)
         ("M-s L" . consult-line-multi)
         ;; Minibuffer history
         :map minibuffer-local-map
         ("M-s" . consult-history)
         ("M-r" . consult-history))
  :init
  (setq register-preview-delay 0.5
        register-preview-function #'consult-register-format)
  (advice-add #'register-preview :override #'consult-register-window)
  (setq xref-show-xrefs-function #'consult-xref
        xref-show-definitions-function #'consult-xref)
  :config
  (consult-customize
   consult-theme :preview-key '(:debounce 0.2 any)
   consult-ripgrep consult-git-grep consult-grep
   consult-bookmark consult-recent-file consult-xref
   consult-source-bookmark consult-source-file-register
   consult-source-recent-file consult-source-project-recent-file
   :preview-key '(:debounce 0.4 any))
  (setq consult-narrow-key "<"))

;; The undo-fu package is a lightweight wrapper around Emacs' built-in undo
;; system, providing more convenient undo/redo functionality.
;; C-S-z and C-? are the redo keys in GUI frames. A terminal sends the same byte
;; for C-z and C-S-z, so terminal frames use C-M-_ instead. C-M-_ and C-?
;; replace the built-in `undo-redo' bindings, so every redo key runs the same
;; command. `undo-fu-only-redo' uses a copy of `undo-redo', so it also redoes
;; after the built-in `undo' on C-/, C-_, and C-x u.
(use-package undo-fu
  :commands (undo-fu-only-redo-all
             undo-fu-disable-checkpoint)
  :bind (("C-z" . undo-fu-only-undo)
         ("C-S-z" . undo-fu-only-redo)
         ("C-M-_" . undo-fu-only-redo)
         ("C-?" . undo-fu-only-redo)))

;; The undo-fu-session package complements undo-fu by enabling the saving
;; and restoration of undo history across Emacs sessions, even after restarting.
(use-package undo-fu-session
  :hook (after-init . undo-fu-session-global-mode))

(use-package doom-themes
  :ensure t
  :custom
  ;; Global settings (defaults)
  (doom-themes-enable-bold t)   ; if nil, bold is universally disabled
  (doom-themes-enable-italic t) ; if nil, italics is universally disabled
  ;; for treemacs users
  ;; (doom-themes-treemacs-theme "doom-atom") ; use "doom-colors" for less minimal icon theme
  :config
  (load-theme 'doom-one t)

  ;; Enable flashing mode-line on errors
  (doom-themes-visual-bell-config)
  ;; Enable custom  treemacs users
  ;; (doom-themes-treemacs-config)
  ;; Corrects (and improves) org-mode's native fontification.
  (doom-themes-org-config))

;; The easysession Emacs package is a session manager for Emacs that can persist
;; and restore file editing buffers, indirect buffers/clones, Dired buffers,
;; windows/splits, the built-in tab-bar (including tabs, their buffers, and
;; windows), and Emacs frames. It offers a convenient and effortless way to
;; manage Emacs editing sessions and utilizes built-in Emacs functions to
;; persist and restore frames.
(use-package easysession
  ;; ':demand t' ensures the package is loaded immediately upon startup
  :demand t

  :config
  ;; Key mappings
  (global-set-key (kbd "C-c sl") #'easysession-switch-to) ; Load session
  (global-set-key (kbd "C-c ss") #'easysession-save) ; Save session
  (global-set-key (kbd "C-c sL") #'easysession-switch-to-and-restore-geometry)
  (global-set-key (kbd "C-c sr") #'easysession-rename)
  (global-set-key (kbd "C-c sR") #'easysession-reset)
  (global-set-key (kbd "C-c su") #'easysession-unload)
  (global-set-key (kbd "C-c sd") #'easysession-delete)

  ;; Save every 10 minutes
  (setq easysession-save-interval (* 10 60))

  ;; Save the current session when using `easysession-switch-to'
  (setq easysession-switch-to-save-session t)

  ;; Do not exclude the current session when switching sessions
  (setq easysession-switch-to-exclude-current nil)

  ;; Display the active session name in the mode-line lighter.
  ;; Keep the useful session name but omit the package's static label.
  (setq easysession-save-mode-lighter "")
  (setq easysession-save-mode-lighter-show-session-name t)

  ;; Optionally, the session name can be shown in the modeline info area:
  ;; (setq easysession-mode-line-misc-info t)
  ;; non-nil: Make `easysession-setup' load the session automatically.
  ;; (nil: session is not loaded automatically; the user can load it manually.)
  (setq easysession-setup-load-session t)

  ;; Only GUI frames for normal work belong in the session. Edit frames, which
  ;; a client such as $EDITOR opens for a commit message, and terminal frames do
  ;; not load the session, and easysession does not save them. easysession
  ;; skips a frame with a non-nil `easysession-dont-save' parameter.
  (defun my/easysession-edit-client-p ()
    "Return non-nil when the client of the selected frame waits for an edit."
    (let ((client (frame-parameter nil 'client)))
      (and (processp client)
           (process-get client 'buffers))))

  ;; Load the session automatically only in a GUI frame that is not an edit
  ;; frame. The server runs `server-after-make-frame-hook' before it shows the
  ;; edit, so a restore there can open more frames. easysession saves only a
  ;; loaded session, so the frames that skip the load cannot overwrite it.
  (defun my/easysession-load-p ()
    "Return non-nil when the selected frame should load the session."
    (and (display-graphic-p)
         (not (my/easysession-edit-client-p))))

  (setq easysession-setup-load-predicate #'my/easysession-load-p)

  ;; The server also runs this hook when it reuses an existing frame for an
  ;; edit, for example from vterm. The `client' parameter of such a frame is
  ;; not the waiting client, so the frame stays in the session.
  (defun my/easysession-skip-edit-frame ()
    "Exclude the selected frame from the session when it is an edit frame."
    (when (my/easysession-edit-client-p)
      (set-frame-parameter nil 'easysession-dont-save t)))

  (add-hook 'server-after-make-frame-hook #'my/easysession-skip-edit-frame)

  (defun my/easysession-gui-frame-p (frame)
    "Return non-nil when FRAME is a GUI frame that belongs in the session."
    (and (display-graphic-p frame)
         (not (frame-parent frame))
         (not (frame-parameter frame 'tooltip))
         (not (frame-parameter frame 'easysession-dont-save))
         (frame-visible-p frame)))

  ;; A restore in a GUI frame turns each saved terminal frame into an extra GUI
  ;; frame. So exclude terminal frames while a session GUI frame exists. Without
  ;; one (after a manual load in a terminal frame), keep the terminal frames, or
  ;; the saved layout is empty.
  (defun my/easysession-skip-terminal-frames ()
    "Exclude terminal frames from the session while a GUI frame exists."
    (let ((gui-frame-p (and (seq-some #'my/easysession-gui-frame-p (frame-list))
                            t)))
      (dolist (frame (frame-list))
        (unless (display-graphic-p frame)
          (set-frame-parameter frame 'easysession-dont-save gui-frame-p)))))

  (add-hook 'easysession-before-save-hook #'my/easysession-skip-terminal-frames)

  ;; In a daemon, easysession saves and unloads the session when the last client
  ;; frame closes, also when that frame is a terminal or edit frame. Save and
  ;; unload at the last session GUI frame instead. Then a terminal or edit frame
  ;; that stays open cannot replace the GUI layout, and the next GUI frame loads
  ;; the session again.
  (defun my/easysession-unload-at-last-gui-frame (frame)
    "Save and unload the session when FRAME is the last session GUI frame."
    (when (and (daemonp)
               (my/easysession-gui-frame-p frame)
               (not (seq-some (lambda (other)
                                (and (not (eq other frame))
                                     (my/easysession-gui-frame-p other)))
                              (frame-list))))
      (easysession-unload)))

  (add-hook 'delete-frame-functions #'my/easysession-unload-at-last-gui-frame)

  ;; The `easysession-setup' function adds hooks:
  ;; - To enable automatic session loading during `emacs-startup-hook', or
  ;;   `server-after-make-frame-hook' when running in daemon mode.
  ;; - To save the session at regular intervals, and when Emacs exits.
  (easysession-setup))

;; The markdown-mode package provides a major mode for Emacs for syntax
;; highlighting, editing commands, and preview support for Markdown documents.
;; It supports core Markdown syntax as well as extensions like GitHub Flavored
;; Markdown (GFM).
(use-package markdown-mode
  :commands (gfm-mode
             gfm-view-mode
             markdown-mode
             markdown-view-mode)
  :mode (("\\.markdown\\'" . markdown-mode)
         ("\\.md\\'" . markdown-mode)
         ("README\\.md\\'" . gfm-mode))
  :custom
  ;; Prefer GFM explicitly over the automatically detected Pandoc/cmark.
  ;; Footnotes are useful in both GitHub documents and Obsidian notes.
  ;; Obsidian-specific links and embeds still need previewing in Obsidian.
  (markdown-command '("cmark-gfm" "--to" "html"
                      "-e" "table" "-e" "strikethrough"
                      "-e" "autolink" "-e" "tagfilter"
                      "-e" "tasklist" "-e" "footnotes"
                      "--strikethrough-double-tilde"))
  ;; Fontify fenced blocks in the editing buffer using the declared language.
  (markdown-fontify-code-blocks-natively t)
  ;; Obsidian uses [[note]] and [[note|display text]].  Markdown Mode supports
  ;; this syntax directly when the alias is the second component.
  (markdown-enable-wiki-links t)
  (markdown-wiki-link-alias-first nil)
  ;; Obsidian's ==highlighted text== syntax is useful in note buffers.
  (markdown-enable-highlighting-syntax t)
  ;; Keep source and live preview side by side.
  (markdown-split-window-direction 'right)
  :bind
  (:map markdown-mode-map
        ("C-c C-e" . markdown-do)))

;; EWW is markdown-mode's built-in live-preview viewer. Its default renderer
;; preserves code text but does not use the language class emitted by cmark-gfm.
;; `shr-tag-pre-highlight' uses that class (for example, language-elisp) to
;; apply the corresponding Emacs major mode's font-lock faces.
(use-package shr-tag-pre-highlight
  :ensure t
  :commands shr-tag-pre-highlight)

(use-package eww
  :ensure nil
  :commands (eww eww-open-file)
  :hook
  (eww-mode . visual-line-mode)
  :init
  (defun my/markdown-live-preview-window-eww (file)
    "Preview FILE in an EWW buffer dedicated to Markdown live previews."
    (let ((buffer (or (and (buffer-live-p markdown-live-preview-buffer)
                           markdown-live-preview-buffer)
                      (generate-new-buffer "*markdown-preview*"))))
      (with-current-buffer buffer
        (unless (derived-mode-p 'eww-mode)
          (eww-mode))
        (my/eww-setup-code-blocks)
        (eww-open-file file))
      buffer))

  (setq markdown-live-preview-window-function
        #'my/markdown-live-preview-window-eww)
  :config
  (defface my/eww-code-block
    '((((class color) (background dark))
       :inherit fixed-pitch :background "#202830" :extend t)
      (((class color) (background light))
       :inherit fixed-pitch :background "#f6f8fa" :extend t)
      (t :inherit fixed-pitch))
    "Background used to distinguish code blocks in EWW."
    :group 'eww)

  (defun my/eww-render-code-block (dom)
    "Render a PRE DOM element with syntax highlighting and a background."
    (shr-ensure-newline)
    (let ((start (point)))
      (shr-tag-pre-highlight dom)
      (add-face-text-property start (point) 'my/eww-code-block t)))

  (defun my/eww-setup-code-blocks ()
    "Enable rendered code blocks in the current EWW buffer."
    (setq-local shr-external-rendering-functions
                (cons '(pre . my/eww-render-code-block)
                      (assq-delete-all
                       'pre (copy-tree shr-external-rendering-functions)))))

  )

;; Automatically generate a table of contents when editing Markdown files
(use-package markdown-toc
  :commands (markdown-toc-generate-toc
             markdown-toc-generate-or-refresh-toc
             markdown-toc-delete-toc
             markdown-toc--toc-already-present-p)
  :init
  (setq markdown-toc-header-toc-title "**Table of Contents**"))

;; ESS provides R editing and interactive R-session support.
;; The wrapper makes `M-x R' use a uvr project environment when the session
;; starts in a project, or uvr's active global R otherwise.
(defconst my/uvr-r-program
  (expand-file-name "scripts/uvr-r" minimal-emacs-user-directory)
  "Wrapper that starts R through uvr for ESS.")

(use-package ess-r-mode
  :ensure ess
  :init
  (setq inferior-ess-r-program my/uvr-r-program)
  :mode ("\\.[Rr]\\'" . ess-r-mode))

;; Tree-sitter grammars and major-mode preferences
;;
;; Prefer Tree-sitter major modes when their grammars are available. The
;; traditional modes remain the automatic fallback on other Emacs installations.
(require 'treesit)

;; Restrict the Bash grammar to files explicitly identified as Bash. In
;; particular, retain `sh-mode' for /bin/sh and other shell dialects, even
;; though the Bash grammar can parse much of their common syntax.
(defun my/bash-mode-maybe ()
  "Use `bash-ts-mode' when its grammar is available, otherwise `sh-mode'."
  (if (and (treesit-available-p)
           (treesit-language-available-p 'bash))
      (bash-ts-mode)
    (sh-mode)))

(defun my/bash-shebang-p ()
  "Return non-nil when the buffer's first line identifies Bash."
  (save-excursion
    (goto-char (point-min))
    (looking-at-p "#!.*\\(?:/\\|[[:space:]]\\)bash\\(?:[[:space:]]\\|\\'\\)")))

(defun my/shell-mode-maybe ()
  "Use Bash Tree-sitter support only for a buffer with a Bash shebang."
  (if (my/bash-shebang-p)
      (my/bash-mode-maybe)
    (sh-mode)))

(add-to-list 'interpreter-mode-alist '("bash" . my/bash-mode-maybe))
(add-to-list 'auto-mode-alist '("\\.sh\\'" . my/shell-mode-maybe))
(dolist (pattern '("\\.bash\\'"
                   "\\(?:/\\|\\`\\)\\.bash\\(?:rc\\|_profile\\|_login\\|_logout\\|_aliases\\)\\'"
                   "/bash_completion\\(?:\\.sh\\)?\\'"))
  (add-to-list 'auto-mode-alist (cons pattern #'my/bash-mode-maybe)))

;; Emacs normally associates .html files with `mhtml-mode'. Prefer the
;; simpler HTML mode here because this configuration targets plain HTML files.
(defun my/html-mode-maybe ()
  "Use `html-ts-mode' when its grammar is available, otherwise `html-mode'."
  (if (and (treesit-available-p)
           (treesit-language-available-p 'html))
      (html-ts-mode)
    (html-mode)))

(add-to-list 'auto-mode-alist '("\\.html?\\'" . my/html-mode-maybe))

(dolist (source '((python "https://github.com/tree-sitter/tree-sitter-python")
                  (c "https://github.com/tree-sitter/tree-sitter-c")
                  (bash "https://github.com/tree-sitter/tree-sitter-bash")
                  (css "https://github.com/tree-sitter/tree-sitter-css")
                  (html "https://github.com/tree-sitter/tree-sitter-html")
                  (json "https://github.com/tree-sitter/tree-sitter-json")
                  (toml "https://github.com/tree-sitter-grammars/tree-sitter-toml")
                  (yaml "https://github.com/tree-sitter-grammars/tree-sitter-yaml")))
  (add-to-list 'treesit-language-source-alist source))
(when (treesit-available-p)
  (dolist (mode-remap '((python . (python-mode . python-ts-mode))
                        (c . (c-mode . c-ts-mode))
                        (css . (css-mode . css-ts-mode))
                        (html . (html-mode . html-ts-mode))
                        (json . (js-json-mode . json-ts-mode))
                        (toml . (conf-toml-mode . toml-ts-mode))
                        (yaml . (yaml-mode . yaml-ts-mode))))
    (when (treesit-language-available-p (car mode-remap))
      (add-to-list 'major-mode-remap-alist (cdr mode-remap)))))

;; Kirigami: a unified interface for code folding

(use-package kirigami
  :commands (kirigami-open-fold
             kirigami-open-fold-rec
             kirigami-close-fold
             kirigami-toggle-fold
             kirigami-open-folds
             kirigami-close-folds-except-current
             kirigami-close-folds)

  :bind
  (("C-c z o" . kirigami-open-fold)      ; Open fold at point
   ("C-c z O" . kirigami-open-fold-rec)  ; Open fold recursively
   ("C-c z r" . kirigami-open-folds)     ; Open all folds
   ("C-c z c" . kirigami-close-fold)     ; Close fold at point
   ("C-c z m" . kirigami-close-folds)    ; Close all folds
   ("C-c z a" . kirigami-toggle-fold))   ; Toggle fold at point

  :init
  (kirigami-global-mode 1))

;; The built-in outline-minor-mode provides structured code folding in modes
;; such as Emacs Lisp and Python, allowing users to collapse and expand sections
;; based on headings or indentation levels. This feature enhances navigation and
;; improves the management of large files with hierarchical structures.
(use-package outline
  :ensure nil
  :commands outline-minor-mode
  :hook
  (;; Use " ▼" instead of the default ellipsis "..." for folded text to make
   ;; folds more visually distinctive and readable.
   (outline-minor-mode
    .
    (lambda()
      (let* ((display-table (or buffer-display-table (make-display-table)))
             (face-offset (* (face-id 'shadow) (ash 1 22)))
             (value (vconcat (mapcar (lambda (c) (+ face-offset c)) " ▼"))))
        (set-display-table-slot display-table 'selective-display value)
        (setq buffer-display-table display-table))))))

;; Enable the mode
(add-hook 'emacs-lisp-mode-hook #'outline-minor-mode)
(add-hook 'conf-mode-hook #'outline-minor-mode)
(add-hook 'markdown-mode-hook #'outline-minor-mode)
(add-hook 'diff-mode-hook #'outline-minor-mode)

;; hs-minor-mode - ideal for C-style languages and others that use braces, `{}`
(add-hook 'c-mode-hook #'hs-minor-mode)

(defun my/css-mode-enable-hideshow ()
  "Enable hideshow in traditional CSS buffers only."
  (unless (derived-mode-p 'css-ts-mode)
    (hs-minor-mode)))

(add-hook 'css-mode-hook #'my/css-mode-enable-hideshow)

(add-hook 'ess-r-mode-hook #'hs-minor-mode)

(defun my/html-mode-enable-hideshow ()
  "Enable hideshow in traditional HTML buffers only."
  (unless (derived-mode-p 'html-ts-mode)
    (hs-minor-mode)))

(add-hook 'html-mode-hook #'my/html-mode-enable-hideshow)

(add-hook 'js-mode-hook #'hs-minor-mode)
(add-hook 'lua-mode-hook #'hs-minor-mode)
(add-hook 'sh-mode-hook #'hs-minor-mode)

;; The outline-indent Emacs package provides a minor mode that enables code
;; folding based on indentation levels.
;; In addition to code folding, outline-indent allows:
;; - Moving indented blocks up and down
;; - Indenting/unindenting to adjust indentation levels
;; - Inserting a new line with the same indentation level as the current line
;; - Move backward/forward to the indentation level of the current line
;; - and other features.
(use-package outline-indent
  :commands outline-indent-minor-mode
  :init
  (setq outline-indent-ellipsis " ▼"))

(add-hook 'python-mode-hook #'outline-indent-minor-mode)
(add-hook 'yaml-mode-hook #'outline-indent-minor-mode)
(add-hook 'yaml-ts-mode-hook #'outline-indent-minor-mode)

;; Intelligent code folding by using the structural understanding of the
;; built-in tree-sitter parser. Unlike traditional folding methods that rely on
;; regular expressions or indentation, treesit-fold uses the actual syntax tree
;; of the code to accurately identify foldable regions such as functions,
;; classes, comments, and documentation strings. This allows for faster and more
;; precise folding behavior that respects the grammar of the programming
;; language, ensuring that fold boundaries are always syntactically correct even
;; in complex or nested code structures.
(use-package treesit-fold
  :commands (treesit-fold-close
             treesit-fold-close-all
             treesit-fold-open
             treesit-fold-toggle
             treesit-fold-open-all
             treesit-fold-mode
             global-treesit-fold-mode
             treesit-fold-open-recursively
             treesit-fold-line-comment-mode)

  :init
  (setq treesit-fold-line-count-show t)
  (setq treesit-fold-line-count-format " ▼")

  :config
  (set-face-attribute 'treesit-fold-replacement-face nil
                      :foreground "#808080"
                      :box nil
                      :weight 'bold))

;; Tree-sitter major modes use syntax-tree-aware folding; their traditional
;; counterparts retain the mode-specific folding configured above.
(add-hook 'bash-ts-mode-hook #'treesit-fold-mode)
(add-hook 'c-ts-mode-hook #'treesit-fold-mode)
(add-hook 'css-ts-mode-hook #'treesit-fold-mode)
(add-hook 'html-ts-mode-hook #'treesit-fold-mode)
(add-hook 'json-ts-mode-hook #'treesit-fold-mode)
(add-hook 'python-ts-mode-hook #'treesit-fold-mode)
(add-hook 'toml-ts-mode-hook #'treesit-fold-mode)

;; dumb-jump provides context-aware 'go to definition' functionality
;; for 50+ programming languages without requiring a language server
(use-package dumb-jump
  :commands dumb-jump-xref-activate
  :init
  ;; Register `dumb-jump' as an xref backend so it integrates with
  ;; `xref-find-definitions'. A priority of 80 ensures it is used only when no
  ;; more specific backend is available.
  (with-eval-after-load 'xref
    (add-hook 'xref-backend-functions #'dumb-jump-xref-activate 80))

  (setq dumb-jump-aggressive nil)
  ;; (setq dumb-jump-quiet t)

  ;; Number of seconds a rg/grep/find command can take before being warned to
  ;; use ag and config.
  (setq dumb-jump-max-find-time 3)

  ;; Use `completing-read' so that selection of jump targets integrates with the
  ;; active completion framework (e.g., Vertico, Ivy, Helm, Icomplete),
  ;; providing a consistent minibuffer-based interface whenever multiple
  ;; definitions are found.
  (setq dumb-jump-selector 'completing-read)

  :config
  ;; If ripgrep is available, force `dumb-jump' to use it because it is
  ;; significantly faster and more accurate than the default searchers (grep,
  ;; ag, etc.).
  (when (executable-find "rg")
    (setq dumb-jump-force-searcher 'rg)
    (setq dumb-jump-prefer-searcher 'rg)))

;; The stripspace Emacs package provides stripspace-local-mode, a minor mode
;; that automatically removes trailing whitespace and blank lines at the end of
;; the buffer when saving.
(use-package stripspace
  :commands stripspace-local-mode

  ;; Enable for prog-mode-hook, text-mode-hook, conf-mode-hook
  :hook ((prog-mode . stripspace-local-mode)
         (text-mode . stripspace-local-mode)
         (conf-mode . stripspace-local-mode))

  :init
  ;; The `stripspace-only-if-initially-clean' option:
  ;; - nil to always delete trailing whitespace.
  ;; - Non-nil to only delete whitespace when the buffer is clean initially.
  ;; (The initial cleanliness check is performed when `stripspace-local-mode'
  ;; is enabled.)
  (setq stripspace-only-if-initially-clean nil)

  ;; Enabling `stripspace-restore-column' preserves the cursor's column position
  ;; even after stripping spaces. This is useful in scenarios where you add
  ;; extra spaces and then save the file. Although the spaces are removed in the
  ;; saved file, the cursor remains in the same position, ensuring a consistent
  ;; editing experience without affecting cursor placement.
  (setq stripspace-restore-column t))

;; diff-hl highlights uncommitted changes in the window margin,
;; enabling navigation between them
(use-package diff-hl
  :commands (diff-hl-mode
             global-diff-hl-mode)
  :hook (emacs-startup . global-diff-hl-mode)
  :init
  ;; Start globally after initialization so restored and subsequently opened
  ;; buffers both participate.  Git supplies no line markers for binary or
  ;; untracked files.
  (setq diff-hl-global-modes '(not pdf-view-mode image-mode))
  (setq diff-hl-flydiff-delay 0.4)  ; Faster optional flydiff updates
  (setq diff-hl-show-staged-changes nil)  ; Separate staged changes
  (setq diff-hl-update-async t))  ; Do not block Emacs

;; Org mode is a major mode designed for organizing notes, planning, task
;; management, and authoring documents using plain text with a simple and
;; expressive markup syntax. It supports hierarchical outlines, TODO lists,
;; scheduling, deadlines, time tracking, and exporting to multiple formats
;; including HTML, LaTeX, PDF, and Markdown.
(use-package org
  :commands (org-mode org-version)
  :mode
  ("\\.org\\'" . org-mode)
  :hook
  (org-mode . visual-line-mode)
  :init
  (setq org-hide-leading-stars t)
  (setq org-startup-indented t)
  (setq org-adapt-indentation nil)
  (setq org-edit-src-content-indentation 0)
  (setq org-fontify-done-headline t)
  (setq org-fontify-todo-headline t)
  (setq org-fontify-whole-heading-line t)
  (setq org-fontify-quote-and-verse-blocks t)
  (setq org-startup-truncated nil))

;; org-appear temporarily reveals normally hidden elements
;; (such as emphasis markers, links, or entities)
;; when the cursor enters them, and hides them again when the cursor leaves
(use-package org-appear
  :commands org-appear-mode
  :hook (org-mode . org-appear-mode))

;; Resolve the venv, Ruff, and Mypy for each Python file from the venvs above
;; it.  Project-specific lint, format, and type-check policy belongs in
;; pyproject.toml.  See lisp/my-python-env/README.md.
;;
;; Each personal package lives in its own directory under lisp/.
(let ((lisp-dir (expand-file-name "lisp" minimal-emacs-user-directory)))
  (when (file-directory-p lisp-dir)
    (dolist (dir (directory-files lisp-dir t "\\`[^.]"))
      (when (file-directory-p dir)
        (add-to-list 'load-path dir)))))

(use-package my-python-env
  :ensure nil
  :commands (my/python-eglot-ensure
             my/python-env-reload
             my/python-env-describe)
  :hook ((python-mode . my/python-eglot-ensure)
         (python-ts-mode . my/python-eglot-ensure)))

;; Set up the Language Server Protocol (LSP) servers using Eglot.
(use-package eglot
  :ensure nil
  :commands (eglot-ensure
             eglot-rename
             eglot-format-buffer)
  :config
  (require 'my-python-env)
  (my/python-env-setup))
