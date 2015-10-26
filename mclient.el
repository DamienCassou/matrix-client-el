;;; mclient.el --- A minimal chat client for the Matrix.org RPC

;; Copyright (C) 2015 Ryan Rix
;; Author: Ryan Rix <ryan@whatthefuck.computer>
;; Maintainer: Ryan Rix <ryan@whatthefuck.computer>
;; Created: 21 June 2015
;; Keywords: web
;; Homepage: http://doc.rix.si/matrix.html
;; Package-Version: 0.1.0
;; Package-Requires: ((json) (request))

;; This file is not part of GNU Emacs.

;; mclient.el is free software: you can redistribute it and/or modify it
;; under the terms of the GNU General Public License as published by the Free
;; Software Foundation, either version 3 of the License, or (at your option) any
;; later version.
;;
;; mclient.el is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
;; FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more
;; details.
;;
;; You should have received a copy of the GNU General Public License along with
;; this file.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; `mclient' is a chat client and API library for the Matrix.org decentralized
;; RPC system.

;; Implementation-wise `mclient' itself provides most of the core plumbing for
;; an interactive Matrix chat client. It uses the Matrix event stream framework
;; to dispatch a global event stream to individual rooms. There are a set of
;; 'event handlers' and 'input filters' in `mclient-handlers' which are used to
;; implement the render flow of the various event types and actions a user can
;; take.

;;; Code:

(require 'matrix)
(require 'mclient-handlers)
(require 'mclient-modes)

;;;###autoload
(defcustom mclient-debug-events nil
  "When non-nil, log raw events to *matrix-events* buffer."
  :type 'boolean
  :group 'matrix-client)

;;;###autoload
(defcustom mclient-event-poll-timeout 30000
  "How long to wait for a Matrix event in the EventStream before timing out and trying again."
  :type 'number
  :group 'matrix-client)

(defvar mclient-new-event-hook nil
  "A lists of functions that are evaluated when a new event comes in.")

(defvar mclient-event-listener-running nil)

(defvar mclient-active-rooms nil
  "Rooms the active client is in.")

(defvar mclient-event-handlers '()
  "An alist of (type . function) handler definitions for various matrix types.

Each of these receives the raw event as a single DATA argument.
See `defmclient-handler'.")

(defvar-local mclient-room-name nil
  "The name of the buffer's room.")

(defvar-local mclient-room-topic nil
  "The topic of the buffer's room.")

(defvar-local mclient-room-id nil
  "The Matrix ID of the buffer's room.")

(defvar-local mclient-room-membership nil
  "The list of members of the buffer's room.")

(defvar-local mclient-room-typers nil
  "The list of members of the buffer's room who are currently typing.")

(defvar-local mclient-room-end-token nil
  "The most recent event-id in a room, used to push read-receipts to the server.")

(defvar mclient-render-presence t
  "Show presence changes in the main buffer windows.")

(defvar mclient-render-membership t
  "Show membership changes in the main buffer windows.")

;;;###autoload
(defcustom mclient-backfill-count 10
  "How many messages to backfill at a time when scrolling.")

;;;###autoload
(defcustom mclient-backfill-threshold 5
  "How close to the top of a buffer point needs to be before backfilling events.")

(defvar mclient-event-stream-end-token nil)

(defvar mclient-input-filters nil
  "List of functions to run input through.

Each of these functions take a single argument, the TEXT the user
inputs.  They can modify that text and return a new version of
it, or they can return nil to prevent further processing of it.")

;;;###autoload
(defun matrix-client ()
  "Connect to Matrix.

This will attempt to log you in if you don't have a valid
[`matrix-token'] and will create room buffers for each room you are
in."
  (interactive)
  (unless matrix-token
    (mclient-login))
  (mclient-inject-event-listeners)
  (mclient-handlers-init)
  (let* ((initial-data (matrix-initial-sync 25)))
    (mapc 'mclient-set-up-room (matrix-get 'rooms initial-data))
    (message "💣 You're jacked in, welcome to Matrix. (💗♥💓💕)")
    (setq mclient-event-listener-running t)
    (mclient-start-event-listener (matrix-get 'end initial-data))))

;;;###autoload
(defun mclient-login ()
  "Get a token form the Matrix homeserver.

If [`mclient-use-auth-source'] is non-nil, attempt to log in
using data from auth-source.  Otherwise, the user will be prompted
for a username and password."
  (interactive)
  (let* ((auth-source-creation-prompts
          '((username . "Matrix identity: ")
            (secret . "Matrix password for %u (homeserver: %h): ")))
         (found (nth 0 (auth-source-search :max 1
                                           :host matrix-homeserver-base-url
                                           :require '(:user :secret)
                                           :create t))))
    (when (and
           found
           (matrix-login-with-password (plist-get found :user)
                                       (let ((secret (plist-get found :secret)))
                                         (if (functionp secret)
                                             (funcall secret)
                                           secret)))
           (let ((save-func (plist-get found :save-function)))
             (when save-func (funcall save-func)))))))

(defun mclient-disconnect ()
  "Disconnect from Matrix and kill all active room buffers."
  (interactive)
  (dolist (room-cons mclient-active-rooms)
    (kill-buffer (cdr room-cons)))
  (setq mclient-active-rooms nil)
  (setq mclient-event-listener-running nil))

(defun mclient-reconnect (arg)
  "Reconnect to Matrix.

Without a `prefix-arg' ARG it will simply restart the
mclient-stream poller, but with a prefix it will disconnect and
connect, clearing all room data."
  (interactive "P")
  (if (or (not arg) mclient-event-stream-end-token)
      (progn
        (mclient-stream-from-end-token))
    (progn
      (mclient-disconnect)
      (matrix-client))))

(defun mclient-set-up-room (roomdata)
  "Set up a room from its initialSync ROOMDATA."
  (let* ((room-id (matrix-get 'room_id roomdata))
         (room-state (matrix-get 'state roomdata))
         (room-messages (matrix-get 'chunk (matrix-get 'messages roomdata)))
         (room-buf (get-buffer-create room-id))
         (room-cons (cons room-id room-buf))
         (render-membership mclient-render-membership)
         (render-presence mclient-render-presence))
    (setq mclient-render-membership nil)
    (setq mclient-render-presence nil)
    (add-to-list 'mclient-active-rooms room-cons)
    (with-current-buffer room-buf
      (matrix-client-mode)
      (erase-buffer)
      (mclient-render-message-line)
      (setq-local mclient-room-id room-id)
      (mapc 'mclient-render-event-to-room room-state)
      (mapc 'mclient-render-event-to-room room-messages))
    (setq mclient-render-membership render-membership)
    (setq mclient-render-presence render-presence)))

(defun mclient-window-change-hook ()
  "Send a read receipt if necessary."
  (when (and mclient-room-id mclient-room-end-token)
    (matrix-mark-as-read mclient-room-id mclient-room-end-token)))

(defun mclient-start-event-listener (end-tok)
  "Start the event listener if it is not already running, from the END-TOK end token."
  (when mclient-event-listener-running
    (matrix-event-poll
     end-tok
     mclient-event-poll-timeout
     'mclient-event-listener-callback)
    (setq mclient-event-stream-end-token end-tok)))

(defun mclient-event-listener-callback (data)
  "The callback which `matrix-event-poll' pushes its data in to.

This calls each function in mclient-new-event-hook with the data
object with a single argument, DATA."
  (unless (eq (car data) 'error)
    (dolist (hook mclient-new-event-hook)
      (funcall hook data)))
  (mclient-start-event-listener (matrix-get 'end data)))

(defun mclient-inject-event-listeners ()
  "Inject the standard event listeners."
  (add-to-list 'mclient-new-event-hook 'mclient-debug-event-maybe)
  (add-to-list 'mclient-new-event-hook 'mclient-render-events-to-room)
  (add-to-list 'mclient-new-event-hook 'mclient-set-room-end-token))

(defun mclient-debug-event-maybe (data)
  "Debug DATA to *matrix-events* if `mclient-debug-events' is non-nil."
  (with-current-buffer (get-buffer-create "*matrix-events*")
    (let ((inhibit-read-only t))
      (when mclient-debug-events
        (end-of-buffer)
        (insert "\n")
        (insert (prin1-to-string data))))))

(defun mclient-render-events-to-room (data)
  "Given a chunk of data from an /initialSyc, render each element from DATA in to its room."
  (let ((chunk (matrix-get 'chunk data)))
    (mapc 'mclient-render-event-to-room chunk)))

(defun mclient-render-event-to-room (item)
  "Feed ITEM in to its proper `mclient-event-handlers' handler."
  (let* ((type (matrix-get 'type item))
         (handler (matrix-get type mclient-event-handlers)))
    (when handler
      (funcall handler item))))

(defun mclient-update-header-line ()
  "Update the header line of the current buffer."
  (if (> 0 (length mclient-room-typers))
      (progn
        (setq header-line-format (format "(%d typing...) %s: %s" (length mclient-room-typers)
                                         mclient-room-name mclient-room-topic)))
    (setq header-line-format (format "%s: %s" mclient-room-name mclient-room-topic))))

(defun mclient-filter (condp lst)
  "A standard filter, feed it a function CONDP and a LST."
  (delq nil
        (mapcar (lambda (x)
                  (and (funcall condp x) x))
                lst)))

(defmacro insert-read-only (text &rest extra-props)
  "Insert a block of TEXT as read-only, with the ability to add EXTRA-PROPS such as face."
  `(add-text-properties
    (point) (progn
              (insert ,text)
              (point))
    '(read-only t ,@extra-props)))

(defun mclient-render-message-line ()
  "Insert a message input at the end of the buffer."
  (end-of-buffer)
  (let ((inhibit-read-only t))
    (insert "\n")
    (insert-read-only (format "🔥 [%s] ▶" mclient-room-id))
    (insert " ")))

(defun mclient-send-active-line ()
  "Send the current message-line text after running it through input-filters."
  (interactive)
  (end-of-buffer)
  (beginning-of-line)
  (re-search-forward "▶")
  (forward-char)
  (kill-line)
  (reduce 'mclient-run-through-input-filter
          mclient-input-filters
          :initial-value (pop kill-ring)))

(defun mclient-run-through-input-filter (text filter)
  "Run each TEXT through a single FILTER.  Used by `mclient-send-active-line'."
  (when text
    (funcall filter text)))

(defun mclient-send-to-current-room (text)
  "Send a string TEXT to the current buffer's room."
  (matrix-send-message mclient-room-id text))

(defun mclient-set-room-end-token (data)
  "When an event DATA comes in, file it in to the room so that we can mark a cursor when visiting the buffer."
  (mapc (lambda (data)
          (let* ((room-id (matrix-get 'room_id data))
                 (room-buf (matrix-get room-id mclient-active-rooms)))
            (when room-buf
              (with-current-buffer room-buf
                (setq-local mclient-room-end-token (matrix-get 'event_id data)))))
          ) (matrix-get 'chunk data)))

(defun mclient-restart-listener-maybe (sym error-thrown)
  "The error handler for mclient's event-poll.

SYM and ERROR-THROWN come from Request and are used to decide whether to connect."
  (cond ((or (string-match "code 6" (cdr error-thrown))
             (eq sym 'parse-error)
             (eq sym 'timeout)
             (string-match "interrupt" (cdr error-thrown))
             (string-match "code 7" (cdr error-thrown)))
         (message "Lost connection with matrix, will re-attempt in %s ms"
                  (/ mclient-event-poll-timeout 2))
         (mclient-restart-later))
        ((string-match "code 60" (cdr error-thrown))
         (message "curl couldn't validate CA, not advising --insecure? File bug pls."))))

(defun mclient-stream-from-end-token ()
  "Restart the mclient stream from the saved end-token."
  (mclient-start-event-listener mclient-event-stream-end-token))

(defun mclient-restart-later ()
  "Try to restart the Matrix poller later, maybe."
  (run-with-timer (/ mclient-event-poll-timeout 1000) nil
                  'mclient-stream-from-end-token))

(provide 'mclient)
;;; mclient.el ends here
