;;; codex-ide-protocol-tests.el --- Tests for codex-ide protocol helpers -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused tests for app-server request construction and pagination.

;;; Code:

(require 'ert)
(require 'seq)
(require 'codex-ide-test-fixtures)
(require 'codex-ide)

(ert-deftest codex-ide-list-threads-across-directories-omits-cwd-and-paginates ()
  (let ((project-dir (codex-ide-test--make-temp-project))
        (requests nil))
    (codex-ide-test-with-fixture project-dir
      (codex-ide-test-with-fake-processes
        (let ((session (codex-ide--create-process-session)))
          (cl-letf (((symbol-function 'codex-ide--request-sync)
                     (lambda (_session method params)
                       (push (cons method params) requests)
                       (if (alist-get 'cursor params)
                           '((data . [((id . "thread-2"))]))
                         '((data . [((id . "thread-1"))])
                           (nextCursor . "page-2"))))))
            (should
             (equal
              (codex-ide--list-threads-across-directories
               session
               :limit 25)
              '(((id . "thread-1"))
                ((id . "thread-2")))))
            (setq requests (nreverse requests))
            (should
             (equal requests
                    '(("thread/list"
                       (limit . 25)
                       (sortKey . "updated_at"))
                      ("thread/list"
                       (limit . 25)
                       (sortKey . "updated_at")
                       (cursor . "page-2")))))
            (should-not
             (seq-some
              (lambda (request) (assq 'cwd (cdr request)))
              requests))))))))

(ert-deftest codex-ide-list-threads-across-directories-rejects-repeated-cursor ()
  (let ((project-dir (codex-ide-test--make-temp-project)))
    (codex-ide-test-with-fixture project-dir
      (codex-ide-test-with-fake-processes
        (let ((session (codex-ide--create-process-session)))
          (cl-letf (((symbol-function 'codex-ide--request-sync)
                     (lambda (&rest _)
                       '((data . []) (nextCursor . "same")))))
            (should-error
             (codex-ide--list-threads-across-directories session)
             :type 'error)))))))

(provide 'codex-ide-protocol-tests)

;;; codex-ide-protocol-tests.el ends here
