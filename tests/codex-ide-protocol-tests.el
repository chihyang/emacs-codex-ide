;;; codex-ide-protocol-tests.el --- Tests for codex-ide protocol helpers -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused tests for app-server request construction and pagination.

;;; Code:

(require 'ert)
(require 'seq)
(require 'codex-ide-test-fixtures)
(require 'codex-ide)

(ert-deftest codex-ide-set-thread-name-sends-official-request ()
  (let ((request nil))
    (cl-letf (((symbol-function 'codex-ide--request-sync)
               (lambda (session method params)
                 (setq request (list session method params))
                 '((threadName . "New name")))))
      (should
       (equal (codex-ide--set-thread-name
               'query-session "thread-1" "New name")
              '((threadName . "New name"))))
      (should
       (equal request
              '(query-session
                "thread/name/set"
                ((threadId . "thread-1")
                 (name . "New name"))))))))

(ert-deftest codex-ide-set-thread-name-rejects-empty-values ()
  (should-error
   (codex-ide--set-thread-name 'query-session "" "New name")
   :type 'error)
  (should-error
   (codex-ide--set-thread-name 'query-session "thread-1" "")
   :type 'error))

(ert-deftest codex-ide-delete-thread-sends-official-request ()
  (let (request)
    (cl-letf (((symbol-function 'codex-ide--request-sync)
               (lambda (session method params)
                 (setq request (list session method params))
                 '())))
      (should-not (codex-ide--delete-thread 'query-session "thread-1"))
      (should
       (equal request
              '(query-session
                "thread/delete"
                ((threadId . "thread-1"))))))))

(ert-deftest codex-ide-delete-thread-rejects-empty-id ()
  (should-error (codex-ide--delete-thread 'query-session "") :type 'error))

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

(ert-deftest codex-ide-list-archived-threads-across-directories-paginates ()
  (let (requests)
    (cl-letf (((symbol-function 'codex-ide--request-sync)
               (lambda (_session method params)
                 (push (cons method params) requests)
                 (if (alist-get 'cursor params)
                     '((data . [((id . "archived-2"))]))
                   '((data . [((id . "archived-1"))])
                     (nextCursor . "next"))))))
      (should (equal (mapcar (lambda (thread) (alist-get 'id thread))
                             (codex-ide--list-threads-across-directories
                              'query-session :archived t))
                     '("archived-1" "archived-2")))
      (should (= (length requests) 2))
      (dolist (request requests)
        (should (equal (car request) "thread/list"))
        (should (eq (alist-get 'archived (cdr request)) t))))))

(ert-deftest codex-ide-list-child-threads-filters-by-parent-and-paginates ()
  (let ((project-dir (codex-ide-test--make-temp-project))
        (requests nil))
    (codex-ide-test-with-fixture project-dir
      (codex-ide-test-with-fake-processes
        (let ((session (codex-ide--create-process-session)))
          (cl-letf (((symbol-function 'codex-ide--request-sync)
                     (lambda (_session method params)
                       (push (cons method params) requests)
                       (if (alist-get 'cursor params)
                           '((data . [((id . "child-2"))]))
                         '((data . [((id . "child-1"))])
                           (nextCursor . "page-2"))))))
            (should
             (equal
              (codex-ide--list-child-threads
               session "parent-1" :limit 25)
              '(((id . "child-1"))
                ((id . "child-2")))))
            (should
             (equal
              (nreverse requests)
              '(("thread/list"
                 (parentThreadId . "parent-1")
                 (limit . 25)
                 (sortKey . "updated_at"))
                ("thread/list"
                 (parentThreadId . "parent-1")
                 (limit . 25)
                 (sortKey . "updated_at")
                 (cursor . "page-2")))))))))))

(provide 'codex-ide-protocol-tests)

;;; codex-ide-protocol-tests.el ends here
