;;; my-python-env.el --- Per-directory Python tool resolution for Eglot -*- lexical-binding: t; -*-

;;; Commentary:
;; Choose the Python tools for each file-visiting Python buffer from the
;; venvs above it on the filesystem:
;;
;; - pyrefly (the language server) comes from the nearest venv that provides
;;   `bin/pyrefly'.
;; - Ruff comes from the nearest venv that provides `bin/ruff'.
;;
;; Each lookup falls back to `exec-path', where `uv tool install' links
;; each tool.
;;
;; Eglot starts one pyrefly server for each directory that holds a venv with
;; pyrefly.  pyrefly finds the config and the interpreter for each file
;; itself.  Only Eglot sees these projects; the normal VC project still
;; applies to `project.el' commands.
;;
;; Ruff runs outside pyrefly: a Flymake backend lints the buffer, and Apheleia
;; formatters sort the imports and format the buffer on save.  Each Ruff run
;; looks up the tool from the directory of the buffer's file.
;;
;; After you create or delete a venv, run `my/python-env-reload'.
;;
;; See README.md in this directory for the design, config behavior, and
;; caveats.

;;; Code:

(require 'eglot)
(require 'flymake)
(require 'project)
(require 'seq)

(defvar apheleia-formatters)
(defvar apheleia-mode-alist)

(defgroup my/python-env nil
  "Per-directory Python tool resolution for Eglot."
  :group 'tools)

(defcustom my/python-env-venv-names '(".venv" "venv")
  "Directory names to check for a venv, in order of preference.
A candidate counts as a venv only when it contains `pyvenv.cfg'."
  :type '(repeat string))

(defcustom my/python-env-pyrefly-arguments '("--workspace-indexing-limit" "0")
  "Arguments for `pyrefly lsp'.
By default, pyrefly indexes up to 2000 files of the workspace, in
addition to the files of each config that it loads.  The workspace is
the Eglot root, which in ds-monorepo is the whole worktree.  There, that
index used 2.5 GB of memory, and the server used 150 MB without it."
  :type '(repeat string))

(defcustom my/python-env-pyrefly-ignored-codes '("unused-import" "unused-variable")
  "Codes of the pyrefly diagnostics that Eglot does not show.
Ruff reports the same problems as F401 and F841.  pyrefly sends these
diagnostics as hints in the editor only, and its config cannot turn
them off."
  :type '(repeat string))

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

(defun my/python-env--venv-tool (venv tool)
  "Return the executable for TOOL in VENV, or nil."
  (my/python-env--executable
   (expand-file-name tool (expand-file-name "bin" venv))))

(defun my/python-env--tool-venv (dir tool)
  "Return the nearest venv directory for DIR that provides TOOL, or nil."
  (seq-find (lambda (venv) (my/python-env--venv-tool venv tool))
            (my/python-env--venvs dir)))

(defun my/python-env-tool (dir tool)
  "Return the executable for TOOL that applies to DIR, or nil.
Use the nearest venv that provides TOOL, then `exec-path'."
  (let ((dir (my/python-env--normalize dir)))
    (my/python-env--cached
     dir tool
     (lambda ()
       (or (when-let* ((venv (my/python-env--tool-venv dir tool)))
             (my/python-env--venv-tool venv tool))
           (executable-find tool))))))

(defun my/python-env--file-dir ()
  "Return the directory of the local file that the current buffer visits.
Return nil for special buffers and remote files."
  (when (and buffer-file-name
             (not (file-remote-p buffer-file-name)))
    (file-name-directory buffer-file-name)))

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
       ;; Ruff's JSON output has no severity.  Pyflakes rules find likely
       ;; bugs, and most other rules are about style.
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

(cl-defmethod project-files ((project (head my/python-env)) &optional dirs)
  "List the files of PROJECT in DIRS that version control does not ignore.
Eglot watches the directories of these files for pyrefly.  The generic
method also lists the files in each venv, and in ds-monorepo it walked
about 127,000 directories."
  (if-let* ((root (project-root project))
            (vc (project-try-vc root)))
      (project-files vc (or dirs (list root)))
    (cl-call-next-method)))

(defun my/python-env-project-find (dir)
  "Return an Eglot project rooted at the directory of DIR's pyrefly venv.
That venv is the nearest venv above DIR that provides `bin/pyrefly'.
Apply only while Eglot looks up a project for a local Python file, so
other `project.el' commands keep the normal VC project."
  (when (and (bound-and-true-p eglot-lsp-context)
             (derived-mode-p 'python-base-mode)
             (my/python-env--file-dir))
    (when-let* ((venv (my/python-env--tool-venv dir "pyrefly")))
      (cons 'my/python-env (file-name-directory (directory-file-name venv))))))

(defclass my/python-env-pyrefly-server (eglot-lsp-server) ()
  :documentation "An Eglot connection to pyrefly.")

(cl-defmethod eglot-handle-notification :around
  ((server my/python-env-pyrefly-server)
   (method (eql textDocument/publishDiagnostics))
   &rest args &key diagnostics &allow-other-keys)
  "Drop the DIAGNOSTICS that `my/python-env-pyrefly-ignored-codes' lists."
  ;; The first :diagnostics in a plist wins.
  (apply #'cl-call-next-method server method
         :diagnostics (cl-remove-if
                       (lambda (diagnostic)
                         (member (plist-get diagnostic :code)
                                 my/python-env-pyrefly-ignored-codes))
                       diagnostics)
         args))

(defun my/python-env-server-contact (_interactive project)
  "Return the server class and the command that start pyrefly in PROJECT.
A lookup from the project root finds the same pyrefly as a lookup from
each file under it: no venv between a file and the root provides
pyrefly, or `my/python-env-project-find' would choose that venv."
  (let ((root (project-root project)))
    `(my/python-env-pyrefly-server
      ,(or (my/python-env-tool root "pyrefly")
           (user-error "Cannot find pyrefly for %s" root))
      "lsp" ,@my/python-env-pyrefly-arguments)))

(defun my/python-env-setup ()
  "Install the per-venv project and the server command for Eglot."
  ;; Run before `project-try-vc', which would otherwise claim the buffer.
  (add-hook 'project-find-functions #'my/python-env-project-find -90)
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
    (message "Restarted %d pyrefly server(s) for %d buffer(s)"
             (length servers) (length buffers))))

(defun my/python-env-describe ()
  "Show the tools and Eglot root for the current buffer."
  (interactive)
  (let* ((dir (or (my/python-env--file-dir)
                  (user-error "This buffer does not visit a local file")))
         (root (let ((eglot-lsp-context t))
                 (when-let* ((project (project-current nil dir)))
                   (project-root project)))))
    (message "pyrefly: %s\nruff: %s\nEglot root: %s"
             (or (my/python-env-tool dir "pyrefly") "none")
             (or (my/python-env-tool dir "ruff") "none")
             (or root default-directory))))

(provide 'my-python-env)

;;; my-python-env.el ends here
