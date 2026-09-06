;; Native compilation enhances Emacs performance by converting Elisp code into
;; native machine code, resulting in faster execution and improved
;; responsiveness.
;;
;; Ensure adding the following compile-angel code at the very beginning
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
  (compile-angel-on-load-mode 1))

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

;; Let WezTerm supply the default terminal background so standalone terminal
;; Emacs has the same transparency as a tmux pane.  Keep GUI face backgrounds
;; under Emacs's normal control.
(defun my/terminal-use-default-background (frame)
  "Use the terminal's default background in non-graphical FRAME."
  (unless (display-graphic-p frame)
    (set-face-attribute 'default frame :background nil)))

(add-hook 'after-make-frame-functions #'my/terminal-use-default-background)
(my/terminal-use-default-background (selected-frame))

;; EnvVar Sync
(use-package exec-path-from-shell
  :if (and (or (display-graphic-p) (daemonp))
           (eq system-type 'darwin)) ; macOS only
  :demand t
  :functions exec-path-from-shell-initialize
  :config
  (dolist (var '("TMPDIR"
                 "SSH_AUTH_SOCK" "SSH_AGENT_PID"
                 "GPG_AGENT_INFO"
                 ;; "FZF_DEFAULT_COMMAND" "FZF_DEFAULT_OPTS" ; fzf
                 ;; "VIRTUAL_ENV" ; Python
                 ;; "GOPATH" "GOROOT" "GOBIN" ; Go
                 ;; "CARGO_HOME" "RUSTUP_HOME" ; Rust
                 ;; "NVM_DIR" "NODE_PATH" ; Node/JS
                 "LANG" "LC_CTYPE"))
    (add-to-list 'exec-path-from-shell-variables var))
  ;; Initialize
  (exec-path-from-shell-initialize))

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

;; Soft Wrapping (Visual Line Mode)
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
(use-package undo-fu
  :commands (undo-fu-only-redo-all
             undo-fu-disable-checkpoint)
  :bind (("C-z" . undo-fu-only-undo)
         ("C-S-z" . undo-fu-only-redo)))

;; The undo-fu-session package complements undo-fu by enabling the saving
;; and restoration of undo history across Emacs sessions, even after restarting.
(use-package undo-fu-session
  :hook (after-init . undo-fu-session-global-mode))

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
  (setq easysession-save-mode-lighter-show-session-name t)

  ;; Restore buffers and layouts without resizing/repositioning frames at startup.
  (setq easysession-setup-load-session-including-geometry nil)

  ;; Handle GUI-to-terminal session restoration when using an Emacs daemon.
  (setq easysession-frameset-restore-force-current-display (daemonp))


  ;; Optionally, the session name can be shown in the modeline info area:
  ;; (setq easysession-mode-line-misc-info t)
  ;; non-nil: Make `easysession-setup' load the session automatically.
  ;; (nil: session is not loaded automatically; the user can load it manually.)
  (setq easysession-setup-load-session t)
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
  ;; C-c C-c l: preview in Emacs, refreshing on save, in either GUI or terminal.
  ;; C-c C-c p: preview in the configured external browser.
  ;; Keep source and preview side by side, matching the usual Markdown workflow.
  (markdown-split-window-direction 'right)
  (markdown-live-preview-window-function #'my/markdown-live-preview-window-eww)
  :bind
  (:map markdown-mode-map
        ("C-c C-e" . markdown-do))
  :config
  (defun my/markdown-live-preview-window-eww (file)
    "Preview FILE with EWW, avoiding terminal image-layer artifacts.
Graphical Emacs renders images normally. In a terminal, EWW shows image alt
text because WezTerm does not reliably clip Kitty or Sixel images between
Emacs windows, with or without tmux."
    (if (display-graphic-p)
        (markdown-live-preview-window-eww file)
      (let ((shr-inhibit-images t))
        (markdown-live-preview-window-eww file)))))

;; Terminal graphics protocols paint into terminal-wide coordinates rather than
;; an individual Emacs window.  In WezTerm, both Kitty placements and Sixel can
;; therefore survive a split change and overwrite an unrelated pane.  Inhibit
;; images while SHR renders EWW HTML whenever the shared buffer is visible in a
;; terminal frame.  GUI-only EWW buffers continue to use native Emacs images.
(use-package eww
  :ensure nil
  :commands eww
  :config
  (defun my/eww-buffer-visible-in-terminal-p ()
    "Return non-nil when the current buffer is visible in a terminal frame.
When the buffer is not visible, use the selected frame as the render target."
    (let ((windows (get-buffer-window-list (current-buffer) nil 'visible)))
      (if windows
          (catch 'terminal
            (dolist (window windows)
              (unless (display-graphic-p (window-frame window))
                (throw 'terminal t)))
            nil)
        (not (display-graphic-p)))))

  (defun my/eww-display-html-with-safe-images (function &rest args)
    "Call FUNCTION with ARGS, suppressing unsafe terminal EWW images."
    (let ((shr-inhibit-images
           (or shr-inhibit-images
               (my/eww-buffer-visible-in-terminal-p))))
      (apply function args)))

  (advice-add 'eww-display-html :around
              #'my/eww-display-html-with-safe-images))

;; Inline images in WezTerm and other supported terminals; GUI rendering stays native.
(use-package kitty-graphics
  ;; Not in the configured package archives; use package.el's VC support.
  :vc (:url "https://github.com/cashmeredev/kitty-graphics.el" :rev :newest)
  :commands kitty-graphics-doctor
  ;; Setup handles ordinary terminal startup and later terminal client frames.
  :hook (after-init . kitty-graphics-setup)
  :custom
  ;; Prefer Sixel for terminal image workflows that occupy a whole window.
  ;; Neither Sixel nor Kitty placements are safely clipped to split EWW
  ;; windows in WezTerm, so the EWW configuration above inhibits those images.
  (kitty-graphics-preferred-protocol 'sixel)
  (kitty-graphics-sixel-encoder-program "magick")
  (kitty-graphics-shr-scale 'fit)
  (kitty-graphics-shr-fit-width 0.9)
  (kitty-graphics-shr-fit-height 20)
  :config
  (defun my/kitty-graphics-window-body-boundary (args)
    "Restrict image refresh in ARGS to the window body, excluding its mode line."
    (let ((window (nth 1 args)))
      (list (car args) window
            (min (nth 2 args) (nth 3 (window-body-edges window))))))

  (advice-add 'kitty-graphics--refresh-overlay :filter-args
              #'my/kitty-graphics-window-body-boundary))

(use-package shr-tag-pre-highlight
  :after eww
  :demand t
  :config
  (defface my/eww-code-block
    '((((class color) (background dark))
       :inherit fixed-pitch :background "#202830" :extend t)
      (((class color) (background light))
       :inherit fixed-pitch :background "#f6f8fa" :extend t)
      (t :inherit fixed-pitch))
    "Background for EWW code blocks, preserving syntax highlighting."
    :group 'eww)

  (defun my/eww-render-code-block (dom)
    "Render code in DOM with syntax colors and a block background."
    (shr-ensure-newline)
    (let ((start (point)))
      (shr-tag-pre-highlight dom)
      (add-face-text-property start (point) 'my/eww-code-block t)))

  (defun my/eww-setup-code-blocks ()
    "Use highlighted code blocks in this EWW buffer."
    (setq-local shr-external-rendering-functions
                (cons '(pre . my/eww-render-code-block)
                      shr-external-rendering-functions)))

  (add-hook 'eww-mode-hook #'my/eww-setup-code-blocks))

;; Automatically generate a table of contents when editing Markdown files
(use-package markdown-toc
  :commands (markdown-toc-generate-toc
             markdown-toc-generate-or-refresh-toc
             markdown-toc-delete-toc
             markdown-toc--toc-already-present-p)
  :init
  (setq markdown-toc-header-toc-title "**Table of Contents**"))
