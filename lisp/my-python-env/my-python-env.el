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
;; After you create or delete a venv, run `my/python-env-reload'.
;;
;; See README.md in this directory for the design, config behavior, and
;; caveats.

;;; Code:

(require 'project)
(require 'seq)

(defvar eglot-lsp-context)
(defvar eglot-server-programs)
(declare-function eglot-current-server "eglot")
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
         (ruff (my/python-env-tool dir "ruff"))
         (mypy (my/python-env-tool dir "mypy"))
         (off '(:enabled :json-false)))
    `(:pylsp
      (:plugins
       (,@(when venv
            ;; Without a venv, Jedi uses the pylsp tool environment.
            `(:jedi (:environment ,(directory-file-name venv))))
        :ruff ,(if ruff
                   `(:enabled t
                              :formatEnabled t
                              :executable ,ruff
                              ;; Let `eglot-format-buffer' apply Ruff's import
                              ;; sorter too.
                              :extendSelect ["I"]
                              :format ["I"])
                 off)
        ;; Check on save only: live mode writes a shadow file on each change.
        ;; Match mypy's default `follow-imports' instead of pylsp-mypy's
        ;; `silent'.  mypy stores its options in `.mypy_cache', so a mismatch
        ;; makes CLI runs and editor runs invalidate each other's cache.
        :pylsp_mypy ,(if mypy
                         `(:enabled t
                                    :live_mode :json-false
                                    :dmypy :json-false
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
               '((python-mode python-ts-mode) . my/python-env-server-contact)))

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
