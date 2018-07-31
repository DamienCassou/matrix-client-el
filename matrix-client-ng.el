;;; matrix-client-ng.el --- summary ---  -*- lexical-binding: t; -*-

;;; Commentary:

;; Commentary.

;;; Code:

;; ARGH EMACS 26 WHY
(unless (fboundp 'if-let)
  (defalias 'if-let 'if-let*)
  (defalias 'when-let 'when-let*))

;;;; Requirements

(require 'cl-lib)
(require 'calendar)

(require 'f)
(require 'ov)
(require 'tracking)

(require 'matrix-api-r0.3.0)
(require 'matrix-client-faces)
(require 'matrix-client-room)
(require 'matrix-notifications)
(require 'matrix-client-images)

;;;; TEMP

(cl-defun matrix-client-notify-m.room.message (event &key room &allow-other-keys)
  "Show notification for m.room.message events.
EVENT should be the `event' variable from the
`defmatrix-client-handler'.  ROOM should be the room object."
  (pcase-let* (((map content sender event_id) event)
               ((map body) content)
               ((eieio extra) room)
               ((eieio buffer) extra)
               (display-name (matrix-user-displayname room sender))
               (id (notifications-notify :title (format$ "<b>$display-name</b>")
                                         ;; Encode the message as ASCII because dbus-notify
                                         ;; can't handle some Unicode chars.  And
                                         ;; `ignore-errors' doesn't work to ignore errors
                                         ;; from it.  Don't ask me why.
                                         :body (encode-coding-string body 'us-ascii)
                                         :category "im.received"
                                         :timeout 5000
                                         :app-icon nil
                                         :actions '("default" "Show")
                                         :on-action #'matrix-client-notification-show)))
    (map-put matrix-client-notifications id (a-list 'buffer buffer
                                                    'event_id event_id))
    ;; Trim the list
    (setq matrix-client-notifications (-take 20 matrix-client-notifications))))

;;;; Variables

(defvar matrix-client-ng-sessions nil
  "List of active sessions.")

(defvar matrix-client-ng-show-images
  ;; FIXME: Copy defcustom.
  nil)

(defvar matrix-client-ng-mark-modified-rooms t)

(defvar matrix-client-ng-input-prompt "▶ ")

(defcustom matrix-client-ng-render-presence t
  "Show presence changes in the main buffer windows."
  :type 'boolean)

(defcustom matrix-client-ng-render-membership t
  "Show membership changes in the main buffer windows."
  :type 'boolean)

(defcustom matrix-client-ng-render-html (featurep 'shr)
  "Render HTML messages in buffers. These are currently the
ad-hoc 'org.matrix.custom.html' messages that Vector emits."
  :type 'boolean)

(defcustom matrix-client-ng-save-token nil
  "Save username and access token upon successful login."
  :type 'boolean)

(defcustom matrix-client-ng-save-token-file "~/.cache/matrix-client.el.token"
  "Save username and access token to this file."
  :type 'file)

(defcustom matrix-client-use-tracking nil
  "Enable tracking.el support in matrix-client."
  :type 'boolean)

(defcustom matrix-client-save-outgoing-messages t
  "Save outgoing messages in kill ring before sending.
This way, in the event that a message gets lost in transit, the
user can recover it from the kill ring instead of retyping it."
  :type 'boolean)



;;;; Macros

(defmacro with-room-buffer (room &rest body)
  (declare (debug (sexp body)) (indent defun))
  `(with-slots* (((extra id) room)
                 ((buffer) extra))
     (unless buffer
       ;; Make buffer if necessary.  This seems like the easiest way
       ;; to guarantee that the room has a buffer, since it seems
       ;; unclear what the first received event type for a joined room
       ;; will be.
       (setq buffer (get-buffer-create (matrix-client-ng-display-name room)))
       (matrix-client-ng-setup-room-buffer room))
     (with-current-buffer buffer
       ,@body)))

(cl-defmacro matrix-client-ng-defevent (type docstring &key object-slots event-keys content-keys let body)
  "Define a method on `matrix-room' to handle Matrix events of TYPE.

TYPE should be a symbol representing the event type,
e.g. `m.room.message'.

DOCSTRING should be a docstring for the method.

OBJECT-SLOTS should be a list of lists, each in the form (OBJECT
SLOT ...), which will be turned into a `with-slots*' form
surrounding the following `pcase-let*' and BODY.  (This form
seems more natural than the (SLOTS OBJECT) form used by
`with-slots'.)

The following are bound in order in `pcase-let*':

EVENT-KEYS should be a list of symbols in the EVENT alist which
are bound with `pcase-let*' around the body.  These keys are
automatically bound: `content', `event_id', `sender',
`origin_server_ts', `type', and `unsigned'.

CONTENT-KEYS should be a list of symbols in the EVENTs `content'
key, which are bound in the `pcase-let*' around the body.

LET should be a varlist which is bound in the `pcase-let*' around
the body.

BODY will finally be evaluated in the context of these slots and
variables.

It is hoped that using this macro is easier than defining a large
method without it."
  ;; FIXME: It would probably be better to use the same form for OBJECT-SLOTS that is used by
  ;; `pcase-let*', because having two different ways is too confusing.
  (declare (indent defun))
  (let ((method-name (intern (concat "matrix-client-event-" (symbol-name type))))
        (slots (cl-loop for (object . slots) in object-slots
                        collect (list slots object))))
    `(cl-defmethod ,method-name ((room matrix-room) event)
       ,docstring
       (declare (indent defun))
       (with-slots* ,slots
         (pcase-let* (((map content event_id sender origin_server_ts type unsigned ,@event-keys) event)
                      ((map ,@content-keys) content)
                      ,@let)
           ,body)))))

;;;; Classes

(matrix-defclass matrix-room-extra ()
  ((buffer :initarg :buffer))
  "Extra data stored in room objects.")

;;;; Mode

(define-derived-mode matrix-client-ng-mode fundamental-mode "Matrix"
  "Mode for Matrix room buffers."
  :group 'matrix-client-ng
  ;; TODO: Add a new abbrev table that uses usernames, rooms, etc.
  :keymap matrix-client-ng-mode-map)

;;;;; Keys

(define-key matrix-client-ng-mode-map (kbd "RET") 'matrix-client-ng-send-input)
(define-key matrix-client-ng-mode-map (kbd "DEL") 'matrix-client-ng-delete-backward-char)

;;;; Connect / disconnect

;;;###autoload
(defun matrix-client-ng-connect (&optional user password access-token server)
  "Matrix Client NG"
  (interactive)
  (if matrix-client-ng-sessions
      ;; TODO: Already have active session: display list of buffers
      ;; FIXME: If login fails, it still shows as active.
      (message "Already active")
    ;; No existing session
    (if-let ((enabled matrix-client-ng-save-token)
             (saved (matrix-client-ng-load-token)))
        ;; Use saved token
        ;; FIXME: Change "username" to "user" when we no longer need compatibility with old code
        (setq user (a-get saved 'username)
              server (a-get saved 'server)
              access-token (a-get saved 'token)
              txn-id (a-get saved 'txn-id))
      ;; Not saved: prompt for username and password
      (setq user (or user (read-string "User ID: "))
            password (or password (read-passwd "Password: "))
            server (or server
                       (--> (read-passwd "Server (leave blank to derive from user ID): ")
                            (if (string-empty-p it)
                                nil
                              it)))))
    (if access-token
        ;; Use saved token and call post-login hook
        (matrix-client-ng-login-hook (matrix-session :user user
                                                     :server server
                                                     :access-token access-token
                                                     :txn-id txn-id
                                                     :initial-sync-p t))
      ;; Log in with username and password
      (matrix-login (matrix-session :user user
                                    :server server
                                    :initial-sync-p t)
                    password))))

(cl-defmethod matrix-client-ng-login-hook ((session matrix-session))
  "Callback for successful login.
Add session to sessions list and run initial sync."
  (push session matrix-client-ng-sessions)
  (matrix-sync session)
  (when matrix-client-ng-save-token
    (matrix-client-ng-save-token session))
  (message "Jacked in to %s.  Syncing..." (oref session server)))

(add-hook 'matrix-login-hook #'matrix-client-ng-login-hook)

(cl-defmethod matrix-client-ng-save-token ((session matrix-session))
  "Save username and access token for session SESSION to file."
  ;; FIXME: This does not work with multiple sessions.
  ;; MAYBE: Could we use `savehist-additional-variables' instead of our own code for this?
  ;; TODO: Check if file exists; if so, ensure it has a proper header so we know it's ours.
  (with-temp-file matrix-client-ng-save-token-file
    (with-slots (user server access-token txn-id) session
      ;; FIXME: Change "username" to "user" when we no longer need compatibility with old code
      ;; FIXME: Change token to access-token for clarity.
      (prin1 (a-list 'username user
                     'server server
                     'token access-token
                     'txn-id txn-id)
             (current-buffer))))
  ;; Ensure permissions are safe
  (chmod matrix-client-ng-save-token-file #o600))

(defun matrix-client-ng-load-token ()
  "Return saved username and access token from file."
  (when (f-exists? matrix-client-ng-save-token-file)
    (read (f-read matrix-client-ng-save-token-file))))

(defun matrix-client-ng-disconnect (&optional logout)
  "Unplug from the Matrix.
If LOGOUT is non-nil, actually log out, canceling access
tokens (username and password will be required again)."
  (interactive "P")
  (cond (logout (seq-do #'matrix-logout matrix-client-ng-sessions)
                ;; Remove saved token
                (f-delete matrix-client-ng-save-token-file))
        ;; FIXME: This does not work for multiple sessions.
        (t (matrix-client-ng-save-token (car matrix-client-ng-sessions))))
  (--each matrix-client-ng-sessions
    ;; Kill pending sync response buffer processes
    (with-slots (pending-syncs disconnect) it
      (setq disconnect t)
      (ignore-errors
        ;; Ignore errors in case of "Attempt to get process for a dead buffer"
        (seq-do #'delete-process pending-syncs)))
    ;; Kill buffers
    (with-slots (rooms) it
      (--each rooms
        (kill-buffer (oref* it extra buffer))))
    ;; Try to GC the session object.  Hopefully no timers or processes or buffers still hold a ref...
    (setf it nil))
  (setq matrix-client-ng-sessions nil))

;;;; Rooms

;;;;; Timeline

(cl-defmethod matrix-client-ng-timeline ((room matrix-room) event)
  "Process EVENT in ROOM."
  (pcase-let* (((map type) event))
    (apply-if-fn (concat "matrix-client-event-" (symbol-name type))
        (list room event)
      (matrix-unimplemented (format$ "Unimplemented client method: $fn-name")))))

;;;; Helper functions

(defun matrix-client-ng-event-timestamp (data)
  "Return timestamp of event DATA."
  (let ((server-ts (float (a-get* data 'origin_server_ts)))
        (event-age (float (or (a-get* data 'unsigned 'age)
                              0))))
    ;; The timestamp and the age are in milliseconds.  We need
    ;; millisecond precision in case of two messages sent/received
    ;; within one second, but we need to return seconds, not
    ;; milliseconds.  So we divide by 1000 to get the timestamp in
    ;; seconds, but we keep millisecond resolution by using floats.
    (/ (- server-ts event-age) 1000)))

(defun matrix-client-ng-linkify-urls (text)
  "Return TEXT with URLs in it made clickable."
  (with-temp-buffer
    (insert text)
    (goto-char (point-min))
    (cl-loop while (re-search-forward (rx bow "http" (optional "s") "://" (1+ (not space))) nil 'noerror)
             do (make-text-button (match-beginning 0) (match-end 0)
                                  'mouse-face 'highlight
                                  'face 'link
                                  'help-echo (match-string 0)
                                  'action #'browse-url-at-mouse
                                  'follow-link t))
    (buffer-string)))

(defun matrix-client-ng-buffer-visible-p (&optional buffer)
  "Return non-nil if BUFFER is currently visible.
If BUFFER is nil, use the current buffer."
  (let ((buffer (or buffer (current-buffer))))
    (or (eq buffer (window-buffer (selected-window)))
        (get-buffer-window buffer))))

(defun matrix--calendar-absolute-to-timestamp (absolute)
  "Convert ABSOLUTE day number to Unix timestamp.
Does not account for leap seconds.  ABSOLUTE should be the number
of days since 0000-12-31, e.g. as returned by
`calendar-absolute-from-gregorian'."
  ;; NOTE: This function should come with Emacs!
  (let* ((gregorian (calendar-gregorian-from-absolute absolute))
         (days-between (1+ (days-between (format "%s-%02d-%02d 00:00" (cl-caddr gregorian) (car gregorian) (cadr gregorian))
                                         "1970-01-01 00:00")))
         (seconds-between (* 86400 days-between)))
    (string-to-number (format-time-string "%s" seconds-between))))

(defun matrix-client--human-format-date (date)
  "Return human-formatted DATE.
DATE should be either an integer timestamp, or a string in
\"YYYY-MM-DD HH:MM:SS\" format.  The \"HH:MM:SS\" part is
optional."
  ;; NOTE: This seems to be the only format that `days-between' (and `date-to-time') accept.  This
  ;; appears to be undocumented; it just says, "date-time strings" without specifying what KIND of
  ;; date-time strings, leaving you to assume it pl.  I only found this out by trial-and-error.
  (setq date (cl-typecase date
               (integer (format-time-string "%F" (seconds-to-time date)))
               (float (format-time-string "%F" (seconds-to-time date)))
               (list (format-time-string "%F" (seconds-to-time date)))
               (string date)))
  (unless (string-match (rx (= 2 digit) ":" (= 2 digit) eos) date)
    (setq date (concat date " 00:00")))
  (let* ((difference (days-between (format-time-string "%F %T") date)))
    (cond ((= 0 difference) "Today")
          ((= 1 difference) "Yesterday")
          ((< difference 7) (format-time-string "%A" (date-to-time date)))
          (t (format-time-string "%A, %B %d, %Y" (date-to-time date))))))

;;;; Footer

(provide 'matrix-client-ng)

;;; matrix-client-ng.el ends here
