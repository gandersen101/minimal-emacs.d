;;; my-python-env.el --- Per-directory Python tool resolution for Eglot -*- lexical-binding: t; -*-

;;; Commentary:
;; Choose the Python environment and tools for each file-visiting Python
;; buffer from the venvs above it on the filesystem:
;;
;; - Jedi (xref, completion) uses the nearest venv.
;; - Ruff uses the nearest venv that provides `bin/ruff'.
;; - Mypy uses the nearest venv that provides `bin/mypy'.
;;
;; Each lookup falls back to the central uv tool environment for pylsp, and
;; then to `exec-path'.
;;
;; pylsp settings apply to a whole workspace, so Eglot starts one pylsp server
;; for each directory that holds a venv.  Only Eglot sees these projects; the
;; normal VC project still applies to `project.el' commands.
;;
;; Ruff runs outside pylsp: a Flymake backend lints the buffer, and Apheleia
;; formatters sort the imports and format the buffer on save.  Each Ruff run
;; looks up the tool from the directory of the buffer's file.
;;
;; After you create or delete a venv, run `my/python-env-reload'.
;;
;; See README.md in this directory for the design, config behavior, and
;; caveats.

;;; Code:

(require 'flymake)
(require 'project)
(require 'seq)

(defvar apheleia-formatters)
(defvar apheleia-mode-alist)
(defvar eglot-lsp-context)
(defvar eglot-server-programs)
(declare-function eglot-current-server "eglot")
(declare-function eglot-managed-p "eglot")
(declare-function eglot-shutdown "eglot")

(defgroup my/python-env nil
  "Per-directory Python tool resolution for Eglot."
  :group 'tools)

(defcustom my/python-env-venv-names '(".venv" "venv")
  "Directory names to check for a venv, in order of preference.
A candidate counts as a venv only when it contains `pyvenv.cfg'."
  :type '(repeat string))

(defcustom my/python-env-fallback-bin
  ;; Mirror uv's tool directory rules without running `uv tool dir' at startup.
  (expand-file-name
   "python-lsp-server/bin"
   (or (getenv "UV_TOOL_DIR")
       (expand-file-name "uv/tools"
                         (or (getenv "XDG_DATA_HOME") "~/.local/share"))))
  "The `bin' directory of the central uv tool environment for pylsp.
Ruff and Mypy in this directory are the fallbacks when no venv provides
them, although uv does not link them onto PATH."
  :type 'directory)

(defvar my/python-env--cache (make-hash-table :test #'equal)
  "Resolved venvs and tools, keyed by (DIRECTORY . KIND).
Negative results are cached too; see `my/python-env-reload'.")

(defun my/python-env--normalize (dir)
  "Return DIR as an absolute directory name."
  (file-name-as-directory (expand-file-name dir)))

(defun my/python-env--cached (dir kind compute)
  "Return the cached KIND value for DIR, or store the result of COMPUTE."
  (let* ((key (cons dir kind))
         (value (gethash key my/python-env--cache 'miss)))
    (if (eq value 'miss)
        (puthash key (funcall compute) my/python-env--cache)
      value)))

(defun my/python-env--executable (file)
  "Return FILE when it is an executable regular file."
  (and (file-executable-p file)
       (not (file-directory-p file))
       file))

(defun my/python-env--venvs (dir)
  "Return the venv directories from DIR upward, nearest first.
DIR does not need to exist, so new files resolve too."
  (let ((dir (my/python-env--normalize dir)))
    (my/python-env--cached
     dir 'venvs
     (lambda ()
       (let ((current dir)
             venvs)
         (while current
           (dolist (name my/python-env-venv-names)
             (let ((venv (expand-file-name name current)))
               (when (file-exists-p (expand-file-name "pyvenv.cfg" venv))
                 (push (file-name-as-directory venv) venvs))))
           (let ((parent (file-name-directory (directory-file-name current))))
             (setq current (unless (equal parent current) parent))))
         (nreverse venvs))))))

(defun my/python-env-venv (dir)
  "Return the nearest venv directory for DIR, or nil."
  (car (my/python-env--venvs dir)))

(defun my/python-env-tool (dir tool)
  "Return the executable for TOOL that applies to DIR, or nil.
Use the nearest venv that provides TOOL, then `my/python-env-fallback-bin',
then `exec-path'."
  (let ((dir (my/python-env--normalize dir)))
    (my/python-env--cached
     dir tool
     (lambda ()
       (or (seq-some (lambda (venv)
                       (my/python-env--executable
                        (expand-file-name tool (expand-file-name "bin" venv))))
                     (my/python-env--venvs dir))
           (my/python-env--executable
            (expand-file-name tool my/python-env-fallback-bin))
           (executable-find tool))))))

(defun my/python-env--file-dir ()
  "Return the directory of the local file that the current buffer visits.
Return nil for special buffers and remote files."
  (when (and buffer-file-name
             (not (file-remote-p buffer-file-name)))
    (file-name-directory buffer-file-name)))

(defun my/python-env--pylsp ()
  "Return the pylsp executable, or nil."
  (or (my/python-env--executable
       (expand-file-name "pylsp" my/python-env-fallback-bin))
      (executable-find "pylsp")))

(defun my/python-env--ruff ()
  "Return the Ruff executable for the current buffer's file, or nil."
  (when-let* ((dir (my/python-env--file-dir)))
    (my/python-env-tool dir "ruff")))

;;;; Ruff through Flymake

(defvar-local my/python-env--ruff-process nil
  "The Ruff process of the latest Flymake check in this buffer.")

(defun my/python-env--ruff-position (location)
  "Return the buffer position of a Ruff LOCATION.
LOCATION is an alist with a 1-based `row' and `column'.  Ruff counts
columns in characters, the same as Emacs."
  (save-excursion
    (goto-char (point-min))
    (forward-line (1- (alist-get 'row location)))
    (min (+ (point) (alist-get 'column location) -1)
         (line-end-position))))

(defun my/python-env--ruff-diagnostic (check)
  "Return a Flymake diagnostic for CHECK, an item of Ruff's JSON output.
Call this function in the source buffer, without narrowing."
  (let-alist check
    (let ((beg (my/python-env--ruff-position .location))
          (end (my/python-env--ruff-position .end_location)))
      ;; Ruff gives some diagnostics an empty range, for example a missing
      ;; newline at the end of the file.
      (unless (< beg end)
        (when-let* ((region (flymake-diag-region
                             (current-buffer) .location.row .location.column)))
          (setq beg (car region)
                end (cdr region))))
      (flymake-make-diagnostic
       (current-buffer) beg end
       ;; The same severities as python-lsp-ruff.
       (if (or (null .code)
               (equal .code "invalid-syntax")
               (string-prefix-p "F" .code))
           :error
         :warning)
       (list "ruff" .code .message)))))

(defun my/python-env--ruff-report (process report-fn)
  "Send the result of the finished Ruff PROCESS to Flymake's REPORT-FN.
Call this function in the source buffer."
  (let* ((output (with-current-buffer (process-buffer process)
                   (buffer-string)))
         ;; A vector, so that an empty result is not nil.
         (checks (and (zerop (process-exit-status process))
                      (ignore-error json-parse-error
                        (json-parse-string output
                                           :object-type 'alist
                                           :null-object nil)))))
    (save-restriction
      (widen)
      (funcall report-fn
               (if checks
                   (mapcar #'my/python-env--ruff-diagnostic checks)
                 ;; Ruff failed, for example on an invalid config.  Show its
                 ;; message on the first line.  The next check after the fix
                 ;; removes it.
                 (list (flymake-make-diagnostic
                        (current-buffer)
                        (point-min)
                        (save-excursion
                          (goto-char (point-min))
                          (line-end-position))
                        :error
                        (list "ruff" nil (string-trim output)))))))))

(defun my/python-env-ruff-flymake (report-fn &rest _args)
  "Check the current buffer with Ruff, and send the result to REPORT-FN.
Ruff reads the buffer from stdin.  `--stdin-filename' gives Ruff the path
of the buffer's file, so Ruff uses the config that applies to that file."
  (let ((ruff (or (my/python-env--ruff)
                  (error "Cannot find ruff")))
        (source (current-buffer)))
    (when (process-live-p my/python-env--ruff-process)
      (kill-process my/python-env--ruff-process))
    (setq my/python-env--ruff-process
          (make-process
           :name "ruff-flymake"
           :buffer (generate-new-buffer " *ruff-flymake*")
           :command (list ruff "check"
                          "--output-format" "json"
                          "--exit-zero" "--no-fix" "--no-cache"
                          "--force-exclude" "--quiet"
                          "--extend-select" "I"
                          "--stdin-filename" buffer-file-name
                          "-")
           :connection-type 'pipe
           :noquery t
           :sentinel
           (lambda (process _event)
             (unless (process-live-p process)
               (unwind-protect
                   ;; Skip the result of a check that a newer check replaced.
                   (when (and (buffer-live-p source)
                              (eq process (buffer-local-value
                                           'my/python-env--ruff-process
                                           source)))
                     (with-current-buffer source
                       (my/python-env--ruff-report process report-fn)))
                 (kill-buffer (process-buffer process)))))))
    (save-restriction
      (widen)
      (process-send-region my/python-env--ruff-process (point-min) (point-max)))
    (process-send-eof my/python-env--ruff-process)))

(defun my/python-env--add-ruff-flymake ()
  "Add the Ruff backend to Flymake in a local Python file that Eglot manages.
Eglot replaces `flymake-diagnostic-functions' when it starts to manage
a buffer, so this function runs from `eglot-managed-mode-hook'."
  (when (and (eglot-managed-p)
             (derived-mode-p 'python-base-mode)
             (my/python-env--file-dir))
    (add-hook 'flymake-diagnostic-functions #'my/python-env-ruff-flymake nil t)
    ;; Eglot connects in the background, and then Flymake can start its first
    ;; check before this hook adds Ruff.
    (when (bound-and-true-p flymake-mode)
      (flymake-start t))))

;;;; Ruff through Apheleia

(defconst my/python-env-apheleia-formatters
  '((my/python-env-ruff-isort
     . ((or (my/python-env--ruff) "ruff")
        "check" "--select" "I" "--fix-only"
        "--no-cache" "--force-exclude"
        "--stdin-filename" filepath "-"))
    (my/python-env-ruff-format
     . ((or (my/python-env--ruff) "ruff")
        "format"
        "--no-cache" "--force-exclude"
        "--stdin-filename" filepath "-")))
  "Apheleia formatters that run the Ruff for the buffer's file.
Apheleia evaluates the first element of each command in the buffer.
Neither command sets `--line-length', so `fill-column' has no effect.
Apheleia reads only stdout, and it logs stderr when a command fails.")

(defun my/python-env-apheleia-setup ()
  "Make Apheleia sort the imports with Ruff, then format with Ruff."
  (dolist (formatter my/python-env-apheleia-formatters)
    (setf (alist-get (car formatter) apheleia-formatters) (cdr formatter)))
  (dolist (mode '(python-mode python-ts-mode))
    (setf (alist-get mode apheleia-mode-alist)
          '(my/python-env-ruff-isort my/python-env-ruff-format))))

;;;; Eglot integration

(cl-defmethod project-root ((project (head my/python-env)))
  (cdr project))

(defun my/python-env-project-find (dir)
  "Return an Eglot project rooted at the directory of DIR's nearest venv.
Apply only while Eglot looks up a project for a local Python file, so
other `project.el' commands keep the normal VC project."
  (when (and (bound-and-true-p eglot-lsp-context)
             (derived-mode-p 'python-base-mode)
             (my/python-env--file-dir))
    (when-let* ((venv (my/python-env-venv dir)))
      (cons 'my/python-env (file-name-directory (directory-file-name venv))))))

(defun my/python-env-workspace-configuration (_server)
  "Return pylsp settings for the server root in `default-directory'.
Eglot binds `default-directory' to the server's project root before it
calls this function."
  (let* ((dir default-directory)
         (venv (my/python-env-venv dir))
         (mypy (my/python-env-tool dir "mypy"))
         (off '(:enabled :json-false)))
    `(:pylsp
      (:plugins
       (,@(when venv
            ;; Without a venv, Jedi uses the pylsp tool environment.
            `(:jedi (:environment ,(directory-file-name venv))))
        ;; Flymake and Apheleia run Ruff for each buffer instead.
        :ruff ,off
        ;; Check on save only: live mode writes a shadow file on each change.
        ;; Match mypy's default `follow-imports' instead of pylsp-mypy's
        ;; `silent'.  mypy stores its options in `.mypy_cache', so a mismatch
        ;; makes CLI runs and editor runs invalidate each other's cache.
        ;;
        ;; Without dmypy, `hover' runs no mypy.  It selects a Jedi hover that
        ;; starts with the class of the value at point.  See the README for
        ;; why dmypy is off.
        :pylsp_mypy ,(if mypy
                         `(:enabled t
                                    :live_mode :json-false
                                    :dmypy :json-false
                                    :hover t
                                    :follow-imports "normal"
                                    :report_progress t
                                    :mypy_command ,(vector mypy))
                       off)
        ;; Ruff covers these providers.  Keeping them off avoids duplicate
        ;; diagnostics and formatters.
        :pylint ,off
        :flake8 ,off
        :pyflakes ,off
        :pycodestyle ,off
        :mccabe ,off
        :pydocstyle ,off
        :isort ,off
        :autopep8 ,off
        :yapf ,off)))))

(defun my/python-env-server-contact (_interactive)
  "Return the command that starts pylsp for Eglot."
  (let ((pylsp (my/python-env--pylsp)))
    (unless pylsp
      (user-error "Cannot find pylsp; run `uv tool install python-lsp-server'"))
    ;; pylsp-mypy honors `mypy_command' only with this variable set.  The
    ;; variable also lets a project's [tool.pylsp-mypy] table choose the
    ;; command.  That adds little risk here, because the venv's own ruff and
    ;; mypy already run from the project.  Open only trusted projects.
    (list "env" "PYLSP_MYPY_ALLOW_DANGEROUS_CODE_EXECUTION=1" pylsp)))

(defun my/python-env-setup ()
  "Install the per-venv project, settings, and server command for Eglot."
  ;; Run before `project-try-vc', which would otherwise claim the buffer.
  (add-hook 'project-find-functions #'my/python-env-project-find -90)
  (setq-default eglot-workspace-configuration
                #'my/python-env-workspace-configuration)
  (add-to-list 'eglot-server-programs
               '((python-mode python-ts-mode) . my/python-env-server-contact))
  (add-hook 'eglot-managed-mode-hook #'my/python-env--add-ruff-flymake))

;;;; Commands

(defun my/python-eglot-ensure ()
  "Start Eglot for the current buffer when it visits a local file."
  (interactive)
  (when (my/python-env--file-dir)
    (eglot-ensure)))

(defun my/python-env--clear-cache ()
  "Forget all resolved venvs and tools."
  (clrhash my/python-env--cache))

(defun my/python-env-reload ()
  "Clear the cache and restart Eglot for all Python file buffers.
A buffer can move to a different server root, so this command shuts the
servers down instead of reconnecting them.  Buffers other than the current
one reconnect the next time you use them."
  (interactive)
  (my/python-env--clear-cache)
  (let (buffers servers)
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (when (and (derived-mode-p 'python-base-mode)
                   (my/python-env--file-dir))
          (push buffer buffers)
          (when-let* ((server (and (fboundp 'eglot-current-server)
                                   (eglot-current-server))))
            (unless (memq server servers)
              (push server servers))))))
    (dolist (server servers)
      (eglot-shutdown server))
    (dolist (buffer buffers)
      (with-current-buffer buffer
        (my/python-eglot-ensure)))
    (message "Restarted %d pylsp server(s) for %d buffer(s)"
             (length servers) (length buffers))))

(defun my/python-env-describe ()
  "Show the venv, tools, and Eglot root for the current buffer."
  (interactive)
  (let* ((dir (or (my/python-env--file-dir)
                  (user-error "This buffer does not visit a local file")))
         (root (let ((eglot-lsp-context t))
                 (when-let* ((project (project-current nil dir)))
                   (project-root project)))))
    (message "venv: %s\nruff: %s\nmypy: %s\npylsp: %s\nEglot root: %s"
             (or (my/python-env-venv dir) "none")
             (or (my/python-env-tool dir "ruff") "none")
             (or (my/python-env-tool dir "mypy") "none")
             (or (my/python-env--pylsp) "none")
             (or root default-directory))))

(provide 'my-python-env)

;;; my-python-env.el ends here
