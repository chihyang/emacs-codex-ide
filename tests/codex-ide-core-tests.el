;;; codex-ide-core-tests.el --- Tests for codex-ide-core -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused tests for core session and workspace primitives.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'codex-ide-core)

(ert-deftest codex-ide-get-working-directory-uses-default-directory ()
  (let* ((project-directory (make-temp-file "codex-ide-project-" t))
         (working-directory (expand-file-name "notes/example" project-directory))
         (default-directory (file-name-as-directory working-directory)))
    (unwind-protect
        (progn
          (make-directory working-directory t)
          (cl-letf (((symbol-function 'project-current)
                     (lambda (&rest _) 'project))
                    ((symbol-function 'project-root)
                     (lambda (_project) project-directory)))
            (should
             (equal (codex-ide--get-working-directory)
                    (codex-ide--normalize-directory working-directory)))))
      (delete-directory project-directory t))))

(provide 'codex-ide-core-tests)

;;; codex-ide-core-tests.el ends here
