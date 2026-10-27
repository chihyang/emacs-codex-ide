;;; codex-ide-websocket.el --- Minimal WebSocket transport for codex-ide -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: Duncan Gillis

;;; Commentary:

;; This module implements the small RFC 6455 subset needed to speak to
;; `codex app-server proxy'.  It deliberately has no dependencies on other
;; codex-ide modules so the session and protocol layers can share it without
;; introducing dependency cycles.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defconst codex-ide-websocket--guid
  "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
  "RFC 6455 GUID used to validate the server handshake.")

(defun codex-ide-websocket-p (process)
  "Return non-nil when PROCESS is configured as a WebSocket transport."
  (process-get process 'codex-ide-websocket-state))

(defun codex-ide-websocket-error (process)
  "Return the WebSocket transport error recorded for PROCESS, if any."
  (process-get process 'codex-ide-websocket-error))

(defun codex-ide-websocket--random-bytes (length)
  "Return LENGTH random bytes as a unibyte string."
  (apply #'unibyte-string
         (cl-loop repeat length collect (random 256))))

(defun codex-ide-websocket--accept-value (key)
  "Return the expected WebSocket accept value for handshake KEY."
  (base64-encode-string
   (secure-hash 'sha1
                (concat key codex-ide-websocket--guid)
                nil nil t)
   t))

(defun codex-ide-websocket--uint-bytes (value width)
  "Encode nonnegative integer VALUE as WIDTH big-endian bytes."
  (apply #'unibyte-string
         (cl-loop for shift downfrom (* 8 (1- width)) to 0 by 8
                  collect (logand #xff (lsh value (- shift))))))

(defun codex-ide-websocket--read-uint (bytes start width)
  "Decode WIDTH big-endian bytes from BYTES at START."
  (let ((value 0))
    (dotimes (index width value)
      (setq value (+ (lsh value 8)
                     (aref bytes (+ start index)))))))

(defun codex-ide-websocket--mask-payload (payload mask)
  "Return PAYLOAD XOR-masked with the four-byte string MASK."
  (let* ((payload (string-as-unibyte payload))
         (length (length payload))
         (result (make-string length 0)))
    (dotimes (index length (string-as-unibyte result))
      (aset result
            index
            (logxor (aref payload index)
                    (aref mask (% index 4)))))))

(defun codex-ide-websocket--encode-frame (opcode payload &optional mask)
  "Encode PAYLOAD as a final WebSocket frame with OPCODE.
MASK must be a four-byte string and defaults to fresh random bytes."
  (let* ((payload (string-as-unibyte payload))
         (payload-length (length payload))
         (mask (or mask (codex-ide-websocket--random-bytes 4)))
         (length-header
          (cond
           ((<= payload-length 125)
            (unibyte-string (logior #x80 payload-length)))
           ((<= payload-length #xffff)
            (concat (unibyte-string (logior #x80 126))
                    (codex-ide-websocket--uint-bytes payload-length 2)))
           (t
            (concat (unibyte-string (logior #x80 127))
                    (codex-ide-websocket--uint-bytes payload-length 8))))))
    (concat (unibyte-string (logior #x80 opcode))
            length-header
            mask
            (codex-ide-websocket--mask-payload payload mask))))

(defun codex-ide-websocket--parse-frame (bytes)
  "Parse one WebSocket frame from unibyte string BYTES.
Return `(FRAME . REST)', where FRAME is a plist, or nil when incomplete."
  (setq bytes (string-as-unibyte bytes))
  (when (>= (length bytes) 2)
    (let* ((first (aref bytes 0))
           (second (aref bytes 1))
           (fin (not (zerop (logand first #x80))))
           (opcode (logand first #x0f))
           (masked (not (zerop (logand second #x80))))
           (short-length (logand second #x7f))
           (extended-width (cond ((= short-length 126) 2)
                                 ((= short-length 127) 8)
                                 (t 0)))
           (header-length (+ 2 extended-width (if masked 4 0))))
      (when (>= (length bytes) header-length)
        (let* ((payload-length
                (if (zerop extended-width)
                    short-length
                  (codex-ide-websocket--read-uint bytes 2 extended-width)))
               (mask-start (+ 2 extended-width))
               (payload-start (+ mask-start (if masked 4 0)))
               (frame-end (+ payload-start payload-length)))
          (when (>= (length bytes) frame-end)
            (let* ((payload (substring bytes payload-start frame-end))
                   (payload
                    (if masked
                        (codex-ide-websocket--mask-payload
                         payload
                         (substring bytes mask-start (+ mask-start 4)))
                      payload)))
              (cons (list :fin fin :opcode opcode :payload payload)
                    (substring bytes frame-end)))))))))

(defun codex-ide-websocket--send-frame (process opcode payload)
  "Send an OPCODE WebSocket frame containing PAYLOAD to PROCESS."
  (process-send-string
   process
   (codex-ide-websocket--encode-frame opcode payload)))

(defun codex-ide-websocket-send-text (process text)
  "Send TEXT through WebSocket PROCESS, queuing it during the handshake."
  (pcase (process-get process 'codex-ide-websocket-state)
    ('open
     (codex-ide-websocket--send-frame
      process 1 (encode-coding-string text 'utf-8 t)))
    ('handshake
     (process-put
      process
      'codex-ide-websocket-send-queue
      (append (process-get process 'codex-ide-websocket-send-queue)
              (list text))))
    (_
     (error "Codex daemon WebSocket is not connected%s"
            (if-let* ((detail (codex-ide-websocket-error process)))
                (format ": %s" detail)
              "")))))

(defun codex-ide-websocket--fail (process format-string &rest args)
  "Record a WebSocket error for PROCESS using FORMAT-STRING and ARGS."
  (let ((message (apply #'format format-string args)))
    (process-put process 'codex-ide-websocket-error message)
    (process-put process 'codex-ide-websocket-state 'failed)
    (when (process-live-p process)
      (delete-process process))))

(defun codex-ide-websocket--header-value (headers name)
  "Return header NAME from HTTP header string HEADERS."
  (let ((case-fold-search t))
    (when (string-match
           (format "\\(?:\\`\\|\r\n\\)%s:[ \t]*\\([^\r\n]+\\)"
                   (regexp-quote name))
           headers)
      (string-trim (match-string 1 headers)))))

(defun codex-ide-websocket--finish-handshake (process headers)
  "Validate HTTP response HEADERS and open WebSocket PROCESS."
  (let* ((key (process-get process 'codex-ide-websocket-key))
         (accept (codex-ide-websocket--header-value
                  headers "Sec-WebSocket-Accept")))
    (if (and (string-match-p "\\`HTTP/1\\.[01] 101\\(?: \\|\r\\|$\\)" headers)
             accept
             (string= accept (codex-ide-websocket--accept-value key)))
        (progn
          (process-put process 'codex-ide-websocket-state 'open)
          (let ((queued (process-get process 'codex-ide-websocket-send-queue)))
            (process-put process 'codex-ide-websocket-send-queue nil)
            (dolist (text queued)
              (codex-ide-websocket-send-text process text))))
      (codex-ide-websocket--fail
       process
       "WebSocket handshake failed: %s"
       (string-trim (car (split-string headers "\r\n" t)))))))

(defun codex-ide-websocket--deliver-data-frame (process frame)
  "Deliver a text or continuation FRAME received from PROCESS."
  (let ((opcode (plist-get frame :opcode))
        (payload (plist-get frame :payload))
        (fin (plist-get frame :fin)))
    (cond
     ((memq opcode '(1 2))
      (if fin
          (when-let* ((callback
                       (process-get process 'codex-ide-websocket-on-text)))
            (funcall callback
                     process
                     (decode-coding-string payload 'utf-8 t)))
        (process-put process 'codex-ide-websocket-fragment-opcode opcode)
        (process-put process 'codex-ide-websocket-fragment-data payload)))
     ((= opcode 0)
      (let ((prior (process-get process 'codex-ide-websocket-fragment-data)))
        (if (null prior)
            (codex-ide-websocket--fail
             process "Received an unexpected WebSocket continuation frame")
          (let ((combined (concat prior payload)))
            (if fin
                (progn
                  (process-put process 'codex-ide-websocket-fragment-opcode nil)
                  (process-put process 'codex-ide-websocket-fragment-data nil)
                  (when-let* ((callback
                               (process-get process
                                            'codex-ide-websocket-on-text)))
                    (funcall callback
                             process
                             (decode-coding-string combined 'utf-8 t))))
              (process-put process
                           'codex-ide-websocket-fragment-data
                           combined)))))))))

(defun codex-ide-websocket--handle-frame (process frame)
  "Handle one decoded WebSocket FRAME received from PROCESS."
  (pcase (plist-get frame :opcode)
    ((or 0 1 2)
     (codex-ide-websocket--deliver-data-frame process frame))
    (8
     (when (eq (process-get process 'codex-ide-websocket-state) 'open)
       (codex-ide-websocket--send-frame process 8 (plist-get frame :payload)))
     (process-put process 'codex-ide-websocket-state 'closed)
     (when (process-live-p process)
       (delete-process process)))
    (9
     (codex-ide-websocket--send-frame process 10 (plist-get frame :payload)))
    (10 nil)
    (_
     (codex-ide-websocket--fail
      process "Unsupported WebSocket opcode %s" (plist-get frame :opcode)))))

(defun codex-ide-websocket--consume-frames (process bytes)
  "Consume complete WebSocket frames for PROCESS from BYTES."
  (let ((remaining bytes)
        parsed)
    (while (setq parsed (codex-ide-websocket--parse-frame remaining))
      (setq remaining (cdr parsed))
      (codex-ide-websocket--handle-frame process (car parsed)))
    remaining))

(defun codex-ide-websocket-process-filter (process chunk)
  "Handle WebSocket bytes CHUNK received from PROCESS."
  (let ((pending (concat
                  (or (process-get process 'codex-ide-websocket-receive-buffer)
                      (string-as-unibyte ""))
                  (string-as-unibyte chunk))))
    (pcase (process-get process 'codex-ide-websocket-state)
      ('handshake
       (if-let* ((header-end (string-match "\r\n\r\n" pending)))
           (let ((after-headers (+ header-end 4)))
             (codex-ide-websocket--finish-handshake
              process
              (substring pending 0 after-headers))
             (setq pending
                   (if (eq (process-get process 'codex-ide-websocket-state) 'open)
                       (codex-ide-websocket--consume-frames
                        process
                        (substring pending after-headers))
                     (string-as-unibyte ""))))))
      ('open
       (setq pending (codex-ide-websocket--consume-frames process pending))))
    (process-put process 'codex-ide-websocket-receive-buffer pending)))

(defun codex-ide-websocket-configure (process on-text)
  "Configure PROCESS as a WebSocket and call ON-TEXT for complete messages."
  (let ((key (base64-encode-string
              (codex-ide-websocket--random-bytes 16)
              t)))
    (process-put process 'codex-ide-websocket-state 'handshake)
    (process-put process 'codex-ide-websocket-key key)
    (process-put process 'codex-ide-websocket-on-text on-text)
    (process-put process 'codex-ide-websocket-receive-buffer
                 (string-as-unibyte ""))
    (process-put process 'codex-ide-websocket-send-queue nil)
    (process-send-string
     process
     (format (concat "GET / HTTP/1.1\r\n"
                     "Host: localhost\r\n"
                     "Upgrade: websocket\r\n"
                     "Connection: Upgrade\r\n"
                     "Sec-WebSocket-Key: %s\r\n"
                     "Sec-WebSocket-Version: 13\r\n\r\n")
             key))))

(provide 'codex-ide-websocket)

;;; codex-ide-websocket.el ends here
