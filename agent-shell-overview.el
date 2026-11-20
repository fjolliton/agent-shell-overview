;;; agent-shell-overview.el --- Overview of the agent-shell sessions -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Frédéric Jolliton

;; Author: Frédéric Jolliton
;; Maintainer: Frédéric Jolliton
;; URL: https://github.com/fjolliton/agent-shell-overview
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (agent-shell "0.94.2"))
;; Keywords: tools, convenience
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; `agent-shell-overview' lists the agent-shell sessions in a side
;; window: the state of each (working, waiting for an answer, done,
;; idle), its session title, last activity, idle time and directory.
;; Sessions are grouped by project, as project.el finds them, a
;; worktree under its main project, or listed as one, see
;; `agent-shell-overview-group-by-project' and `G'.  From the list, a
;; session can be previewed, jumped to, interrupted, reloaded,
;; restarted, killed, marked unread or muted.  A muted session never
;; asks for attention and is listed in a Parked group of its own.
;;
;; At the bottom or top of the frame, the overview is a table; on the
;; left or right, a narrow list where each session takes several lines.
;; `agent-shell-overview-side' is the side it opens on, and `w' in the
;; overview, `agent-shell-overview-cycle-side', moves it from side to
;; side.
;;
;;   (keymap-global-set "C-c o" #'agent-shell-overview)
;;   (setopt agent-shell-overview-side 'right)
;;   (agent-shell-overview-tracking-mode 1)
;;
;; `agent-shell-overview-tracking-mode' follows the turns of the agent
;; shells, to tell which ones finished unseen.  The overview enables it,
;; but enabling it at startup also tracks the turns that end before the
;; overview is first shown.
;;
;; Extending:
;;
;; - `agent-shell-overview-state-functions' gives a shell a state of
;;   its own before the built-in ones are considered.  Each state has
;;   its glyph, label and faces in `agent-shell-overview-states', whose
;;   order is that of the state sort.  The states of
;;   `agent-shell-overview-attention-states' ask for attention: the
;;   "needs you" filter, the attention navigation and
;;   `agent-shell-overview-attention' use them.
;; - `agent-shell-overview-columns' lists the columns of the table;
;;   `agent-shell-overview-add-column' inserts one.  The narrow list
;;   shows the columns that are not built-in on its time line.
;; - `agent-shell-overview-entry-functions' adds rows that are not shell
;;   buffers, as plists with their own state, title, time, directory and
;;   actions.
;; - `agent-shell-overview-help-functions' gives the row of a shell its
;;   tooltip.
;; - `agent-shell-overview-refresh-hook' runs on each polling tick,
;;   before the overview is redrawn.
;; - `agent-shell-overview-mute-functions' runs after a shell is muted or
;;   unmuted, for instance to save that state.
;; - `agent-shell-overview-worktree-functions' tells the main project of
;;   a worktree, for git by default.  The projects themselves come from
;;   project.el, so `project-find-functions' and its markers apply.
;; - `agent-shell-overview-directory-functions' tells where a shell
;;   works when that is not its cwd, such as a worktree its session
;;   entered.
;; - `agent-shell-overview-detail-functions' adds text to the location
;;   of a row, such as the branch or pull request of its checkout.
;; - A segment of a cell with an `agent-shell-overview-action' property
;;   runs that function when clicked, instead of going to the shell.
;; - New commands go in `agent-shell-overview-mode-map' and
;;   `agent-shell-overview-menu', and find their row with
;;   `agent-shell-overview-row-at-point'.
;;
;; This package was written by Claude, Anthropic's AI model, on behalf
;; of Frédéric Jolliton, who reviews and maintains it.

;;; Code:

(require 'agent-shell)
(require 'cl-lib)
(require 'hl-line)
(require 'map)
(require 'project)
(require 'seq)
(require 'subr-x)
(require 'tabulated-list)
(require 'text-property-search)

;;;; Customization

(defconst agent-shell-overview--builtin-sorts '(age name state activity)
  "The sorts the overview knows, see `agent-shell-overview-sorts'.")

(define-widget 'agent-shell-overview-sort 'choice
  "A sort of the overview, one of `agent-shell-overview--builtin-sorts'."
  :args (mapcar (lambda (sort) `(const ,sort)) agent-shell-overview--builtin-sorts))

(defgroup agent-shell-overview nil
  "Overview of the agent shells."
  :group 'agent-shell
  :prefix "agent-shell-overview-")

(defface agent-shell-overview-dim '((t :inherit shadow))
  "Face of what is secondary in the overview.")

(defface agent-shell-overview-idle-seconds '((t :inherit bold))
  "Face of an idle time in seconds in the overview.")

(defface agent-shell-overview-idle-minutes '((t))
  "Face of an idle time in minutes in the overview.")

(defface agent-shell-overview-idle-hours '((t :inherit font-lock-comment-face))
  "Face of an idle time in hours in the overview.")

(defface agent-shell-overview-idle-days '((t :inherit agent-shell-overview-dim))
  "Face of an idle time in days in the overview.")

(defface agent-shell-overview-blocked '((t :inherit error))
  "Face of the state of a shell waiting for an answer in the overview.")

(defface agent-shell-overview-finished '((t :inherit success))
  "Face of the state of a shell that has finished its turn in the overview.")

(defface agent-shell-overview-busy
  '((((class color) (background light)) :foreground "RoyalBlue3")
    (((class color) (background dark)) :foreground "LightSkyBlue")
    (t :inherit bold))
  "Face of the state of a working shell in the overview.")

(defface agent-shell-overview-location '((t :inherit font-lock-constant-face))
  "Face of the location of a shell in its project in the overview.")

(defface agent-shell-overview-project
  '((t :inherit (bold font-lock-function-name-face)))
  "Face of the name of a project group in the overview.")

(defface agent-shell-overview-filter '((t :inherit warning))
  "Face of the current filter on the summary line of the overview.
It shows when the filter is not the one that lists every row.")

(defface agent-shell-overview-visible '((t :inherit hl-line :extend t))
  "Face of the row of a shell shown in a window of the overview's frame.
It goes under the faces of the cells, to the edge of the window.")

(defface agent-shell-overview-parked '((t :inherit bold))
  "Face of the name of the Parked group in the overview.")

(defcustom agent-shell-overview-side 'bottom
  "The side of the frame on which `agent-shell-overview' opens.
On `top' and `bottom', the overview is a table in a window as tall as
it.  On `left' and `right', it is a list in a narrow window, where each
session takes several lines, without column titles, fewer in the
standard or compact mode, see `agent-shell-overview-compact'."
  :type '(choice (const bottom) (const top) (const left) (const right)))

(defcustom agent-shell-overview-vertical-width 40
  "Width of the window of the overview on the left or right side, in columns.
Its lines stop one column short of the edge: without fringes, a line
that reaches the last column of a window loses it to the truncation
glyph."
  :type 'natnum)

(defcustom agent-shell-overview-compact nil
  "What each session shows on the left or right side.
With nil, the detailed mode, everything: its number, state, title and
idle time; its location, followed by its detail, see
`agent-shell-overview-detail-functions'; then its other columns, see
`agent-shell-overview-columns'.  With `standard', where it works: its
number, state, title and idle time, then its location and detail.  With
any other non-nil value, the compact mode, its state at a glance on one
line: its number, state, title, the essential segments of its detail
and its idle time.  Hovering a row shows its location and last activity
in full.  This has no effect at the top or bottom.  This is the mode
until `agent-shell-overview-cycle-compact' changes it."
  :type '(choice (const :tag "Detailed" nil)
                 (const :tag "Standard" standard)
                 (const :tag "Compact" t)))

(defcustom agent-shell-overview-columns
  '((" State" 12 agent-shell-overview-column-state :pad-right 1)
    ("Session" 40 agent-shell-overview-column-title :pad-right 2)
    ("Last activity" 13 agent-shell-overview-column-activity :pad-right 2)
    ("Idle" 5 agent-shell-overview-column-idle :right-align t :pad-right 2)
    ("Where" 0 agent-shell-overview-column-where))
  "The columns of the overview table, at the bottom or top of the frame.
Each is (TITLE WIDTH FUNCTION . PROPS).  TITLE and WIDTH are those of
the column, and PROPS its properties in `tabulated-list-format', such
as `:right-align' and `:pad-right'.  FUNCTION is called with the id of
a row, an agent shell buffer or an entry plist, see
`agent-shell-overview-entry-functions', and with its state, a key of
`agent-shell-overview-states'; it returns the string of the cell.
A cell narrower than its column is followed by a space aligned on the
next column, so a glyph wider than a column, which a fallback font may
draw, does not push the next columns; the state column is one wider
than its widest label for that.

On the left or right side, the overview shows the state, title,
location and idle time of each row in a layout of its own, the last
activity on hovering it.  The columns whose FUNCTION is not one of the
built-in `agent-shell-overview-column-*' functions are shown there too,
on a line of their own, each right-aligned in WIDTH plus 3 columns from
the left, or, with a `:side-align' property of `right', against the
right edge, after a space at least.  That is the only property of PROPS
the side layout reads.
The standard and compact modes, see `agent-shell-overview-compact',
leave them out.

See `agent-shell-overview-add-column'."
  :type '(repeat (cons (string :tag "Title")
                       (cons (natnum :tag "Width")
                             (cons (function :tag "Function")
                                   (plist :tag "Properties"))))))

(defcustom agent-shell-overview-states
  '((blocked "●" "Blocked" agent-shell-overview-blocked nil)
    (finished "✔" "Done" agent-shell-overview-finished bold)
    (busy "☐" "Working" agent-shell-overview-busy nil)
    (ready "–" "Idle" agent-shell-overview-dim nil)
    (killed "✕" "Killed" agent-shell-overview-dim nil))
  "The states of the rows of the overview, in the order of the state sort.
Each is (STATE GLYPH LABEL FACE TITLE-FACE): GLYPH and LABEL show the
state, in FACE, and TITLE-FACE is that of the session title of its rows,
or nil.  The built-in states of a shell are `blocked' when it waits for
an answer, `finished' when its turn ended unseen, `busy' while it works,
`ready' when idle, and `killed' once its process is gone.  The states
of `agent-shell-overview-state-functions' and of the rows of
`agent-shell-overview-entry-functions' belong here too."
  :type '(repeat (list (symbol :tag "State")
                       (string :tag "Glyph")
                       (string :tag "Label")
                       (face :tag "Face")
                       (choice :tag "Title face" (const nil) face))))

(defcustom agent-shell-overview-attention-states '(blocked finished)
  "The states that ask for attention, the most urgent first.
A row in one of them asks for attention unless it is parked: the
\"needs you\" filter lists it, the attention navigation stops on it,
and `agent-shell-overview-attention' returns its state.  A folded group
shows the glyph of its most urgent such row, or of a working one."
  :type '(repeat symbol))

(defcustom agent-shell-overview-sorts '(age name state activity)
  "The sorts of the overview, in the order they cycle.
`agent-shell-overview-default-sort' applies until
`agent-shell-overview-cycle-sort' changes it, to the sort after it here,
or to the first one when it is not here.
- `age': rows oldest first, groups by their oldest row.
- `name': rows by session title, groups by the last component of the
  project path, both ignoring case.
- `state': rows in the order of `agent-shell-overview-states', groups
  by their most urgent row.
- `activity': rows most recent activity first, groups by their most
  recent activity.
See `agent-shell-overview-cycle-sort'."
  :type '(repeat agent-shell-overview-sort))

(defcustom agent-shell-overview-default-sort 'age
  "The sort of the overview until `agent-shell-overview-cycle-sort' changes it.
It need not be in `agent-shell-overview-sorts'.  Another value than the
four sorts there is warned about, and `age' applies instead."
  :type 'agent-shell-overview-sort)

(defcustom agent-shell-overview-filters
  '((all "all" t)
    (attention "needs you" attention)
    (busy "working" (busy))
    (ready "idle" (ready)))
  "The filters of the overview, in the order they cycle.
Each is (KEY LABEL SELECTION).  SELECTION is t for every row,
`attention' for the rows that ask for attention, see
`agent-shell-overview-attention-states', or a list of the states of the
rows it lists.  `agent-shell-overview-default-filter' applies until
`agent-shell-overview-cycle-filter' changes it."
  :type '(repeat (list (symbol :tag "Key")
                       (string :tag "Label")
                       (choice :tag "Selection"
                               (const :tag "Every row" t)
                               (const :tag "Rows asking for attention" attention)
                               (repeat :tag "States" symbol)))))

(defcustom agent-shell-overview-default-filter 'all
  "The key of the filter the overview starts with.
It applies until `agent-shell-overview-cycle-filter' changes it, and
must be the key of a filter of `agent-shell-overview-filters'; another
value is warned about, and the first filter there applies instead."
  :type 'symbol)

(defcustom agent-shell-overview-group-by-project t
  "Non-nil to group the rows of the overview by project.
When nil, the rows form one list, sorted as a whole, with their
directories in full; the Parked group stays apart.  This is the
grouping until `agent-shell-overview-toggle-grouping' changes it."
  :type 'boolean)

(defcustom agent-shell-overview-poll-interval 1
  "Seconds between two polls of the states of the agent shells.
Polling covers what emits no event, and redraws the overview while it is
shown.  A change applies when polling next starts."
  :type 'number)

;;;; Extension points

(defvar agent-shell-overview-state-functions nil
  "Functions giving the state of an agent shell before the built-in states.
Each is called with a live agent shell buffer, and returns a key of
`agent-shell-overview-states' or nil.  The first non-nil result is the
state of the shell, see `agent-shell-overview-state'.")

(defvar agent-shell-overview-help-functions nil
  "Functions giving the tooltip of the row of an agent shell.
Each is called with a live agent shell buffer, and returns a string or
nil.  The first non-nil result is the `help-echo' of the state of the
row, and closes the tooltip of the row on the left or right side.")

(defvar agent-shell-overview-entry-functions nil
  "Functions returning extra rows of the overview, which are not shell buffers.
Each is called without argument at each redraw and returns a list of
plists, the entries, with these keys:
- `:id': what tells the entry from the others, compared with `equal'
  across redraws; required.
- `:title': its session title.
- `:state': its state, a key of `agent-shell-overview-states'.
- `:time': the time of its last activity, a Lisp timestamp, or nil.
- `:directory': its directory, which gives its project group.
- `:group': `parked' to list it in the Parked group, as is an entry
  without a directory; otherwise nil.
- `:goto': a function called with the entry to go to it, from the most
  recently used ordinary window, which is selected.  RET and a click
  call it, and the overview is redrawn after it.
- `:preview': a function called with the entry to show it, keeping the
  focus in the overview; without it, the echo area shows its help.
- `:kill': a function called with the entry to remove it, which asks for
  confirmation itself if need be; the overview is redrawn after it.
- `:help': a string, or a function called with the entry returning a
  string or nil: the tooltip of its state, also shown in the echo area
  by a command that needs a shell.
- `:confirm': a prompt that a click asks `y-or-n-p' before `:goto'.
An entry has no shell, so the commands that act on a shell refuse it.")

(defcustom agent-shell-overview-refresh-hook nil
  "Hook run on each polling tick, before the overview is redrawn.
It runs as long as polling does: while an agent shell lives or the
overview is shown, every `agent-shell-overview-poll-interval' seconds.
An error in it is ignored."
  :type 'hook)

(defcustom agent-shell-overview-worktree-functions
  '(agent-shell-overview-git-worktree-root)
  "Functions telling the main project of a worktree.
The projects of the overview are those of project.el, see
`project-current', so `project-find-functions' and its markers apply.
Each function is called with the root of such a project, a directory
name, and returns the root of the main project when that root is a
linked worktree, or the like in another version control system, and
nil otherwise.  The first non-nil result counts: the worktree is listed
in the group of the main project, with a worktree mark.  An error in a
function is shown as a message, and the next functions still run."
  :type 'hook)

;; Read through `agent-shell-overview--directory', at every redraw.
(defcustom agent-shell-overview-directory-functions nil
  "Functions telling the directory an agent shell works in.
Each is called with a live agent shell buffer, and returns a directory
or nil.  The first non-nil result is the directory of the row of the
shell, and otherwise its cwd, see `agent-shell-cwd'.  It gives the
project group of the row and its location, with the worktree mark in a
linked worktree, see `agent-shell-overview-worktree-functions'.  The
shell itself keeps its cwd: the commands that start a shell do not use
it.  The functions run at every redraw, once a second for each row, so
they must only read what is already known, not run processes or read
files.  An error in a function is shown as a message, and the next
functions still run."
  :type 'hook)

(defcustom agent-shell-overview-detail-functions nil
  "Functions adding text to the location of a row.
Each is called with the id of a row, an agent shell buffer or an entry
plist, see `agent-shell-overview-entry-functions', and returns a string
or nil.  The non-nil results, joined with a space, are the detail of the
row, which keeps its own faces.  At the bottom or top of the frame, the
detail follows the location in the \"Where\" column; on the left or
right side, it is right-aligned on the line of the location, which is
cut on the left to make room.  In the compact mode, see
`agent-shell-overview-compact', a row shows only the segments of its
detail with a non-nil `agent-shell-overview-essential' text property,
joined with a space, before the idle time, the title giving up the room;
without such a segment, it shows none.

A segment of the detail, as of any cell, is made clickable by an
`agent-shell-overview-action' text property: its value is a function,
which a mouse click on the segment calls with the id of the row, in
place of going to the shell; RET still goes to the shell.
Give such a segment a `help-echo' of its own, which the tooltip of the
row does not replace, and a `mouse-face' other than `highlight', such as
`link', for it to highlight apart from the row.

The functions run at every redraw, once a second for each row, so they
must only read what is already known, such as a cache filled by
asynchronous processes, not run processes or read files.  An error in a
function is shown as a message, and the next functions still run."
  :type 'hook)

(defcustom agent-shell-overview-mute-functions nil
  "Abnormal hook run after an agent shell is muted or unmuted.
Each function is called with the shell buffer current and as its
argument; whether it is now muted is `agent-shell-overview-muted-p'.  It
also runs when `agent-shell-overview-reload-shell' carries the mute
state to the new shell.  An error in a function is shown as a message,
and the next functions still run."
  :type 'hook)

;;;; Internal state

(defconst agent-shell-overview--buffer "*Agent Shells*"
  "Name of the buffer of the overview.")

(defconst agent-shell-overview--sides '(bottom left top right)
  "The sides of the overview, in the order they cycle.
See `agent-shell-overview-cycle-side'.")

(defvar agent-shell-overview--shells nil
  "Agent shell buffers, in the order they were registered.")

(defvar-local agent-shell-overview--finished nil
  "Non-nil when a turn of this shell ended and it has not been viewed since.")

(defvar-local agent-shell-overview--restored nil
  "Non-nil from the replay of a resumed session to the next turn.
See `agent-shell-overview-activity-known-p'.")

(defvar-local agent-shell-overview-restored-time nil
  "The time of the last activity of the session this shell resumed, or nil.
A Lisp timestamp, set by the client that saved the session.  The
overview shows it while the last activity of the shell is unknown, see
`agent-shell-overview-activity-known-p'.")

(defvar-local agent-shell-overview-muted nil
  "Non-nil when this agent shell is muted: it never asks for attention.
The overview lists it in its Parked group.  See
`agent-shell-overview-toggle-mute'.")

(defvar-local agent-shell-overview--subscriptions nil
  "The event subscriptions of this agent shell, see `agent-shell-subscribe-to'.")

(defvar agent-shell-overview--timer nil
  "Timer polling the states while a shell lives or the overview is shown.
See `agent-shell-overview--tick'.")

(defvar agent-shell-overview--attention nil
  "Alist of the live agent shells and their attention at the last poll.")

(defvar agent-shell-overview--sort nil
  "The current sort of the overview, or nil.
Nil, or a sort neither in `agent-shell-overview-sorts' nor the default
one, is `agent-shell-overview-default-sort'.")

(defvar agent-shell-overview--grouping nil
  "The current grouping of the overview: `project', `none', or nil.
Nil is the one of `agent-shell-overview-group-by-project'.")

(defvar agent-shell-overview--compact nil
  "The mode of the vertical layout: `detailed', `standard' or `compact'.
Nil is that of `agent-shell-overview-compact'.")

(defvar agent-shell-overview--filter nil
  "The key of the current filter in `agent-shell-overview-filters', or nil.
Nil, or a key no longer there, is `agent-shell-overview-default-filter'.")

(defvar agent-shell-overview--warned nil
  "The (OPTION . VALUE) pairs of the defaults already warned about.")

(defvar agent-shell-overview--sectioned nil
  "Whether a group header or a row was printed in the drawing yet.
It is `none' before the first one, t after it, and nil outside of a
drawing, see `agent-shell-overview--print-entry'.")

(defvar agent-shell-overview--numbered nil
  "The number of shells numbered so far in the drawing of the overview.
It is nil outside of a drawing.  See `agent-shell-overview-goto-number'.")

(defvar agent-shell-overview--visible nil
  "The buffers shown in the windows of the overview's frame, while drawing it.")

(defvar agent-shell-overview--folded nil
  "The groups the overview folds to their header line.
Each is a project root, or `parked' for the Parked group, see
`agent-shell-overview--group'.  See `agent-shell-overview-toggle-fold'.")

(defvar-local agent-shell-overview--layout 'horizontal
  "The layout of the overview in this buffer, `horizontal' or `vertical'.
It follows from the side the buffer was last shown on.")

(defvar agent-shell-overview--locations (make-hash-table :test #'equal)
  "Cache of `agent-shell-overview--location', by directory.")

;;;; Registry and attention

(defun agent-shell-overview-shells ()
  "Return the live agent shells, oldest first."
  (setq agent-shell-overview--shells
        (seq-filter #'buffer-live-p agent-shell-overview--shells)))

(defun agent-shell-overview-title (buffer)
  "Return the session title of agent shell BUFFER, or its buffer name.
The title is the first line of the one the session has, else the buffer
name without its \"<agent> Agent @ \" prefix."
  ;; `agent-shell--state' is internal to agent-shell: without a title
  ;; there, the buffer name stands in.
  (let ((title (ignore-errors
                 (map-nested-elt (buffer-local-value 'agent-shell--state buffer)
                                 '(:session :title)))))
    (if (and (stringp title) (not (string-blank-p title)))
        (car (split-string (string-trim title) "\n"))
      (replace-regexp-in-string "\\`.*? Agent @ " "" (buffer-name buffer)))))

(defun agent-shell-overview-muted-p (buffer)
  "Return non-nil if agent shell BUFFER is live and muted."
  (and (buffer-live-p buffer)
       (buffer-local-value 'agent-shell-overview-muted buffer)))

(defun agent-shell-overview-pending (buffer)
  "Return what agent shell BUFFER waits for from the user, or nil.
`blocked' when it waits for an answer, otherwise `finished' when a turn
ended unseen, whether the shell is muted or not.  Nil as well for a
killed buffer.  Never signals."
  (when (buffer-live-p buffer)
    (if (eq (ignore-errors (agent-shell-status :shell-buffer buffer)) 'blocked)
        'blocked
      (and (buffer-local-value 'agent-shell-overview--finished buffer) 'finished))))

(defun agent-shell-overview--dead-p (buffer)
  "Return non-nil if the shell process of BUFFER is gone."
  (let ((process (get-buffer-process buffer)))
    (not (and process (process-live-p process)))))

(defun agent-shell-overview-state (buffer)
  "Return the state of agent shell BUFFER, a key of `agent-shell-overview-states'.
It is the first state `agent-shell-overview-state-functions' gives,
else `killed' when its process is gone, else what it waits for, see
`agent-shell-overview-pending', else `busy' or `ready'."
  (cond ((not (buffer-live-p buffer)) 'killed)
        ((run-hook-with-args-until-success
          'agent-shell-overview-state-functions buffer))
        ((agent-shell-overview--dead-p buffer) 'killed)
        (t (let ((status (ignore-errors (agent-shell-status :shell-buffer buffer))))
             (cond ((eq status 'blocked) 'blocked)
                   ((buffer-local-value 'agent-shell-overview--finished buffer) 'finished)
                   ((eq status 'busy) 'busy)
                   (t 'ready))))))

(defun agent-shell-overview-attention (buffer)
  "Return the state in which agent shell BUFFER asks for attention, or nil.
It is its state when that is one of
`agent-shell-overview-attention-states', and nil for a muted shell.
Never signals."
  (ignore-errors
    (unless (agent-shell-overview-muted-p buffer)
      (let ((state (and (buffer-live-p buffer) (agent-shell-overview-state buffer))))
        (and (memq state agent-shell-overview-attention-states) state)))))

(defun agent-shell-overview--tick ()
  "Poll the states of the agent shells and redraw the overview.
Run `agent-shell-overview-refresh-hook', update the mode lines if the
attention of a shell changed, and redraw the overview if it is shown.
Stop polling once no agent shell is left and the overview is not shown.
Never signals, as it runs from a timer."
  (ignore-errors
    (let ((shells (agent-shell-overview-shells)))
      (ignore-errors (run-hooks 'agent-shell-overview-refresh-hook))
      (unless (or shells (agent-shell-overview--window))
        (agent-shell-overview--poll-stop))
      (let ((attention (mapcar (lambda (buffer)
                                 (cons buffer (agent-shell-overview-attention buffer)))
                               shells)))
        (unless (equal attention agent-shell-overview--attention)
          (setq agent-shell-overview--attention attention)
          (force-mode-line-update t)))
      (agent-shell-overview-refresh))))

(defun agent-shell-overview--poll-start ()
  "Poll the states of the agent shells, unless already polling.
See `agent-shell-overview--tick'."
  (unless (timerp agent-shell-overview--timer)
    (setq agent-shell-overview--timer
          (run-with-timer agent-shell-overview-poll-interval
                          agent-shell-overview-poll-interval
                          #'agent-shell-overview--tick))))

(defun agent-shell-overview--poll-stop ()
  "Stop polling the states of the agent shells."
  (when (timerp agent-shell-overview--timer)
    (cancel-timer agent-shell-overview--timer))
  (setq agent-shell-overview--timer nil))

(defun agent-shell-overview--viewed-p (buffer)
  "Return non-nil if BUFFER is shown in the selected window of a visible frame."
  (seq-some (lambda (window)
              (eq window (frame-selected-window (window-frame window))))
            (get-buffer-window-list buffer nil 'visible)))

(defun agent-shell-overview--on-turn-end (buffer)
  "Flag agent shell BUFFER as finished unless it is being viewed."
  (when (buffer-live-p buffer)
    (setf (buffer-local-value 'agent-shell-overview--restored buffer) nil)
    (unless (agent-shell-overview--viewed-p buffer)
      (setf (buffer-local-value 'agent-shell-overview--finished buffer) t))
    (agent-shell-overview--tick)))

(defun agent-shell-overview--on-submit (buffer)
  "Clear the finished flag of agent shell BUFFER, as a new turn starts."
  (when (buffer-live-p buffer)
    (setf (buffer-local-value 'agent-shell-overview--restored buffer) nil)
    (setf (buffer-local-value 'agent-shell-overview--finished buffer) nil)
    (agent-shell-overview--tick)))

(defun agent-shell-overview--clear-viewed (frame)
  "Clear the finished flag of the buffer in FRAME's selected window.
Return non-nil if it was set.  An invisible or iconified FRAME is not
looked at, and clears nothing."
  (when (and (frame-live-p frame) (eq (frame-visible-p frame) t))
    (let ((buffer (window-buffer (frame-selected-window frame))))
      (when (buffer-local-value 'agent-shell-overview--finished buffer)
        (setf (buffer-local-value 'agent-shell-overview--finished buffer) nil)
        t))))

(defun agent-shell-overview--on-window-change (frame)
  "Clear the finished flag of the buffer in FRAME's selected window.
Poll the states if it was set, see `agent-shell-overview--tick'."
  (when (agent-shell-overview--clear-viewed frame)
    (agent-shell-overview--tick)))

(defun agent-shell-overview--on-buffer-change (frame)
  "Follow a change of the buffers or windows of FRAME, redrawing at most once.
Clear the finished flag of the buffer in its selected window, and poll
the states if it was set; otherwise redraw the overview if it is shown
on FRAME, where a shell shown in a window has its row tinted."
  (if (agent-shell-overview--clear-viewed frame)
      (agent-shell-overview--tick)
    (when-let* ((window (agent-shell-overview--window)))
      (when (eq (window-frame window) frame)
        (agent-shell-overview-refresh)))))

(defun agent-shell-overview--on-restored (buffer)
  "Mark the last activity of agent shell BUFFER unknown, as it resumed."
  (when (buffer-live-p buffer)
    (setf (buffer-local-value 'agent-shell-overview--restored buffer) t)
    (agent-shell-overview--tick)))

(defun agent-shell-overview--track ()
  "Register this agent shell, follow its turns and start polling.
A turn that ends, or fails, while the shell is not viewed flags it as
finished; a submitted prompt clears the flag.  The replay of a resumed
session makes its last activity unknown until the next turn.  Polling
covers what emits no event, such as a question asked by a tool."
  (add-to-list 'agent-shell-overview--shells (current-buffer) t)
  (unless agent-shell-overview--subscriptions
    (let ((buffer (current-buffer)))
      (pcase-dolist (`(,event . ,handler)
                     '((input-submitted . agent-shell-overview--on-submit)
                       (turn-complete . agent-shell-overview--on-turn-end)
                       ;; A failed turn ends with `error' rather than `turn-complete'.
                       (error . agent-shell-overview--on-turn-end)
                       (session-restored . agent-shell-overview--on-restored)))
        (push (agent-shell-subscribe-to
               :shell-buffer buffer :event event
               :on-event (lambda (_event) (funcall handler buffer)))
              agent-shell-overview--subscriptions))))
  (agent-shell-overview--poll-start))

(defun agent-shell-overview--untrack ()
  "Stop following the turns of this agent shell."
  (dolist (subscription agent-shell-overview--subscriptions)
    (ignore-errors (agent-shell-unsubscribe :subscription subscription)))
  (setq agent-shell-overview--subscriptions nil))

(defun agent-shell-overview--live-shells ()
  "Return the live buffers in `agent-shell-mode'."
  (match-buffers '(derived-mode . agent-shell-mode)))

;;;###autoload
(define-minor-mode agent-shell-overview-tracking-mode
  "Track the agent shells for `agent-shell-overview'.
When enabled, each agent shell is registered as it starts, its turns
are followed to tell which ones finished unseen, and the states of the
shells are polled while one lives or the overview is shown.  Enabling
it registers the agent shells already live."
  :global t
  :group 'agent-shell-overview
  (if agent-shell-overview-tracking-mode
      (progn
        (add-hook 'agent-shell-mode-hook #'agent-shell-overview--track)
        (add-hook 'window-buffer-change-functions
                  #'agent-shell-overview--on-buffer-change)
        (add-hook 'window-selection-change-functions
                  #'agent-shell-overview--on-window-change)
        (dolist (buffer (agent-shell-overview--live-shells))
          (with-current-buffer buffer
            (agent-shell-overview--track))))
    (remove-hook 'agent-shell-mode-hook #'agent-shell-overview--track)
    (remove-hook 'window-buffer-change-functions
                 #'agent-shell-overview--on-buffer-change)
    (remove-hook 'window-selection-change-functions
                 #'agent-shell-overview--on-window-change)
    (dolist (buffer (agent-shell-overview--live-shells))
      (with-current-buffer buffer
        (agent-shell-overview--untrack)))
    (agent-shell-overview--poll-stop)))

(defun agent-shell-overview--set-muted (shell muted)
  "Mute agent SHELL if MUTED is non-nil, otherwise unmute it.
Run `agent-shell-overview-mute-functions' in SHELL."
  (with-current-buffer shell
    (setq agent-shell-overview-muted (and muted t))
    (run-hook-wrapped 'agent-shell-overview-mute-functions
                      (lambda (function)
                        (with-demoted-errors "agent-shell-overview-mute-functions: %S"
                          (funcall function shell))
                        nil))))

(defun agent-shell-overview--toggle-mute (shell)
  "Mute or unmute agent SHELL, and redraw the overview."
  (unless (and (buffer-live-p shell)
               (with-current-buffer shell (derived-mode-p 'agent-shell-mode)))
    (user-error "Not an agent shell"))
  (let ((muted (not (buffer-local-value 'agent-shell-overview-muted shell))))
    (agent-shell-overview--set-muted shell muted)
    (message "%s %s" (if muted "Muted" "Unmuted") (buffer-name shell)))
  (agent-shell-overview--tick))

(defun agent-shell-overview-reload-shell (shell)
  "Restart the agent of SHELL and resume its session, see `agent-shell-reload'.
The new shell buffer takes the name of SHELL, and stays muted if SHELL
was, see `agent-shell-overview-muted'."
  (let ((name (buffer-name shell))
        (muted (buffer-local-value 'agent-shell-overview-muted shell)))
    (with-current-buffer shell
      (agent-shell-reload))
    (when-let* ((muted)
                (buffer (get-buffer name)))
      (agent-shell-overview--set-muted buffer t))))

;;;; Rows

(defun agent-shell-overview--entry-p (id)
  "Return non-nil if row ID is an entry plist rather than a shell buffer.
See `agent-shell-overview-entry-functions'."
  (consp id))

(defun agent-shell-overview--key (id)
  "Return what identifies row ID across redraws.
A shell buffer is its own key, an entry has its `:id'."
  (if (agent-shell-overview--entry-p id) (plist-get id :id) id))

(defun agent-shell-overview--row (id)
  "Return the (STATE . ID) row of ID, a shell buffer or an entry."
  (cons (if (agent-shell-overview--entry-p id)
            (plist-get id :state)
          (agent-shell-overview-state id))
        id))

(defun agent-shell-overview--parked-p (id)
  "Return non-nil if row ID belongs to the Parked group.
It is a muted shell, or an entry whose `:group' is `parked' or that has
no directory."
  (if (agent-shell-overview--entry-p id)
      (or (eq (plist-get id :group) 'parked)
          (not (plist-get id :directory)))
    (agent-shell-overview-muted-p id)))

(defun agent-shell-overview--attention-p (row)
  "Return non-nil if ROW, a (STATE . ID) pair, asks for attention.
Its state is one of `agent-shell-overview-attention-states', and it is
not parked."
  (and (memq (car row) agent-shell-overview-attention-states)
       (not (agent-shell-overview--parked-p (cdr row)))))

(defun agent-shell-overview--entries ()
  "Return the entries of `agent-shell-overview-entry-functions'.
A function that fails adds none, and its error is shown."
  (mapcan (lambda (function)
            (with-demoted-errors "agent-shell-overview: %S"
              (copy-sequence (funcall function))))
          agent-shell-overview-entry-functions))

(defun agent-shell-overview--entry-help (entry)
  "Return the help of ENTRY, see `agent-shell-overview-entry-functions'."
  (let ((help (plist-get entry :help)))
    (if (functionp help) (funcall help entry) help)))

(defun agent-shell-overview--help (id)
  "Return the tooltip of the state of row ID, or nil.
A shell whose last activity is unknown says so, after the help of
`agent-shell-overview-help-functions', and that the time shown is that
of the saved session if `agent-shell-overview-restored-time' is set."
  (if (agent-shell-overview--entry-p id)
      (agent-shell-overview--entry-help id)
    (when (buffer-live-p id)
      (let ((help (run-hook-with-args-until-success
                   'agent-shell-overview-help-functions id))
            (unknown
             (and (agent-shell-overview--unknown-p id)
                  (if (buffer-local-value 'agent-shell-overview-restored-time id)
                      "No turn seen yet: the last activity is that of the saved session."
                    "No turn seen yet: the last activity is unknown."))))
        (if (and help unknown) (concat help "\n" unknown) (or help unknown))))))

(defun agent-shell-overview--state-spec (state)
  "Return (GLYPH LABEL FACE TITLE-FACE) of STATE.
See `agent-shell-overview-states'.  An unknown state shows as \"?\"
and its name."
  (or (alist-get state agent-shell-overview-states)
      (list "?" (format "%s" state) 'agent-shell-overview-dim nil)))

(defun agent-shell-overview--title-of (id)
  "Return the session title of row ID, a shell buffer or an entry."
  (if (agent-shell-overview--entry-p id)
      (format "%s" (or (plist-get id :title) (plist-get id :id)))
    (agent-shell-overview-title id)))

(defun agent-shell-overview-activity-known-p (buffer)
  "Return non-nil if the last activity of agent shell BUFFER is known.
It is not from the replay of a resumed session, signalled by the
`session-restored' event of agent-shell, to the next turn of the shell:
agent-shell takes the time of any message of the agent, the replayed
ones included, and the overview shows instead the time of
`agent-shell-overview-restored-time', or no time.  A session
resumed without replay, as with `session/resume', signals no such
event, so its time is that of the resume."
  (not (buffer-local-value 'agent-shell-overview--restored buffer)))

(defun agent-shell-overview--unknown-p (id)
  "Return non-nil if row ID is a shell whose last activity is unknown.
See `agent-shell-overview-activity-known-p'."
  (and (bufferp id) (buffer-live-p id)
       (not (agent-shell-overview-activity-known-p id))))

(defun agent-shell-overview--activity (id)
  "Return the time of the last activity of row ID, or nil.
While that of a shell is unknown, see
`agent-shell-overview-activity-known-p', it is
`agent-shell-overview-restored-time'."
  (cond ((agent-shell-overview--entry-p id) (plist-get id :time))
        ((agent-shell-overview--unknown-p id)
         (buffer-local-value 'agent-shell-overview-restored-time id))
        (t (ignore-errors (agent-shell-last-activity-time :shell-buffer id)))))

(defun agent-shell-overview--idle (time)
  "Return the time since TIME, as \"12s\", \"3m\", \"2h\" or \"2d\".
The result is empty when TIME is nil."
  (if time
      (let ((seconds (max 0 (round (float-time (time-since time))))))
        (cond ((< seconds 60) (format "%ds" seconds))
              ((< seconds 3600) (format "%dm" (/ seconds 60)))
              ((< seconds 86400) (format "%dh" (/ seconds 3600)))
              (t (format "%dd" (/ seconds 86400)))))
    ""))

(defun agent-shell-overview--last-activity (time)
  "Return TIME in local time, as \"14:32\" today.
On an earlier day of this year, as \"Nov 3 09:12\"; in another year, as
\"Nov 3 2025\".  The result is empty when TIME is nil."
  (if time
      (let ((system-time-locale "C"))
        (format-time-string
         (cond ((equal (format-time-string "%F" time) (format-time-string "%F"))
                "%H:%M")
               ((equal (format-time-string "%Y" time) (format-time-string "%Y"))
                "%b %-d %H:%M")
               (t "%b %-d %Y"))
         time))
    ""))

;;;; Projects and locations

(defun agent-shell-overview-git-worktree-root (root)
  "Return the root of the main project of ROOT, a linked git worktree, or nil.
ROOT is one when its `.git' file reads \"gitdir:
<repository>/worktrees/<name>\", a relative path being from ROOT.  The
main root is the parent of a repository named `.git' or `.bare', and
else the repository itself, as a bare \"proj.git\" is.  See
`agent-shell-overview-worktree-functions'."
  (let ((dotgit (expand-file-name ".git" root)))
    (when (file-regular-p dotgit)
      (ignore-errors
        (with-temp-buffer
          (insert-file-contents dotgit)
          (when (looking-at "gitdir: *\\(.+?\\)/worktrees/[^/\n]+/*$")
            (let ((repository (expand-file-name (match-string 1) root)))
              (if (member (file-name-nondirectory repository) '(".git" ".bare"))
                  (file-name-directory repository)
                repository))))))))

(defun agent-shell-overview--base-root (directory)
  "Return the root of the project of DIRECTORY, or DIRECTORY.
The project is the one `project-current' finds, without prompting; one
that fails to be found counts as none."
  (file-name-as-directory
   (file-truename
    (or (condition-case nil
            (when-let* ((project (project-current nil directory)))
              (project-root project))
          (error nil))
        directory))))

(defun agent-shell-overview--main-root (root)
  "Return the root of the main project of ROOT, a worktree, or nil.
See `agent-shell-overview-worktree-functions'."
  (when-let* ((main (run-hook-wrapped
                     'agent-shell-overview-worktree-functions
                     (lambda (function)
                       (with-demoted-errors "agent-shell-overview-worktree-functions: %S"
                         (funcall function root))))))
    (file-name-as-directory (file-truename main))))

(defun agent-shell-overview--project-root (directory)
  "Return the root of the project holding DIRECTORY, or DIRECTORY.
It is the root that project.el finds, or that of its main project when
that root is a worktree, see `agent-shell-overview-worktree-functions'."
  (let ((root (agent-shell-overview--base-root directory)))
    (or (agent-shell-overview--main-root root) root)))

(defun agent-shell-overview--location (directory)
  "Return (PROJECT . WHERE) for DIRECTORY, its project root and where in it.
WHERE is relative, or abbreviated in full outside of PROJECT; its
`agent-shell-overview-worktree' property is non-nil in a worktree, see
`agent-shell-overview--project-root'."
  ;; Finding them reads files, hence the cache.
  (or (gethash directory agent-shell-overview--locations)
      (puthash directory
               (let* ((truename (file-name-as-directory (file-truename directory)))
                      (base (agent-shell-overview--base-root truename))
                      (main (agent-shell-overview--main-root base))
                      (root (or main base)))
                 (cons root
                       (propertize
                        ;; A linked worktree may be outside of its project.
                        (directory-file-name
                         (if (string-prefix-p root truename)
                             (substring truename (length root))
                           (abbreviate-file-name truename)))
                        'agent-shell-overview-worktree (and main t))))
               agent-shell-overview--locations)))

(defun agent-shell-overview--directory (id)
  "Return the directory of row ID, or nil.
That of a shell is the first that `agent-shell-overview-directory-functions'
gives, and otherwise its cwd, see `agent-shell-cwd'."
  (if (agent-shell-overview--entry-p id)
      (plist-get id :directory)
    (and (buffer-live-p id)
         (or (run-hook-wrapped
              'agent-shell-overview-directory-functions
              (lambda (function)
                (with-demoted-errors "agent-shell-overview-directory-functions: %S"
                  (funcall function id))))
             (with-current-buffer id (agent-shell-cwd))))))

(defun agent-shell-overview--detail (id)
  "Return the detail of row ID, or the empty string.
It joins the results of `agent-shell-overview-detail-functions'."
  (let (parts)
    (run-hook-wrapped
     'agent-shell-overview-detail-functions
     (lambda (function)
       (when-let* ((part (with-demoted-errors "agent-shell-overview-detail-functions: %S"
                           (funcall function id)))
                   ((not (string-empty-p part))))
         (push part parts))
       nil))
    (string-join (nreverse parts) " ")))

(defun agent-shell-overview--grouped-p ()
  "Return non-nil if the overview groups its rows by project.
See `agent-shell-overview-toggle-grouping'."
  (pcase agent-shell-overview--grouping
    ('project t)
    ('none nil)
    (_ agent-shell-overview-group-by-project)))

(defun agent-shell-overview--vertical-mode ()
  "Return the mode of the vertical layout: `detailed', `standard' or `compact'.
See `agent-shell-overview-compact' and
`agent-shell-overview-cycle-compact'."
  (or agent-shell-overview--compact
      (pcase agent-shell-overview-compact
        ('nil 'detailed)
        ('standard 'standard)
        (_ 'compact))))

(defun agent-shell-overview--group (id)
  "Return the key of the overview group of row ID.
It is `parked' for a row of the Parked group, see
`agent-shell-overview--parked-p', and otherwise the project root of its
directory, see `agent-shell-overview--location'."
  (if (agent-shell-overview--parked-p id)
      'parked
    (car (agent-shell-overview--location (agent-shell-overview--directory id)))))

(defun agent-shell-overview--where (id)
  "Return the location the overview shows for row ID.
It is its directory relative to its project, see
`agent-shell-overview--location'.  A row out of a project group, in the
Parked group or when the overview does not group by project, has its
directory in full, abbreviated; it keeps the
`agent-shell-overview-worktree' property."
  (if-let* ((directory (agent-shell-overview--directory id)))
      (pcase-let ((`(,project . ,where) (agent-shell-overview--location directory)))
        (if (or (and (agent-shell-overview--grouped-p)
                     (not (agent-shell-overview--parked-p id)))
                (file-name-absolute-p where))
            where
          (propertize (directory-file-name
                       (concat (abbreviate-file-name project) where))
                      'agent-shell-overview-worktree
                      (and (not (string-empty-p where))
                           (get-text-property 0 'agent-shell-overview-worktree where)))))
    ""))

;;;; Columns

(defun agent-shell-overview-column-state (id state)
  "Return the state cell of row ID in STATE: its glyph and label.
Its `help-echo' is the help of the row, see
`agent-shell-overview-help-functions'."
  (pcase-let ((`(,glyph ,label ,face) (agent-shell-overview--state-spec state)))
    (propertize (format " %s %s " glyph label)
                'face face
                'help-echo (agent-shell-overview--help id))))

(defun agent-shell-overview-column-title (id state)
  "Return the title cell of row ID in STATE.
Its face is that STATE gives its titles, dimmed for a muted shell."
  (propertize (agent-shell-overview--title-of id)
              'face (if (and (bufferp id) (agent-shell-overview-muted-p id))
                        'agent-shell-overview-dim
                      (nth 3 (agent-shell-overview--state-spec state)))))

(defun agent-shell-overview-column-activity (id _state)
  "Return the cell of the time of the last activity of row ID.
It is blank when there is none, see `agent-shell-overview--activity'."
  (propertize (agent-shell-overview--last-activity
               (agent-shell-overview--activity id))
              'face 'agent-shell-overview-dim))

(defun agent-shell-overview-column-idle (id _state)
  "Return the cell of the time since the last activity of row ID.
Its face fades from seconds, to minutes, to hours, to days.  It is
blank when there is no last activity, see
`agent-shell-overview--activity'."
  (let ((idle (agent-shell-overview--idle (agent-shell-overview--activity id))))
    (cond
     ((string-empty-p idle) idle)
     (t (propertize idle 'face
                    (pcase (aref idle (1- (length idle)))
                      (?s 'agent-shell-overview-idle-seconds)
                      (?m 'agent-shell-overview-idle-minutes)
                      (?h 'agent-shell-overview-idle-hours)
                      (_ 'agent-shell-overview-idle-days)))))))

(defun agent-shell-overview-column-where (id _state)
  "Return the cell of the location of row ID, see `agent-shell-overview--where'.
At the bottom or top of the frame, the detail of the row follows it, see
`agent-shell-overview-detail-functions'; on the left or right side, the
row shows its detail itself."
  (let ((where (propertize (agent-shell-overview--where id)
                           'face 'agent-shell-overview-location))
        (detail (if (eq agent-shell-overview--layout 'vertical)
                    ""
                  (agent-shell-overview--detail id))))
    (cond ((string-empty-p detail) where)
          ((string-empty-p where) detail)
          (t (concat where " " detail)))))

(defconst agent-shell-overview--builtin-columns
  '(agent-shell-overview-column-state
    agent-shell-overview-column-title
    agent-shell-overview-column-activity
    agent-shell-overview-column-idle
    agent-shell-overview-column-where)
  "The functions of the built-in columns of `agent-shell-overview-columns'.")

(defun agent-shell-overview-add-column (column &optional after)
  "Add COLUMN to `agent-shell-overview-columns', after the column AFTER.
COLUMN is (TITLE WIDTH FUNCTION . PROPS).  AFTER is the function of a
column; when nil or absent, COLUMN goes last.  A column with the same
function is replaced."
  (let* ((function (nth 2 column))
         (columns (seq-remove (lambda (other) (eq (nth 2 other) function))
                              agent-shell-overview-columns))
         (position (and after
                        (seq-position columns after
                                      (lambda (other after) (eq (nth 2 other) after))))))
    (setq agent-shell-overview-columns
          (if position
              (append (seq-take columns (1+ position))
                      (list column)
                      (seq-drop columns (1+ position)))
            (append columns (list column))))))

(defun agent-shell-overview--format ()
  "Return the value of `tabulated-list-format' of the overview.
It follows `agent-shell-overview-columns'.  No column is sortable: the
rows keep the order of `agent-shell-overview--table', as the group
headers are rows too."
  (apply #'vector
         (mapcar (lambda (column)
                   (append (list (nth 0 column) (nth 1 column) nil)
                           (nthcdr 3 column)))
                 agent-shell-overview-columns)))

(defun agent-shell-overview--cells (id state)
  "Return the cells of row ID in STATE, followed by STATE.
They follow `agent-shell-overview-columns'.  In the horizontal layout, a
cell with a `help-echo' on a segment has the tooltip of its column on
the rest, as `tabulated-list-print-col' gives a cell without one, since
it keeps that of a cell only when the cell starts with it."
  (vconcat (mapcar (lambda (column)
                     (let ((cell (funcall (nth 2 column) id state)))
                       (when (and (eq agent-shell-overview--layout 'horizontal)
                                  (text-property-not-all 0 (length cell) 'help-echo nil cell))
                         (setq cell (copy-sequence cell))
                         (agent-shell-overview--put-missing
                          0 (length cell) 'help-echo
                          (concat (nth 0 column) ": " (substring-no-properties cell))
                          cell))
                       cell))
                   agent-shell-overview-columns)
           (list state)))

(defun agent-shell-overview--cell (id cells function)
  "Return the cell of the column of FUNCTION among CELLS of row ID.
CELLS are as `agent-shell-overview--cells' made them.  Without such a
column in `agent-shell-overview-columns', call FUNCTION for it."
  (if-let* ((index (seq-position agent-shell-overview-columns function
                                 (lambda (column function)
                                   (eq (nth 2 column) function)))))
      (aref cells index)
    (funcall function id (aref cells (1- (length cells))))))

(defun agent-shell-overview--line (text)
  "Return the table entry of a line that is no row, TEXT with its newline."
  ;; The other cells are empty, as `tabulated-list-print-entry' measures
  ;; the cells of the lines next to a row.
  (list nil (vconcat (list text)
                     (make-list (max 0 (1- (length agent-shell-overview-columns))) ""))))

;;;; Table

(defun agent-shell-overview--align (count end text)
  "Return COUNT spaces before TEXT, displayed so that TEXT ends at column END.
They show as one stretch up to the width of TEXT before END: in columns
when TEXT is ASCII, otherwise in pixels, so that glyphs wider than a
column, which a fallback font may draw, do not push TEXT past END."
  (if (> count 0)
      (propertize (make-string count ?\s)
                  'display `(space :align-to
                                   (- ,end ,(if (string-match-p "\\`[[:ascii:]]*\\'" text)
                                                (length text)
                                              (list (string-pixel-width text))))))
    ""))

(defun agent-shell-overview--truncate-left (string width)
  "Return STRING cut on the left with \"…\" to fit in WIDTH columns."
  (if (<= (string-width string) width)
      string
    (concat "…" (reverse (truncate-string-to-width (reverse string) (1- width))))))

(defun agent-shell-overview--table-width ()
  "Return the width of the overview table in columns.
It is one less than `agent-shell-overview-vertical-width' in the
vertical layout, and that of the selected window in the horizontal one."
  (if (eq agent-shell-overview--layout 'vertical)
      (1- agent-shell-overview-vertical-width)
    (window-max-chars-per-line)))

;; `tabulated-list-mode-map' makes mouse-1 on a `mouse-face' follow a link,
;; which turns it into mouse-2.
(defvar-keymap agent-shell-overview-row-map
  :doc "Keymap of a row of the overview, which is what makes it clickable."
  "<mouse-1>" #'agent-shell-overview-click
  "<mouse-2>" #'agent-shell-overview-click
  "<mouse-3>" #'agent-shell-overview-mouse-menu)

(defvar-keymap agent-shell-overview-group-map
  :doc "Keymap of a group header of the overview, which folds and unfolds it."
  "TAB" #'agent-shell-overview-toggle-fold
  "RET" #'agent-shell-overview-toggle-fold
  "<backtab>" #'agent-shell-overview-toggle-fold-all
  "<mouse-1>" #'agent-shell-overview-toggle-fold
  "<mouse-2>" #'agent-shell-overview-toggle-fold
  ;; Shift with mouse-1 down otherwise pops up the font menu.
  "S-<down-mouse-1>" #'ignore
  "S-<mouse-1>" #'agent-shell-overview-toggle-fold-all)

(defvar-keymap agent-shell-overview-sort-map
  :doc "Keymap of the sort on the summary line of the overview, which cycles it."
  "RET" #'agent-shell-overview-cycle-sort
  "<mouse-1>" #'agent-shell-overview-cycle-sort
  "<mouse-2>" #'agent-shell-overview-cycle-sort)

(defun agent-shell-overview--folded-state (parked rows)
  "Return the most urgent attention state or `busy' among ROWS, or nil.
ROWS are the (STATE . ID) rows of a folded group, the Parked group if
PARKED is non-nil."
  (seq-find (lambda (state)
              (and (assq state rows)
                   (or (eq state 'busy)
                       (and (memq state agent-shell-overview-attention-states)
                            ;; Muting hides only the states in which a shell
                            ;; waits for the user; others, such as a crash an
                            ;; extension adds, still show on the Parked header.
                            (not (and parked (memq state '(blocked finished))))))))
            (mapcar #'car agent-shell-overview-states)))

(defun agent-shell-overview--group-header (project rows &optional folded)
  "Return the table entry of the header line of group PROJECT, or `parked'.
It shows a fold marker, the name, the number of ROWS, the glyph of a
FOLDED group, and the parent directory against the right edge."
  (let* ((width (agent-shell-overview--table-width))
         (dim 'agent-shell-overview-dim)
         (parked (eq project 'parked))
         (path (if parked
                   "Parked"
                 (abbreviate-file-name (directory-file-name project))))
         (left (concat (propertize (if folded " ⏵ " " ⏷ ") 'face dim)
                       (propertize (file-name-nondirectory path)
                                   'face (if parked
                                             'agent-shell-overview-parked
                                           'agent-shell-overview-project))
                       (propertize (format " %d" (length rows)) 'face dim)
                       (when folded
                         (when-let* ((state (agent-shell-overview--folded-state
                                             parked rows)))
                           (pcase-let ((`(,glyph ,_ ,face)
                                        (agent-shell-overview--state-spec state)))
                             (concat " " (propertize glyph 'face face)))))))
         ;; A space at least before the parent, and one after it.
         (room (- width (string-width left) 2))
         (parent (if (and (> room 0) (not parked))
                     (agent-shell-overview--truncate-left
                      (directory-file-name (or (file-name-directory path) ""))
                      room)
                   "")))
    ;; The keymap takes the newline, for a key at the end of the line; the
    ;; highlight stops at the text, as on a row.  The `help-echo' shows the
    ;; highlight at once and gives a truncated path in full.
    (agent-shell-overview--line
     (concat
      ;; The `agent-shell-overview-group' property tells a header from the
      ;; other lines.
      (propertize
       (concat left
               (agent-shell-overview--align
                (max 1 (- width (string-width left) (string-width parent) 1))
                (1- width) parent)
               (propertize parent 'face dim)
               " ")
       'agent-shell-overview-group project
       'keymap agent-shell-overview-group-map
       'mouse-face 'highlight
       'help-echo (if parked
                      "Muted sessions, which never ask for attention, and other parked rows"
                    path))
      (propertize "\n" 'keymap agent-shell-overview-group-map)))))

(defun agent-shell-overview--warn-default (option message &rest args)
  "Warn that OPTION has an unknown value, once per value.
MESSAGE and ARGS format the warning, after the name of OPTION."
  (let ((key (cons option (symbol-value option))))
    (unless (member key agent-shell-overview--warned)
      (push key agent-shell-overview--warned)
      (display-warning 'agent-shell-overview
                       (apply #'format-message (concat "`%s' " message) option args)
                       :warning))))

(defun agent-shell-overview--default-sort ()
  "Return `agent-shell-overview-default-sort', or `age' if it is unknown."
  (if (memq agent-shell-overview-default-sort agent-shell-overview--builtin-sorts)
      agent-shell-overview-default-sort
    (agent-shell-overview--warn-default
     'agent-shell-overview-default-sort
     "is %S, not one of %s; sorting by age instead"
     agent-shell-overview-default-sort
     (mapconcat #'symbol-name agent-shell-overview--builtin-sorts ", "))
    'age))

(defun agent-shell-overview--current-sort ()
  "Return the current sort of the overview, see `agent-shell-overview-sorts'."
  (let ((default (agent-shell-overview--default-sort)))
    (if (and (memq agent-shell-overview--sort agent-shell-overview--builtin-sorts)
             (or (memq agent-shell-overview--sort agent-shell-overview-sorts)
                 (eq agent-shell-overview--sort default)))
        agent-shell-overview--sort
      default)))

(defun agent-shell-overview--current-filter ()
  "Return the current filter, an element of `agent-shell-overview-filters'."
  (or (assq agent-shell-overview--filter agent-shell-overview-filters)
      (assq agent-shell-overview-default-filter agent-shell-overview-filters)
      (let ((first (or (car agent-shell-overview-filters) (list 'all "all" t))))
        (agent-shell-overview--warn-default
         'agent-shell-overview-default-filter
         "is %S, not a key of `agent-shell-overview-filters'; using %S instead"
         agent-shell-overview-default-filter (car first))
        first)))

(defun agent-shell-overview--sort-key (row)
  "Return what orders ROW, a (STATE . ID) pair, in the current sort.
Keys compare with `agent-shell-overview--key<', the smallest first.  A
row without a time of activity, see `agent-shell-overview--activity',
goes after all the others."
  (pcase (agent-shell-overview--current-sort)
    ('name (downcase (agent-shell-overview--title-of (cdr row))))
    ('state (or (seq-position (mapcar #'car agent-shell-overview-states) (car row))
                (length agent-shell-overview-states)))
    ('activity (if-let* ((time (agent-shell-overview--activity (cdr row))))
                   (- (float-time time))
                 1.0e+INF))
    (_ 0)))

(defun agent-shell-overview--key< (a b)
  "Return non-nil if sort key A orders before sort key B.
Keys are numbers, strings, or lists of keys compared element by
element."
  (cond ((and (numberp a) (numberp b)) (< a b))
        ((and (stringp a) (stringp b)) (string< a b))
        ((and (consp a) (consp b))
         (or (agent-shell-overview--key< (car a) (car b))
             (and (not (agent-shell-overview--key< (car b) (car a)))
                  (agent-shell-overview--key< (cdr a) (cdr b)))))
        (t nil)))

(defun agent-shell-overview--sort-by (function list)
  "Return LIST sorted by the keys FUNCTION gives its elements.
The keys, computed once each, compare with `agent-shell-overview--key<'.
The sort is stable, so a tie keeps the order of LIST."
  (mapcar #'cdr
          (sort (mapcar (lambda (element) (cons (funcall function element) element))
                        list)
                (lambda (a b) (agent-shell-overview--key< (car a) (car b))))))

(defun agent-shell-overview--select (rows key)
  "Return the ROWS the current filter selects, in the current sort.
ROWS are (STATE . ID) pairs, and KEY gives the sort key of a row, see
`agent-shell-overview--sort-key'.  A tie keeps the order of ROWS.  See
`agent-shell-overview-filters'."
  (let ((selection (nth 2 (agent-shell-overview--current-filter))))
    (agent-shell-overview--sort-by
     key (seq-filter (lambda (row)
                       (cond ((eq selection t) t)
                             ((eq selection 'attention)
                              (agent-shell-overview--attention-p row))
                             (t (memq (car row) selection))))
                     rows))))

(defun agent-shell-overview--group-entries (group)
  "Return the table entries of GROUP, a (PROJECT . ROWS) pair.
They are its header line, see `agent-shell-overview--group-header',
followed by the entries of its (STATE . ID) ROWS unless PROJECT is in
`agent-shell-overview--folded'."
  (let ((folded (member (car group) agent-shell-overview--folded)))
    (cons (agent-shell-overview--group-header (car group) (cdr group) folded)
          (unless folded
            (mapcar #'agent-shell-overview--row-entry (cdr group))))))

(defun agent-shell-overview--row-entry (row)
  "Return the table entry of ROW, a (STATE . ID) pair."
  (list (cdr row) (agent-shell-overview--cells (cdr row) (car row))))

(defun agent-shell-overview--table ()
  "Return the table entries: the rows the current filter selects, by group.
The groups and their rows follow the current sort, the Parked group
last, after a summary line, see `agent-shell-overview--summary'.  When
the overview does not group by project, the rows out of the Parked
group are one list without a header, see
`agent-shell-overview--grouped-p'."
  (let* ((ids (append (agent-shell-overview-shells)
                      (agent-shell-overview--entries)))
         (grouped (agent-shell-overview--grouped-p))
         (order (when grouped
                  (let ((table (make-hash-table :test #'eq)))
                    (seq-do-indexed (lambda (id index) (puthash id index table)) ids)
                    table)))
         (split (seq-group-by (lambda (row) (and (agent-shell-overview--parked-p (cdr row)) t))
                              (mapcar #'agent-shell-overview--row ids)))
         (others (cdr (assq nil split)))
         ;; The sort key of each row, computed once.
         (key (let ((keys (make-hash-table :test #'eq)))
                (lambda (row)
                  (with-memoization (gethash row keys)
                    (agent-shell-overview--sort-key row)))))
         (parked (agent-shell-overview--select (cdr (assq t split)) key))
         (flat (unless grouped (agent-shell-overview--select others key)))
         (groups (when grouped
                   (seq-filter
                    #'cdr
                    (mapcar (lambda (group)
                              (cons (car group)
                                    (agent-shell-overview--select (cdr group) key)))
                            (seq-group-by (lambda (row) (agent-shell-overview--group (cdr row)))
                                          others)))))
         (lines (append
                 (if grouped
                     (mapcan
                      #'agent-shell-overview--group-entries
                      ;; A folded group takes its place from the rows it
                      ;; hides, and a tie goes to the oldest row, shells
                      ;; before entries.
                      (agent-shell-overview--sort-by
                       (lambda (group)
                         (list (if (eq (agent-shell-overview--current-sort) 'name)
                                   (downcase (file-name-nondirectory
                                              (directory-file-name (car group))))
                                 ;; The first row has the smallest key of its group.
                                 (funcall key (cadr group)))
                               (seq-min (mapcar (lambda (row) (gethash (cdr row) order))
                                                (cdr group)))))
                       groups))
                   (mapcar #'agent-shell-overview--row-entry flat))
                 (and parked
                      (agent-shell-overview--group-entries (cons 'parked parked)))))
         (total (+ (length flat)
                   (seq-reduce (lambda (sum group) (+ sum (length (cdr group)))) groups 0)
                   (length parked))))
    (if (or lines (not (eq (nth 2 (agent-shell-overview--current-filter)) t)))
        (cons (agent-shell-overview--line
               (agent-shell-overview--summary total (length parked)
                                              (- (length ids) total)))
              lines)
      lines)))

(defun agent-shell-overview--summary (total parked hidden)
  "Return the summary line of TOTAL listed rows, PARKED of them parked.
The current sort and filter, with the HIDDEN rows it leaves out, are
against the right edge, on a second line when the first cannot hold them.
A click on the sort cycles it, see `agent-shell-overview-sort-map'."
  (let* ((width (agent-shell-overview--table-width))
         (dim 'agent-shell-overview-dim)
         (filter (agent-shell-overview--current-filter))
         (left (propertize
                (concat (if (zerop total)
                            " No sessions"
                          (format " %d session%s" total (if (= total 1) "" "s")))
                        (if (> parked 0) (format " · %d parked" parked) ""))
                'face dim))
         (sort (propertize (format "⇅ %s" (agent-shell-overview--current-sort))
                           'face dim
                           'keymap agent-shell-overview-sort-map
                           'mouse-face 'highlight
                           'help-echo (substitute-command-keys
                                       "mouse-1 or \\<agent-shell-overview-mode-map>\\[agent-shell-overview-cycle-sort]: next sort")))
         (shown (and (not (eq (nth 2 filter) t))
                     (propertize (concat (nth 1 filter) " only"
                                         (if (> hidden 0) (format " (%d hidden)" hidden) ""))
                                 'face 'agent-shell-overview-filter)))
         (right (if shown (concat sort (propertize " · " 'face dim) shown) sort)))
    (cl-flet ((fits (text)
                ;; Two spaces at least before TEXT, and one after it.
                (<= (+ (string-width left) 2 (string-width text) 1) width))
              (line (start text)
                ;; The lines stop one column short of the edge, as the parent
                ;; directory of a group header does.
                (concat start
                        (agent-shell-overview--align
                         (max 1 (- width (string-width start) (string-width text) 1))
                         (1- width) text)
                        text " \n")))
      (cond ((fits right) (line left right))
            ((fits sort) (concat (line left sort) (if shown (line "" shown) "")))
            (t (concat left "\n" (line "" right)))))))

;;;; Drawing

(defun agent-shell-overview--number-cell (number)
  "Return the one-column cell of NUMBER in the gutter of a row, or a blank.
The tenth shows 0, the key that goes to it."
  (if number
      (propertize (format "%d" (% number 10)) 'face 'agent-shell-overview-dim)
    " "))

(defun agent-shell-overview--print-vertical (id cells number)
  "Insert the lines of row ID in the vertical layout, from its CELLS.
They show its NUMBER, state, title and idle time, the location and
detail, then the other columns, ending in a newline.  See
`agent-shell-overview--vertical-mode': in the standard mode, the third
is left out; in the compact mode, they are one line of its NUMBER,
state, title, preceded by a mark in a worktree, the essential segments
of its detail and idle time."
  (pcase-let* ((state (aref cells (1- (length cells))))
               (`(,glyph ,_ ,face) (agent-shell-overview--state-spec state))
               (mode (agent-shell-overview--vertical-mode))
               (title (agent-shell-overview--cell
                       id cells #'agent-shell-overview-column-title))
               (title-face (and (not (string-empty-p title))
                                (get-text-property 0 'face title)))
               (where (agent-shell-overview--cell
                       id cells #'agent-shell-overview-column-where))
               (mark (if (and (not (string-empty-p where))
                              (get-text-property 0 'agent-shell-overview-worktree where))
                         "⎇ " ""))
               (activity (agent-shell-overview--cell
                          id cells #'agent-shell-overview-column-activity))
               (idle (agent-shell-overview--cell
                      id cells #'agent-shell-overview-column-idle))
               (detail (agent-shell-overview--detail id))
               ;; The number sits under the fold marker of the group header, the
               ;; glyph under the project name, and the rest under the title.
               ;; The lines stop one column short of the edge, as the parent
               ;; directory of the header does.
               (indent "     ")
               (width (- agent-shell-overview-vertical-width (length indent) 2))
               (start (point)))
    (cl-flet ((right (text used)
                ;; TEXT right-aligned on the line, after USED columns.
                (insert (agent-shell-overview--align
                         (max 1 (- width used (string-width text)))
                         (+ (length indent) width) text)
                        text))
              (location ()
                ;; The detail is right-aligned, the location cut on the
                ;; left before it.
                (let* ((detail (truncate-string-to-width detail width nil nil "…"))
                       (room (- width (string-width detail)
                                (if (string-empty-p detail) 0 1))))
                  (unless (and (string-empty-p where) (string-empty-p detail))
                    (insert "\n" indent
                            (if (or (string-empty-p where)
                                    (< room (+ (string-width mark) 2)))
                                ""
                              (propertize (concat mark (agent-shell-overview--truncate-left
                                                        where (- room (string-width mark))))
                                          'face 'agent-shell-overview-location)))
                    (unless (string-empty-p detail)
                      (insert (agent-shell-overview--align
                               (max 1 (- width (- (current-column) (length indent))
                                         (string-width detail)))
                               (+ (length indent) width) detail)
                              detail))))))
      (insert " " (agent-shell-overview--number-cell number) " "
              (propertize glyph 'face face)
              ;; The title starts on its column, after a glyph of any width.
              (agent-shell-overview--align 1 (length indent) ""))
      (if (eq mode 'detailed)
          ;; The title and idle time, the location and detail, then the
          ;; other columns on a line of their own when one of them is not
          ;; blank: each right-aligned in its width plus 3, from the left,
          ;; and those with `:side-align' `right' against the right edge.
          (let ((title (truncate-string-to-width
                        title (max 1 (- width 1 (string-width idle))) nil nil "…"))
                (used 0)
                (columns "")
                (pinned nil))
            (insert (propertize title 'face title-face))
            (right idle (string-width title))
            (location)
            (seq-do-indexed
             (lambda (column index)
               (unless (memq (nth 2 column) agent-shell-overview--builtin-columns)
                 (let ((cell (aref cells index))
                       (field (+ (nth 1 column) 3)))
                   (if (eq (plist-get (nthcdr 3 column) :side-align) 'right)
                       (push cell pinned)
                     (setq used (+ used (max field (string-width cell))))
                     (setq columns
                           (concat columns
                                   (agent-shell-overview--align
                                    (max 0 (- field (string-width cell)))
                                    (+ (length indent) used) cell)
                                   cell))))))
             agent-shell-overview-columns)
            (let ((pinned (string-join (nreverse pinned) " ")))
              (unless (string-blank-p (substring-no-properties
                                       (concat columns pinned)))
                (insert "\n" indent columns)
                (unless (string-empty-p pinned)
                  (right pinned used)))))
        ;; The first line ends with the idle time, preceded in the compact
        ;; mode by the essential segments of the detail, up to half of it.
        (let* ((one (eq mode 'compact))
               (mark (if one mark ""))
               (essential (if one
                              (truncate-string-to-width
                               (agent-shell-overview--essential detail)
                               (/ width 2) nil nil "…")
                            ""))
               (tail (string-join (seq-remove #'string-empty-p (list essential idle))
                                  " "))
               (title (truncate-string-to-width
                       title (max 1 (- width (string-width mark) 1 (string-width tail)))
                       nil nil "…")))
          (insert (propertize mark 'face 'agent-shell-overview-location)
                  (propertize title 'face title-face))
          (right tail (+ (string-width mark) (string-width title)))
          (unless one
            (location))))
      (insert ?\n))
    ;; Without a `help-echo', the highlight of the row under the mouse
    ;; waits for the next redisplay to show.  The narrow lines truncate the
    ;; title and location, and leave out the last activity, so it gives
    ;; them in full.
    (agent-shell-overview--put-missing
     start (point) 'help-echo
     (string-join (seq-remove #'string-empty-p
                              (list (substring-no-properties title)
                                    (substring-no-properties where)
                                    (if (string-empty-p activity)
                                        ""
                                      (concat "Last activity: "
                                              (substring-no-properties activity)))
                                    (or (agent-shell-overview--help id) "")))
                  "\n"))))

(defun agent-shell-overview--essential (detail)
  "Return the essential segments of DETAIL, joined with a space.
They are its runs with a non-nil `agent-shell-overview-essential'
property, see `agent-shell-overview-detail-functions'."
  (let ((end (length detail))
        (start 0)
        parts)
    (while (setq start (text-property-not-all
                        start end 'agent-shell-overview-essential nil detail))
      (let ((stop (or (text-property-any
                       start end 'agent-shell-overview-essential nil detail)
                      end)))
        (push (substring detail start stop) parts)
        (setq start stop)))
    (string-join (nreverse parts) " ")))

(defun agent-shell-overview--put-missing (start end property value &optional object)
  "Set PROPERTY to VALUE from START to END where it is nil.
OBJECT is the string to change, or nil for the current buffer.  A
segment with a value of its own, such as the `help-echo' of a clickable
segment, see `agent-shell-overview-detail-functions', keeps it."
  (while (< start end)
    (let ((next (next-single-property-change start property object end)))
      (unless (get-text-property start property object)
        (put-text-property start next property value object))
      (setq start next))))

(defun agent-shell-overview--separator ()
  "Return the dashed line between two sections of the overview."
  (propertize (concat " "
                      (make-string (max 0 (- (agent-shell-overview--table-width) 2)) ?╌)
                      "\n")
              'face 'agent-shell-overview-dim))

(defun agent-shell-overview--print-entry (id cells)
  "Insert the table entry of row ID with CELLS, as a clickable row.
A live shell among the first ten of the drawing shows its number, and a
shell shown in a window of the frame has its row tinted.  With a nil ID, insert
the first cell alone, as a line that is no row."
  ;; A group header, or a row before any, opens a section, set off by a
  ;; dashed line from the section above it, and by half a line from the
  ;; lines above the first one, but not at the top of the buffer.
  (when (and agent-shell-overview--sectioned
             (or (and id (eq agent-shell-overview--sectioned 'none))
                 (and (not id)
                      (get-text-property 0 'agent-shell-overview-group (aref cells 0)))))
    (unless (bobp)
      (insert (if (eq agent-shell-overview--sectioned t)
                  (agent-shell-overview--separator)
                (propertize "\n" 'face '(:height 0.5)))))
    (setq agent-shell-overview--sectioned t))
  (if id
      (let ((start (point))
            (number (and agent-shell-overview--numbered
                         (< agent-shell-overview--numbered 10)
                         (buffer-live-p id)
                         (setq agent-shell-overview--numbered
                               (1+ agent-shell-overview--numbered)))))
        (if (eq agent-shell-overview--layout 'vertical)
            (agent-shell-overview--print-vertical id cells number)
          (tabulated-list-print-entry id cells)
          ;; The number takes the second column of the padding.
          (when number
            (save-excursion
              (goto-char (1+ start))
              (delete-char 1)
              (insert (agent-shell-overview--number-cell number)))))
        ;; The tint goes under the faces of the cells, and through the
        ;; final newline, so that it extends to the edge of the window.
        (when (and (bufferp id) (memq id agent-shell-overview--visible))
          (add-face-text-property start (point) 'agent-shell-overview-visible t))
        (add-text-properties start (point)
                             `(tabulated-list-id
                               ,id tabulated-list-entry ,cells
                               ,@(and number (list 'agent-shell-overview-number number))))
        ;; Not sticky: a click past the end of the row is not on it.
        ;; Without the final newline, the highlight of a row stops at its end.
        ;; A segment keeps a `mouse-face' of its own.
        (agent-shell-overview--put-missing start (1- (point)) 'mouse-face 'highlight)
        (add-text-properties start (1- (point))
                             (list 'keymap agent-shell-overview-row-map
                                   'rear-nonsticky t)))
    (insert (aref cells 0))))

(defun agent-shell-overview--row-start (id)
  "Return the position of the first line of the row of ID, or nil.
ID matches the row with the same key, see `agent-shell-overview--key',
as each redraw may make the entries afresh."
  (when id
    (let ((key (agent-shell-overview--key id)))
      (save-excursion
        (goto-char (point-min))
        (when-let* ((match (text-property-search-forward
                            'tabulated-list-id key
                            (lambda (key value)
                              (and value (equal key (agent-shell-overview--key value)))))))
          (prop-match-beginning match))))))

(defun agent-shell-overview--header-start (project)
  "Return the position of the header line of the group of PROJECT, or nil."
  (save-excursion
    (goto-char (point-min))
    (when-let* ((match (text-property-search-forward
                        'agent-shell-overview-group project t)))
      (prop-match-beginning match))))

(defun agent-shell-overview--print ()
  "Draw the table in this buffer, keeping point on the row of the same id.
Point goes to the header of a folded group holding the row, or stays
on the same line when the row is gone."
  (let* ((inhibit-read-only t)
         (id (tabulated-list-get-id (pos-bol)))
         (offset (when-let* ((row (agent-shell-overview--row-start id)))
                   (- (point) row)))
         (line (line-number-at-pos))
         (format (agent-shell-overview--format)))
    (unless (equal format tabulated-list-format)
      (setq tabulated-list-format format)
      (when (eq agent-shell-overview--layout 'horizontal)
        (tabulated-list-init-header)))
    (setq tabulated-list-entries (agent-shell-overview--table))
    (let ((agent-shell-overview--numbered 0)
          (agent-shell-overview--sectioned 'none)
          (agent-shell-overview--visible
           (mapcar #'window-buffer
                   (window-list (when-let* ((window (agent-shell-overview--window)))
                                  (window-frame window))
                                'never))))
      (tabulated-list-print))
    ;; Without the final newline, the buffer has no empty line for the
    ;; window to scroll to; this is why point is restored here.
    (goto-char (point-max))
    (when (and (bolp) (not (bobp)))
      (delete-char -1))
    ;; On the same row, point keeps its offset, up to the end of the row,
    ;; which may have lost a line; on another row, it goes to the first line.
    (if-let* ((row (agent-shell-overview--row-start id)))
        (goto-char (min (+ row offset)
                        (if-let* ((next (text-property-not-all
                                         row (point-max) 'tabulated-list-id
                                         (get-text-property row 'tabulated-list-id))))
                            (1- next)
                          (point-max))))
      (if-let* ((header (and (or (buffer-live-p id)
                                 (agent-shell-overview--entry-p id))
                             (let ((project (agent-shell-overview--group id)))
                               ;; Without project groups, only Parked has a header.
                               (and (or (eq project 'parked)
                                        (agent-shell-overview--grouped-p))
                                    (member project agent-shell-overview--folded)
                                    (agent-shell-overview--header-start project))))))
          (goto-char header)
        (goto-char (point-min))
        (forward-line (1- line))
        (when-let* ((row (agent-shell-overview--row-start
                          (tabulated-list-get-id (pos-bol)))))
          (goto-char row))))))

(defun agent-shell-overview--window ()
  "Return the side window showing the overview on any frame, or nil."
  (when-let* ((buffer (get-buffer agent-shell-overview--buffer)))
    (seq-find (lambda (window) (window-parameter window 'window-side))
              (get-buffer-window-list buffer nil t))))

(defun agent-shell-overview--fit (window)
  "Make WINDOW as tall as the table, down to one line of text.
The minimum counts the header and mode lines: an empty buffer measures
less than they take, and the resize would fail."
  (fit-window-to-buffer window nil (1+ (- (window-total-height window)
                                          (window-body-height window)))))

(defun agent-shell-overview-refresh ()
  "Redraw the overview, if it is shown.
In the horizontal layout, also fit its window to it.  The window keeps
its first line on the same row, unless point would leave the window."
  (interactive)
  (when-let* ((window (agent-shell-overview--window)))
    ;; The selected window's point is the one that survives the redraw.
    (with-selected-window window
      (let* ((start (window-start window))
             (id (get-text-property start 'tabulated-list-id))
             (offset (when-let* ((row (agent-shell-overview--row-start id)))
                       (count-lines row start)))
             (line (count-lines (point-min) start)))
        (agent-shell-overview--print)
        (when (eq agent-shell-overview--layout 'horizontal)
          (agent-shell-overview--fit window))
        ;; Erasing the buffer moved the window to its top: put back the
        ;; line it showed first, by row, else by line number.
        (set-window-start
         window
         (save-excursion
           (if-let* ((row (agent-shell-overview--row-start id)))
               (progn (goto-char row) (forward-line offset))
             (goto-char (point-min))
             (forward-line line))
           (pos-bol))
         t)))))

;;;; Commands

(defun agent-shell-overview-row-at-point ()
  "Return the id of the overview row at point, or nil.
It is an agent shell buffer, possibly killed since the last redraw, or
an entry plist, see `agent-shell-overview-entry-functions'.  A line
that is no row, such as a group header, has none."
  (tabulated-list-get-id (pos-bol)))

(defun agent-shell-overview--shell ()
  "Return the agent shell on the current row, or signal a user error.
An entry has no shell, and the error shows its help."
  (let ((id (agent-shell-overview-row-at-point)))
    (cond ((buffer-live-p id) id)
          ((agent-shell-overview--entry-p id)
           (user-error "%s" (or (agent-shell-overview--entry-help id)
                                "No agent shell on this row")))
          (t (user-error "No agent shell on this line")))))

(defun agent-shell-overview--entry ()
  "Return the entry on the current row, or nil."
  (let ((id (agent-shell-overview-row-at-point)))
    (and (agent-shell-overview--entry-p id) id)))

(defun agent-shell-overview-cycle-sort ()
  "Sort the overview by the next of `agent-shell-overview-sorts'.
The sort lasts for the session."
  (interactive)
  (setq agent-shell-overview--sort
        (or (cadr (memq (agent-shell-overview--current-sort)
                        agent-shell-overview-sorts))
            (car agent-shell-overview-sorts)))
  (agent-shell-overview-refresh)
  (message "Sort: %s" (if (eq agent-shell-overview--sort 'activity)
                          "last activity"
                        agent-shell-overview--sort)))

(defun agent-shell-overview-cycle-filter ()
  "Filter the overview by the next of `agent-shell-overview-filters'.
The filter lasts for the session.  Point stays on its row if still
listed, otherwise on the same line, or on the first row when that line
is no row."
  (interactive)
  (setq agent-shell-overview--filter
        (car (or (cadr (memq (agent-shell-overview--current-filter)
                             agent-shell-overview-filters))
                 (car agent-shell-overview-filters))))
  (agent-shell-overview-refresh)
  (unless (agent-shell-overview-row-at-point)
    (goto-char (or (agent-shell-overview--first-row) (point))))
  (message "Filter: %s" (nth 1 (agent-shell-overview--current-filter))))

(defun agent-shell-overview-toggle-grouping ()
  "Group the rows of the overview by project, or list them as one.
The grouping lasts for the session, see
`agent-shell-overview-group-by-project'.  Point stays on its row.  On
the header of a project, it goes to the first row of that project in
the list, or the first row when none is listed; on the header of the
Parked group, it stays there."
  (interactive)
  (let ((header (and (not (agent-shell-overview-row-at-point))
                     (get-text-property (pos-bol) 'agent-shell-overview-group))))
    (setq agent-shell-overview--grouping
          (if (agent-shell-overview--grouped-p) 'none 'project))
    (agent-shell-overview-refresh)
    (when header
      (goto-char (or (agent-shell-overview--header-start header)
                     (save-excursion
                       (goto-char (point-min))
                       (agent-shell-overview--find-row
                        1 (lambda (id) (equal (agent-shell-overview--group id) header))))
                     (agent-shell-overview--first-row)
                     (point)))))
  (message "Grouping: %s" (if (agent-shell-overview--grouped-p) "by project" "none")))

(defun agent-shell-overview-cycle-compact ()
  "Switch the overview to the next mode: detailed, standard, compact.
This applies on the left or right side; see
`agent-shell-overview-compact'.  The mode lasts for the session.  Point
stays on its row."
  (interactive)
  (setq agent-shell-overview--compact
        (pcase (agent-shell-overview--vertical-mode)
          ('detailed 'standard)
          ('standard 'compact)
          (_ 'detailed)))
  (agent-shell-overview-refresh)
  (message "%s%s"
           (pcase agent-shell-overview--compact
             ('detailed "Detailed list")
             ('standard "Standard list")
             (_ "Compact list"))
           (if (eq agent-shell-overview--layout 'vertical)
               ""
             " (on the left or right side)")))

(define-obsolete-function-alias 'agent-shell-overview-toggle-compact
  #'agent-shell-overview-cycle-compact "0.1.0")

(defun agent-shell-overview-toggle-fold (&optional all)
  "Fold or unfold the group of the header line at point.
A folded group shows its header alone, which counts the rows it hides
and shows the glyph of the most urgent of them.  With ALL non-nil, fold
every group, or unfold them all if this one is folded.  The fold lasts
for the session, and point stays on the header.  Called by a mouse
event, it acts on the header line clicked."
  (interactive)
  (when (mouse-event-p last-input-event)
    (posn-set-point (event-end last-input-event)))
  (let* ((project (or (get-text-property (pos-bol) 'agent-shell-overview-group)
                      (user-error "No group header on this line")))
         (projects (if all
                       (save-excursion
                         (goto-char (point-min))
                         (let (projects)
                           (while-let ((match (text-property-search-forward
                                               'agent-shell-overview-group nil nil)))
                             (push (prop-match-value match) projects))
                           projects))
                     (list project))))
    (setq agent-shell-overview--folded
          (if (member project agent-shell-overview--folded)
              (seq-difference agent-shell-overview--folded projects)
            (seq-union agent-shell-overview--folded projects)))
    (agent-shell-overview--print)
    (when-let* ((header (agent-shell-overview--header-start project)))
      (goto-char header))
    (when (and (eq agent-shell-overview--layout 'horizontal)
               (window-parameter nil 'window-side))
      (agent-shell-overview--fit (selected-window)))))

(defun agent-shell-overview-toggle-fold-all ()
  "Fold every group, or unfold them all if the one at point is folded.
Called by a mouse event, the one clicked counts instead."
  (interactive)
  (agent-shell-overview-toggle-fold t))

(defun agent-shell-overview--ordinary-windows ()
  "Return this frame's non-side, non-dedicated windows, most recent first."
  (seq-sort-by #'window-use-time #'>
               (seq-remove (lambda (window)
                             (or (window-parameter window 'window-side)
                                 (window-dedicated-p window)))
                           (window-list nil 'never))))

(defun agent-shell-overview-leave ()
  "Select the most recently used ordinary window of this frame, if any.
A shell started or resumed from the overview then shows there."
  (when-let* ((window (car (agent-shell-overview--ordinary-windows))))
    (select-window window)))

(defun agent-shell-overview--find-row (step &optional predicate)
  "Return the start of the next row after the one at point, or nil.
STEP is 1 to look down, and -1 to look up.  The lines that are no row
are skipped, and so are the rows of the shells killed since the last
redraw, which the next one removes.  With PREDICATE, only a row whose id
satisfies it counts."
  (save-excursion
    (let ((key (agent-shell-overview--key (agent-shell-overview-row-at-point)))
          found)
      (while (and (not found) (zerop (forward-line step)))
        (let ((id (agent-shell-overview-row-at-point)))
          (when (and (or (buffer-live-p id) (agent-shell-overview--entry-p id))
                     (not (equal (agent-shell-overview--key id) key))
                     (or (not predicate) (funcall predicate id)))
            (setq found (agent-shell-overview--row-start id)))))
      found)))

(defun agent-shell-overview--move (n)
  "Move to the first line of the Nth next row, as far as there are rows.
A negative N moves back.  See `agent-shell-overview--find-row'."
  (dotimes (_ (abs n))
    (when-let* ((row (agent-shell-overview--find-row (if (< n 0) -1 1))))
      (goto-char row))))

(defun agent-shell-overview-quit ()
  "Close the overview."
  (interactive)
  (when-let* ((window (agent-shell-overview--window)))
    (delete-window window)))

(defun agent-shell-overview--display ()
  "Show the shell on this row in an ordinary window and return that window.
The window already showing it is preferred over the most recently used
one.  Without an ordinary window, `display-buffer' places it; a user
error tells when it cannot."
  (let* ((shell (agent-shell-overview--shell))
         (windows (agent-shell-overview--ordinary-windows))
         (window (or (seq-find (lambda (window) (eq (window-buffer window) shell))
                               windows)
                     (car windows))))
    (if window
        (progn
          (set-window-buffer window shell)
          window)
      (or (display-buffer shell)
          (user-error "No window to show %s in" (buffer-name shell))))))

(defun agent-shell-overview--goto-entry (entry)
  "Go to ENTRY with its `:goto' function.
The function runs in the most recently used ordinary window, which is
selected; the window selected before is again if it fails or is quit.
The overview is redrawn either way, as a failure may change the
entries."
  (let ((goto (or (plist-get entry :goto)
                  (user-error "%s" (or (agent-shell-overview--entry-help entry)
                                       "Nothing to go to on this row")))))
    (unwind-protect
        (let ((window (selected-window)))
          (agent-shell-overview-leave)
          (condition-case err
              (funcall goto entry)
            (t
             (when (window-live-p window)
               (select-window window))
             (signal (car err) (cdr err)))))
      (agent-shell-overview-refresh))))

(defun agent-shell-overview-goto ()
  "Show the shell on this row in an ordinary window, select it, close the overview.
An entry is gone to with its `:goto' function instead, see
`agent-shell-overview-entry-functions'."
  (interactive)
  (agent-shell-overview-goto-keep)
  (agent-shell-overview-quit))

(defun agent-shell-overview-goto-keep ()
  "Show the shell on this row in an ordinary window and select it.
An entry is gone to with its `:goto' function instead, see
`agent-shell-overview-entry-functions'.  The overview stays open."
  (interactive)
  (if-let* ((entry (agent-shell-overview--entry)))
      (agent-shell-overview--goto-entry entry)
    (select-window (agent-shell-overview--display))))

(defun agent-shell-overview-goto-number (number)
  "Show the shell numbered NUMBER in an ordinary window and select it.
The first ten live shells shown in the overview, top down, are numbered
1 to 9, then 0 for the tenth; the entries have no number.
Interactively, NUMBER is the digit of the key, 0 meaning 10.  The
overview stays open, as with `agent-shell-overview-goto-keep'."
  (interactive
   (list (if (and (characterp last-command-event)
                  (<= ?0 last-command-event ?9))
             (let ((digit (- last-command-event ?0)))
               (if (= digit 0) 10 digit))
           (read-number "Shell number: "))))
  (goto-char (or (text-property-any (point-min) (point-max)
                                    'agent-shell-overview-number number)
                 (user-error "No shell numbered %d" (% number 10))))
  (agent-shell-overview-goto-keep))

(defun agent-shell-overview-preview ()
  "Show the shell on this row in an ordinary window, keeping the focus here.
An entry is shown with its `:preview' function, or else its help is
shown in the echo area, see `agent-shell-overview-entry-functions'."
  (interactive)
  (if-let* ((entry (agent-shell-overview--entry)))
      (if-let* ((preview (plist-get entry :preview)))
          (funcall preview entry)
        (message "%s" (or (agent-shell-overview--entry-help entry)
                          (agent-shell-overview--title-of entry))))
    (agent-shell-overview--display)))

(defun agent-shell-overview-preview-next (n)
  "Move to the Nth next row and show its shell, keeping the focus here.
A negative N moves back.  See `agent-shell-overview-preview'."
  (interactive "p")
  (agent-shell-overview--move n)
  (when (agent-shell-overview-row-at-point)
    (agent-shell-overview-preview)))

(defun agent-shell-overview-preview-previous (n)
  "Move to the Nth previous row and show its shell, keeping the focus here."
  (interactive "p")
  (agent-shell-overview-preview-next (- n)))

(defun agent-shell-overview--preview-attention (step)
  "Preview the nearest row that asks for attention, below it if STEP is 1.
STEP -1 looks above.  See `agent-shell-overview-attention-states'.  The
search does not wrap around: a shell stays finished until it is
selected, so wrapping would visit the same shells again."
  (if-let* ((row (agent-shell-overview--find-row
                  step (lambda (id)
                         (agent-shell-overview--attention-p
                          (agent-shell-overview--row id))))))
      (progn
        (goto-char row)
        (agent-shell-overview-preview))
    (message "No more sessions")))

(defun agent-shell-overview-preview-next-attention ()
  "Move to the next row that asks for attention and show it, keeping the focus."
  (interactive)
  (agent-shell-overview--preview-attention 1))

(defun agent-shell-overview-preview-previous-attention ()
  "Move to the previous row that asks for attention and show it, keeping the focus."
  (interactive)
  (agent-shell-overview--preview-attention -1))

(defun agent-shell-overview-kill ()
  "Kill the shell on this row, after confirmation.
Killing the buffer ends the session, as agent-shell then shuts its
client down.  An entry is removed with its `:kill' function instead, see
`agent-shell-overview-entry-functions'."
  (interactive)
  (if-let* ((entry (agent-shell-overview--entry)))
      (progn
        (funcall (or (plist-get entry :kill)
                     (user-error "This row cannot be killed"))
                 entry)
        (agent-shell-overview-refresh))
    (let ((shell (agent-shell-overview--shell)))
      (when (yes-or-no-p (format "Kill %s? " (buffer-name shell)))
        (kill-buffer shell)
        (agent-shell-overview-refresh)))))

(defun agent-shell-overview-new ()
  "Start a new agent shell for the directory of the most recent ordinary window."
  (interactive)
  (agent-shell-overview-leave)
  (agent-shell-new-shell))

(defun agent-shell-overview-new-in-project ()
  "Start a new agent shell at the project root of the row at point.
The project is that of the directory of the shell or entry, see
`agent-shell-overview--directory', as `agent-shell-overview--location'
finds it, whether the overview groups by project or not."
  (interactive)
  (let* ((id (or (agent-shell-overview-row-at-point)
                 (user-error "No agent shell on this line")))
         (directory (or (agent-shell-overview--directory id)
                        (user-error "No directory for this row")))
         (root (car (agent-shell-overview--location directory))))
    (agent-shell-overview-leave)
    (let ((default-directory root))
      (agent-shell-new-shell))))

;;;###autoload
(defun agent-shell-overview-reload ()
  "Restart the agent of a shell and resume its session, after confirmation.
In the overview, the shell is that of the row at point; elsewhere, the
current agent shell.  See `agent-shell-overview-reload-shell'."
  (interactive)
  (if (derived-mode-p 'agent-shell-overview-mode)
      (let ((shell (agent-shell-overview--shell)))
        (when (y-or-n-p (format "Restart the agent of %s and resume its session? "
                                (buffer-name shell)))
          (agent-shell-overview-leave)
          (agent-shell-overview-reload-shell shell)
          (agent-shell-overview-refresh)))
    (unless (derived-mode-p 'agent-shell-mode)
      (user-error "Not an agent shell"))
    (when (y-or-n-p "Restart the agent and resume this session? ")
      (agent-shell-overview-reload-shell (current-buffer)))))

(defun agent-shell-overview-restart ()
  "Restart the shell on this row with a new session, after confirmation."
  (interactive)
  (let ((shell (agent-shell-overview--shell)))
    (when (yes-or-no-p (format "Restart %s with a new session? " (buffer-name shell)))
      (agent-shell-overview-leave)
      (with-current-buffer shell
        (agent-shell-restart))
      (agent-shell-overview-refresh))))

(defun agent-shell-overview-set-mode ()
  "Set the session mode of the shell on this row."
  (interactive)
  (with-current-buffer (agent-shell-overview--shell)
    (agent-shell-set-session-mode)))

(defun agent-shell-overview-set-model ()
  "Set the session model of the shell on this row."
  (interactive)
  (with-current-buffer (agent-shell-overview--shell)
    (agent-shell-set-session-model)))

(defun agent-shell-overview-interrupt ()
  "Interrupt the shell on this row, as `agent-shell-confirm-interrupt' says."
  (interactive)
  (with-current-buffer (agent-shell-overview--shell)
    (agent-shell-interrupt)))

(defun agent-shell-overview-view-traffic ()
  "View the traffic of the shell on this row."
  (interactive)
  (with-current-buffer (agent-shell-overview--shell)
    (agent-shell-view-traffic)))

(defun agent-shell-overview--then-next-row (function)
  "Call FUNCTION, then go to the row that followed this one.
Without such a row, go to the one that preceded it.  The row is that of
before the call, which may move or hide the row at point."
  (let ((next (when-let* ((row (or (agent-shell-overview--find-row 1)
                                   (agent-shell-overview--find-row -1))))
                (get-text-property row 'tabulated-list-id))))
    (funcall function)
    (when-let* ((row (agent-shell-overview--row-start next)))
      (goto-char row))))

(defun agent-shell-overview-toggle-unread ()
  "Toggle the shell on this row between idle and finished, as if unread.
Then go to the row that followed it, or else the one that preceded it,
without showing it.  A finished shell stays so until its window is
selected.  A shell in any other state is left as it is."
  (interactive)
  (let ((shell (agent-shell-overview--shell)))
    (agent-shell-overview--then-next-row
     (lambda ()
       (setf (buffer-local-value 'agent-shell-overview--finished shell)
             (pcase (agent-shell-overview-state shell)
               ('ready t)
               ('finished nil)
               (_ (user-error "Only an idle or finished shell can be marked"))))
       (agent-shell-overview--tick)))))

;;;###autoload
(defun agent-shell-overview-toggle-mute (&optional shell)
  "Mute or unmute agent SHELL.
A muted shell keeps running but never asks for attention, and the
overview lists it in its Parked group.  Interactively, SHELL is the
shell of the row at point in the overview, and point goes to the row
that followed it, or else the one that preceded it, so that repeating
the command goes on down the list; elsewhere, it is the current agent
shell."
  (interactive)
  (if (and (not shell) (derived-mode-p 'agent-shell-overview-mode))
      (let ((shell (agent-shell-overview--shell)))
        (agent-shell-overview--then-next-row
         (lambda () (agent-shell-overview--toggle-mute shell))))
    (agent-shell-overview--toggle-mute (or shell (current-buffer)))))

(easy-menu-define agent-shell-overview-menu nil
  "The popup menu of a row of the overview.
Each item shows the key of its command in the overview."
  '("Agent shell"
    ["Jump" agent-shell-overview-goto]
    ["Interrupt" agent-shell-overview-interrupt]
    ["Mark unread / read" agent-shell-overview-toggle-unread]
    ["Mute / unmute" agent-shell-overview-toggle-mute]
    ["Set mode" agent-shell-overview-set-mode]
    ["Set model" agent-shell-overview-set-model]
    ["View traffic" agent-shell-overview-view-traffic]
    ["Reload" agent-shell-overview-reload]
    ["Restart" agent-shell-overview-restart]
    ["Kill" agent-shell-overview-kill]
    "--"
    ["New shell" agent-shell-overview-new]
    ["New shell in project" agent-shell-overview-new-in-project]
    ["Group by project / list as one" agent-shell-overview-toggle-grouping]
    ["Detailed, standard or compact list" agent-shell-overview-cycle-compact]
    ["Move to the next side" agent-shell-overview-cycle-side]
    ["Toggle logging" agent-shell-toggle-logging]))

(defun agent-shell-overview-click (event)
  "Show the shell on the row clicked by EVENT, as with RET.
An entry with a `:confirm' prompt is gone to only after confirmation.
A click on a segment with an `agent-shell-overview-action' property
calls that function with the row instead."
  (interactive "e")
  (posn-set-point (event-end event))
  (if-let* ((action (get-text-property (point) 'agent-shell-overview-action))
            (id (agent-shell-overview-row-at-point)))
      (funcall action id)
    (let ((prompt (plist-get (agent-shell-overview--entry) :confirm)))
      (when (or (not prompt) (y-or-n-p prompt))
        (agent-shell-overview-goto-keep)))))

(defun agent-shell-overview-mouse-menu (event)
  "Pop up a menu of the actions on the row clicked by EVENT and run one.
See `agent-shell-overview-menu'."
  (interactive "e")
  (posn-set-point (event-end event))
  (popup-menu agent-shell-overview-menu event))

(defvar-keymap agent-shell-overview-mode-map
  :doc "Keymap of `agent-shell-overview-mode'.
A command added here finds its row with
`agent-shell-overview-row-at-point'."
  :parent tabulated-list-mode-map
  "RET" #'agent-shell-overview-goto-keep
  "S-<return>" #'agent-shell-overview-goto
  "1" #'agent-shell-overview-goto-number
  "2" #'agent-shell-overview-goto-number
  "3" #'agent-shell-overview-goto-number
  "4" #'agent-shell-overview-goto-number
  "5" #'agent-shell-overview-goto-number
  "6" #'agent-shell-overview-goto-number
  "7" #'agent-shell-overview-goto-number
  "8" #'agent-shell-overview-goto-number
  "9" #'agent-shell-overview-goto-number
  "0" #'agent-shell-overview-goto-number
  "SPC" #'agent-shell-overview-preview
  "n" #'agent-shell-overview-preview-next
  "p" #'agent-shell-overview-preview-previous
  "TAB" #'agent-shell-overview-preview-next-attention
  "<backtab>" #'agent-shell-overview-preview-previous-attention
  "g" #'agent-shell-overview-refresh
  "S" #'agent-shell-overview-cycle-sort
  "f" #'agent-shell-overview-cycle-filter
  "q" #'agent-shell-overview-quit
  "k" #'agent-shell-overview-kill
  "u" #'agent-shell-overview-toggle-unread
  "z" #'agent-shell-overview-toggle-mute
  "c" #'agent-shell-overview-new
  "N" #'agent-shell-overview-new-in-project
  "r" #'agent-shell-overview-reload
  "R" #'agent-shell-overview-restart
  "m" #'agent-shell-overview-set-mode
  "M" #'agent-shell-overview-set-model
  "C-c C-c" #'agent-shell-overview-interrupt
  "t" #'agent-shell-overview-view-traffic
  "l" #'agent-shell-toggle-logging
  "G" #'agent-shell-overview-toggle-grouping
  "C" #'agent-shell-overview-cycle-compact
  ;; The column widths come from `agent-shell-overview-columns' at each
  ;; redraw, so the width commands of `tabulated-list-mode' cannot work.
  "{" #'undefined
  "}" #'undefined
  "w" #'agent-shell-overview-cycle-side)

(defun agent-shell-overview--set-layout (layout)
  "Give this overview buffer the header line of LAYOUT.
The vertical layout has no column titles, so it shows the global header
line.  Its lines follow at the next redraw."
  (setq agent-shell-overview--layout layout)
  (if (eq layout 'vertical)
      (kill-local-variable 'header-line-format)
    (setq tabulated-list-format (agent-shell-overview--format))
    (tabulated-list-init-header)))

(defun agent-shell-overview--first-row ()
  "Return the start of the first row of the overview, or nil."
  (text-property-not-all (point-min) (point-max) 'tabulated-list-id nil))

(defun agent-shell-overview--revert (&rest _)
  "Redraw the overview, as `agent-shell-overview-refresh' does.
The value of `revert-buffer-function' in the overview.  When the buffer
is not in the side window of the overview, it is redrawn as it is.
`tabulated-list-revert-hook' runs first, as `tabulated-list-revert'
runs it."
  (run-hooks 'tabulated-list-revert-hook)
  (if (agent-shell-overview--window)
      (agent-shell-overview-refresh)
    (agent-shell-overview--print)))

(define-derived-mode agent-shell-overview-mode tabulated-list-mode "Agent Shells"
  "Major mode of the overview of the agent shells, see `agent-shell-overview'.
\\{agent-shell-overview-mode-map}"
  ;; A blank column, then the number of the row; the state cells start
  ;; with a blank of their own, for its face.
  (setq tabulated-list-padding 2)
  (setq tabulated-list-printer #'agent-shell-overview--print-entry)
  (setq-local revert-buffer-function #'agent-shell-overview--revert)
  (agent-shell-overview--set-layout 'horizontal))

(defun agent-shell-overview--show (&optional row)
  "Show the overview on `agent-shell-overview-side' of this frame, and select it.
Its window on any frame closes first.  Point goes to buffer position
ROW, or to the first row.  Enable tracking and polling.  The projects
and locations of the directories are found afresh, see
`agent-shell-overview--location'."
  ;; VC keeps what it found of each directory, and project.el with it.
  (maphash (lambda (directory _)
             (vc-file-clearprops (file-name-as-directory (file-truename directory))))
           agent-shell-overview--locations)
  (clrhash agent-shell-overview--locations)
  (unless agent-shell-overview-tracking-mode
    (agent-shell-overview-tracking-mode 1))
  (when-let* ((window (agent-shell-overview--window)))
    (delete-window window))
  (let* ((buffer (get-buffer-create agent-shell-overview--buffer))
         (side agent-shell-overview-side)
         (vertical (memq side '(left right))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'agent-shell-overview-mode)
        (agent-shell-overview-mode))
      (agent-shell-overview--set-layout (if vertical 'vertical 'horizontal))
      (when row
        (goto-char row)))
    (select-window
     (display-buffer-in-side-window
      buffer
      `((side . ,side)
        (slot . 0)
        (dedicated . t)
        ,@(if vertical
              `((window-width . (body-columns . ,agent-shell-overview-vertical-width))
                (preserve-size . (t . nil)))
            '((window-height . agent-shell-overview--fit)
              (preserve-size . (nil . t)))))))
    ;; Drawn once shown, as the group headers take the width of the window.
    (agent-shell-overview-refresh)
    (agent-shell-overview--poll-start)
    (unless row
      (goto-char (or (agent-shell-overview--first-row) (point-min))))))

(defun agent-shell-overview--window-here ()
  "Return the side window showing the overview on this frame, or nil."
  (when-let* ((window (agent-shell-overview--window)))
    (and (eq (window-frame window) (selected-frame)) window)))

;;;###autoload
(defun agent-shell-overview ()
  "Show the overview of the agent shells on this frame and select it, or close it.
Selected, it closes.  Shown on this frame, it gets selected.  Shown on
another frame, it moves here.  It opens on `agent-shell-overview-side'."
  (interactive)
  (if-let* ((window (agent-shell-overview--window-here)))
      (if (eq window (selected-window))
          (agent-shell-overview-quit)
        (select-window window))
    (agent-shell-overview--show)))

;;;###autoload
(defun agent-shell-overview-cycle-side ()
  "Move the overview to the next side, staying on its row.
The sides cycle from bottom to left, top and right, and the side lasts
for the session, see `agent-shell-overview-side'.  When the
overview is not shown on this frame, show it here on the current side
instead."
  (interactive)
  (if-let* ((window (agent-shell-overview--window-here)))
      ;; The start of the row, as an offset in it means nothing in the
      ;; other layout.
      (let ((row (with-current-buffer (window-buffer window)
                   (save-excursion
                     (goto-char (window-point window))
                     (or (agent-shell-overview--row-start
                          (agent-shell-overview-row-at-point))
                         (pos-bol))))))
        (setq agent-shell-overview-side
              (or (cadr (memq agent-shell-overview-side agent-shell-overview--sides))
                  (car agent-shell-overview--sides)))
        (agent-shell-overview--show row))
    (agent-shell-overview--show)))

(provide 'agent-shell-overview)
;;; agent-shell-overview.el ends here
