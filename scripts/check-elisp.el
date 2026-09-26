;;; check-elisp.el --- Verify Emacs Lisp syntax and indentation -*- lexical-binding: t; -*-

;;; Commentary:
;; Used by the local prek hook to validate changed Emacs Lisp files without
;; loading this configuration or writing compiled output.

;;; Code:

(require 'use-package-core)

(defun my/check-elisp-file (file)
  "Return non-nil when FILE has balanced delimiters and canonical indentation."
  (with-temp-buffer
    (insert-file-contents file)
    (emacs-lisp-mode)
    (let ((syntax-ok t))
      (condition-case err
          (check-parens)
        (error
         (setq syntax-ok nil)
         (message "%s: unmatched delimiter: %s" file
                  (error-message-string err))))
      (when syntax-ok
        (let ((contents (buffer-string)))
          (let ((inhibit-message t))
            (indent-region (point-min) (point-max)))
          (if (equal contents (buffer-string))
              t
            (message "%s: run `indent-region' to normalize indentation" file)
            nil))))))

(let ((failed nil))
  (dolist (file command-line-args-left)
    (condition-case err
        (unless (my/check-elisp-file file)
          (setq failed t))
      (error
       (setq failed t)
       (message "%s: could not check file: %s" file
                (error-message-string err)))))
  (when failed
    (kill-emacs 1)))

;;; check-elisp.el ends here
