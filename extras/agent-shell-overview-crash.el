;;; agent-shell-overview-crash.el --- Crashed agents in the agent-shell overview -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Frédéric Jolliton

;; Author: Frédéric Jolliton
;; Maintainer: Frédéric Jolliton
;; URL: https://github.com/fjolliton/agent-shell-overview
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (agent-shell-overview "0.1.0"))
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

;; `agent-shell-overview-crash-mode' shows in the overview the agent
;; shells whose agent crashed, in a state of their own, `crashed', or
;; `oom' when earlyoom killed it for lack of memory.  Both ask for
;; attention, before any other state.  The tooltip of such a row tells
;; the cause of the crash, and `M-r' in the overview,
;; `agent-shell-overview-crash-reload-all', restarts the agents of all
;; the crashed shells and resumes their sessions.
;;
;; A crash is seen in two ways:
;;
;; - The agent process is no longer live, yet the shell still holds it.
;;   A deliberate stop drops it from the shell first, so only a death
;;   of its own is taken for a crash.
;; - The agent was seen with a child process of a given command, then
;;   twice in a row without one.  The agent does not start it again, so
;;   it answers no more, although it still runs.  A periodic `ps' looks
;;   for that child, see `agent-shell-overview-crash-sample-interval'
;;   and `agent-shell-overview-crash-child-command', which can disable
;;   this check.
;;
;; Once a crash is seen, a single look in the log of earlyoom, see
;; `agent-shell-overview-crash-oom-command', tells whether it killed the
;; agent.  That look is for hosts running earlyoom under systemd, and
;; can be disabled.
;;
;; This add-on is meant for Linux and the BSDs: it relies on `ps', and
;; optionally on `journalctl' and earlyoom.  To enable it, with this
;; file in the extras directory of the package:
;;
;;   (add-to-list 'load-path "/path/to/agent-shell-overview/extras")
;;   (require 'agent-shell-overview-crash)
;;   (agent-shell-overview-crash-mode 1)

;;; Code:

(require 'agent-shell-overview)
(require 'easymenu)
(require 'map)
(require 'seq)
(require 'subr-x)

(defvar agent-shell--state)

;;;; Customization

(defgroup agent-shell-overview-crash nil
  "Crashed agents in the agent-shell overview."
  :group 'agent-shell-overview
  :prefix "agent-shell-overview-crash-")

(defcustom agent-shell-overview-crash-child-command
  "\\`\\.?claude\\(?:-wrapped\\)?\\'"
  "Regexp matching the command name of the child process of an agent, or nil.
It is matched against the command name `ps' gives of each direct child
of an agent process.  An agent seen with such a child, then without one,
has crashed.

The default matches the Claude Code process that Claude's ACP adapter
runs as a child, and which it does not start again when it dies: the
adapter keeps running without answering.  The adapters of other agents
may run a CLI of their own as a child, which this regexp can match
instead.  It is a single regexp for every agent: to watch the children
of several types of agent, it matches all their command names.

Nil disables this check, and the `ps' that samples the processes."
  :type '(choice (const :tag "No check" nil)
                 regexp))

(defcustom agent-shell-overview-crash-sample-interval 10
  "Seconds at least between two samples of the processes of the agents.
A sample looks for the child process of each agent, see
`agent-shell-overview-crash-child-command'."
  :type 'number)

(defcustom agent-shell-overview-crash-message-regexp
  "Claude Agent process died: \\(.*\\)"
  "Regexp of the line an agent writes in its shell when its child dies.
Its first group is the cause, which the tooltip of a crashed shell
tells.  The default is the line Claude's ACP adapter writes when its
Claude Code process dies.  For another agent, it is a regexp of the line
that agent writes, or the default, which then never matches: the
tooltip tells the exit status instead."
  :type 'regexp)

(defcustom agent-shell-overview-crash-oom-command
  '("journalctl" "-u" "earlyoom" "-o" "cat" "--no-pager" "--since" "-15min")
  "Command printing the recent log of earlyoom, or nil for no lookup.
Once a crash is seen, it runs once, and a line of its output telling
earlyoom sent a signal to the agent or its child process turns
the crash into an `oom' one.  The default is for hosts running earlyoom
under systemd.  A failure of the command changes nothing."
  :type '(choice (const :tag "No lookup" nil)
                 (repeat :tag "Command" string)))

;;;; Agent processes

(defun agent-shell-overview-crash--agent-process (buffer)
  "Return the agent process of agent shell BUFFER, or nil."
  ;; `agent-shell--state' is internal to agent-shell, `:process' to acp.
  (ignore-errors
    (map-nested-elt (buffer-local-value 'agent-shell--state buffer)
                    '(:client :process))))

(defun agent-shell-overview-crash--agent-pid (buffer)
  "Return the pid of the agent process of agent shell BUFFER, or nil."
  (when-let* ((agent (agent-shell-overview-crash--agent-process buffer))
              ((processp agent)))
    (process-id agent)))

(defvar-local agent-shell-overview-crash--child-pid nil
  "The child process of this shell's agent last seen by a sample, or nil.
It is (AGENT CHILD COMMAND): the pids of the agent and of its child
process, and the command name of the child.  See
`agent-shell-overview-crash-child-command'.")

(defvar-local agent-shell-overview-crash--child-missing nil
  "Non-nil when the last sample saw this shell's agent without its child.")

;;;; Crashes

(defvar-local agent-shell-overview-crash--crash nil
  "How the agent of this shell crashed, or nil while it has not.
It is (STATE MESSAGE STATUS): STATE is `crashed', or `oom' once earlyoom
is known to have killed it; MESSAGE is what the agent wrote of the death
of its child process, or nil; STATUS is how the death was seen.
Once set, it stays: the agent of a crashed shell answers no more.")

(defconst agent-shell-overview-crash--oom-line
  "^sending SIG[A-Z0-9]+ to process \\([0-9]+\\) "
  "Regexp of a line of earlyoom killing a process, whose pid is its first group.")

(defun agent-shell-overview-crash--message (buffer)
  "Return the cause of the last death of a child written in BUFFER, or nil.
See `agent-shell-overview-crash-message-regexp'."
  (with-current-buffer buffer
    (save-excursion
      (save-restriction
        (widen)
        (goto-char (point-max))
        (when (re-search-backward agent-shell-overview-crash-message-regexp nil t)
          (string-trim (match-string-no-properties 1)))))))

(defun agent-shell-overview-crash--oom-killed-p (output pids)
  "Return non-nil if earlyoom log OUTPUT tells it killed one of PIDS."
  (let ((start 0)
        found)
    (while (and (not found)
                (string-match agent-shell-overview-crash--oom-line output start))
      (setq start (match-end 0)
            found (memql (string-to-number (match-string 1 output)) pids)))
    found))

(defun agent-shell-overview-crash--record (buffer status pids)
  "Record that the agent of agent shell BUFFER crashed, unless already done.
STATUS tells how the crash was seen, and PIDS are those of the agent and
of its child process, or nil for one unknown.  The crash is
recorded at once, then `agent-shell-overview-crash-oom-command', unless
nil, runs once and turns it into `oom' when its output tells earlyoom
killed one of PIDS.  A failed lookup changes nothing."
  (with-current-buffer buffer
    (unless agent-shell-overview-crash--crash
      (setq agent-shell-overview-crash--crash
            (list 'crashed (agent-shell-overview-crash--message buffer) status))
      (when agent-shell-overview-crash-oom-command
        (let ((chunks nil)
              ;; A remote or vanished directory would fail the local process.
              (default-directory temporary-file-directory))
          (ignore-errors
            (make-process
             :name "agent-shell-overview-crash-oom"
             :command agent-shell-overview-crash-oom-command
             :buffer nil
             :connection-type 'pipe
             :noquery t
             :filter (lambda (_process output) (push output chunks))
             :sentinel
             (lambda (process _event)
               (unless (process-live-p process)
                 (ignore-errors
                   (when (buffer-live-p buffer)
                     (with-current-buffer buffer
                       ;; The agent may write its line after the crash is seen.
                       (unless (nth 1 agent-shell-overview-crash--crash)
                         (setf (nth 1 agent-shell-overview-crash--crash)
                               (agent-shell-overview-crash--message buffer)))
                       (when (and (eq (process-status process) 'exit)
                                  (zerop (process-exit-status process))
                                  (agent-shell-overview-crash--oom-killed-p
                                   (apply #'concat (nreverse chunks))
                                   (delq nil (copy-sequence pids))))
                         (setf (car agent-shell-overview-crash--crash) 'oom)))
                     (agent-shell-overview-refresh))))))))))))

(defun agent-shell-overview-crash--check (buffer)
  "Return the crash state of agent shell BUFFER, `crashed', `oom' or nil.
An agent process still in the client but no longer live died on its own:
a deliberate stop, `agent-shell--shutdown', has `acp-shutdown' drop the
process from the client before it dies, so it is never taken for a
crash.  The crash is recorded, see `agent-shell-overview-crash--record'.
A crash seen by a sample of the processes is returned as well."
  (let ((agent (agent-shell-overview-crash--agent-process buffer)))
    (when (and (processp agent)
               (not (process-live-p agent))
               (not (buffer-local-value 'agent-shell-overview-crash--crash buffer)))
      (let ((seen (buffer-local-value 'agent-shell-overview-crash--child-pid buffer))
            (pid (process-id agent)))
        (agent-shell-overview-crash--record
         buffer
         (format "Agent %s %d" (process-status agent) (process-exit-status agent))
         (list pid (and (eql (car seen) pid) (cadr seen))))))
    (car (buffer-local-value 'agent-shell-overview-crash--crash buffer))))

(defun agent-shell-overview-crash--help (buffer)
  "Return what the overview tells of the crash of agent shell BUFFER, or nil."
  (pcase (buffer-local-value 'agent-shell-overview-crash--crash buffer)
    (`(,state ,message ,status)
     (let ((detail (or message status)))
       (if (eq state 'oom)
           (concat "Killed by earlyoom (out of memory)"
                   (and detail (concat ": " detail)))
         detail)))))

;;;; Samples of the processes

(defvar agent-shell-overview-crash--sample-started nil
  "The `float-time' the last sample of the agent processes started, or nil.")

(defvar agent-shell-overview-crash--sample-process nil
  "The `ps' process of the running sample of the agent processes, or nil.")

(defun agent-shell-overview-crash--children (output pids)
  "Return a (PID CHILD COMMAND) list for each of PIDS found in OUTPUT.
CHILD is the pid of a direct child of PID whose command name, COMMAND,
matches `agent-shell-overview-crash-child-command'; both are omitted
when PID has no such child, or when that option is nil.  OUTPUT is
that of \"ps -e -o pid=,ppid=,comm=\", whose command name may hold
spaces; the lines it does not parse are skipped.  A pid missing from
OUTPUT is missing from the result."
  (let ((commands (make-hash-table))
        (children (make-hash-table)))
    (dolist (line (split-string output "\n" t))
      (when (string-match
             "\\`[ \t]*\\([0-9]+\\)[ \t]+\\([0-9]+\\)[ \t]+\\(.*?\\)[ \t]*\\'"
             line)
        (let ((pid (string-to-number (match-string 1 line)))
              (ppid (string-to-number (match-string 2 line))))
          (puthash pid (match-string 3 line) commands)
          (push pid (gethash ppid children)))))
    (seq-keep
     (lambda (pid)
       (when (gethash pid commands)
         (let ((child (and agent-shell-overview-crash-child-command
                           (seq-find
                            (lambda (child)
                              (string-match-p agent-shell-overview-crash-child-command
                                              (gethash child commands "")))
                            (gethash pid children)))))
           (if child
               (list pid child (gethash child commands))
             (list pid)))))
     pids)))

(defun agent-shell-overview-crash--check-sample (children agents)
  "Record from CHILDREN what a sample tells of the agents of AGENTS.
CHILDREN is the result of `agent-shell-overview-crash--children', and
AGENTS the (BUFFER . PID) pairs of the shells sampled.  An agent seen
with a child process has its pid remembered; an agent seen without one
in two samples in a row, once one was seen, has crashed, as the agent
never starts it again.  A single sample may fall between two child
processes, and an agent just started, before its first one, is no
crash."
  (pcase-dolist (`(,buffer . ,pid) agents)
    (when-let* (((buffer-live-p buffer))
                ((eql pid (agent-shell-overview-crash--agent-pid buffer)))
                (found (assq pid children)))
      (let ((child (cdr found))
            (seen (buffer-local-value 'agent-shell-overview-crash--child-pid buffer)))
        (cond (child
               (with-current-buffer buffer
                 (setq agent-shell-overview-crash--child-pid found
                       agent-shell-overview-crash--child-missing nil)))
              ((not (eql (car seen) pid)))
              ((buffer-local-value 'agent-shell-overview-crash--child-missing buffer)
               (agent-shell-overview-crash--record
                buffer
                (if (nth 2 seen)
                    (format "Child process %d (%s) gone" (nth 1 seen) (nth 2 seen))
                  (format "Child process %d gone" (nth 1 seen)))
                (list pid (nth 1 seen))))
              (t
               (with-current-buffer buffer
                 (setq agent-shell-overview-crash--child-missing t))))))))

(defun agent-shell-overview-crash--sample ()
  "Start a sample of the processes of the agents, unless one is recent.
A single `ps' lists every process; once it ends, a child process gone
from an agent is recorded as a crash, see
`agent-shell-overview-crash--check-sample', and the overview is
redrawn.  A sample starts at most every
`agent-shell-overview-crash-sample-interval' seconds, never while one
runs, and never while `agent-shell-overview-crash-child-command' is
nil.  A failed sample changes nothing.  Never signals, as it runs from
a timer and a sentinel."
  (ignore-errors
    (let ((now (float-time)))
      (unless (or (null agent-shell-overview-crash-child-command)
                  (process-live-p agent-shell-overview-crash--sample-process)
                  (and agent-shell-overview-crash--sample-started
                       (< (- now agent-shell-overview-crash--sample-started)
                          agent-shell-overview-crash-sample-interval)))
        (setq agent-shell-overview-crash--sample-started now)
        (when-let* ((agents (seq-keep
                             (lambda (buffer)
                               (when-let* ((pid (agent-shell-overview-crash--agent-pid
                                                 buffer)))
                                 (cons buffer pid)))
                             (agent-shell-overview-shells))))
          (let ((chunks nil)
                ;; A remote or vanished directory would fail the local process.
                (default-directory temporary-file-directory))
            (setq agent-shell-overview-crash--sample-process
                  (ignore-errors
                    (make-process
                     :name "agent-shell-overview-crash-ps"
                     :command '("ps" "-e" "-o" "pid=,ppid=,comm=")
                     :buffer nil
                     :connection-type 'pipe
                     :noquery t
                     :filter (lambda (_process output) (push output chunks))
                     :sentinel
                     (lambda (process _event)
                       (unless (process-live-p process)
                         (ignore-errors
                           (when (and (eq (process-status process) 'exit)
                                      (zerop (process-exit-status process)))
                             (agent-shell-overview-crash--check-sample
                              (agent-shell-overview-crash--children
                               (apply #'concat (nreverse chunks))
                               (mapcar #'cdr agents))
                              agents)))
                         (ignore-errors (agent-shell-overview-refresh)))))))))))))

(defun agent-shell-overview-crash--watch ()
  "Check each live agent shell for a crash, then sample the agents.
See `agent-shell-overview-crash--check' and
`agent-shell-overview-crash--sample'.  Nothing is done while no agent
shell lives."
  (when-let* ((shells (agent-shell-overview-shells)))
    (dolist (shell shells)
      (ignore-errors (agent-shell-overview-crash--check shell)))
    (agent-shell-overview-crash--sample)))

;;;; Commands

(defun agent-shell-overview-crash-reload-all ()
  "Restart the agents of all crashed shells and resume their sessions.
A crashed shell is in the `oom' or `crashed' state, see
`agent-shell-overview-crash-mode'.  Asks once for all.  Each reload
starts a new shell buffer in place of the old one, see
`agent-shell-overview-reload-shell'."
  (interactive)
  (let ((shells (seq-filter (lambda (buffer)
                              (memq (agent-shell-overview-state buffer)
                                    '(oom crashed)))
                            (agent-shell-overview-shells))))
    (cond ((null shells) (message "No crashed sessions"))
          ((y-or-n-p (format "Restart the agents of %d crashed sessions and resume them? "
                             (length shells)))
           (agent-shell-overview-leave)
           (dolist (shell shells)
             (agent-shell-overview-reload-shell shell))
           (agent-shell-overview-refresh)))))

;;;; Mode

(defconst agent-shell-overview-crash--states
  '((oom "⚠" "OOM" agent-shell-overview-blocked nil)
    (crashed "⚠" "Crashed" agent-shell-overview-blocked nil))
  "The states of `agent-shell-overview-crash-mode', the most urgent first.")

(defconst agent-shell-overview-crash--menu-item
  ["Reload all crashed" agent-shell-overview-crash-reload-all]
  "The item of `agent-shell-overview-menu' of the crash mode.")

(defvar agent-shell-overview-crash--added-states nil
  "The states the crash mode added to `agent-shell-overview-states'.")

(defvar agent-shell-overview-crash--added-attention nil
  "The states the crash mode added to `agent-shell-overview-attention-states'.")

(defvar agent-shell-overview-crash--previous-key nil
  "The own binding of the key of the crash mode before the mode took it.
The key is that of `agent-shell-overview-crash-reload-all' in
`agent-shell-overview-mode-map'.  It is nil when the map had no binding
of its own there.")

(defun agent-shell-overview-crash--own-key ()
  "Return the own binding of the key of the crash mode, or nil.
The key is that of `agent-shell-overview-crash-reload-all' in
`agent-shell-overview-mode-map'.  It is nil when the key is unbound, or
bound as in the parent keymap alone."
  (let ((binding (keymap-lookup agent-shell-overview-mode-map "M-r"))
        (parent (keymap-parent agent-shell-overview-mode-map)))
    (unless (and parent (equal binding (keymap-lookup parent "M-r")))
      binding)))

(defun agent-shell-overview-crash--enable ()
  "Add the states, hooks, key and menu item of the crash mode, unless present."
  (dolist (state (reverse agent-shell-overview-crash--states))
    (unless (assq (car state) agent-shell-overview-states)
      (push state agent-shell-overview-states)
      (push (car state) agent-shell-overview-crash--added-states)))
  (dolist (state (reverse (mapcar #'car agent-shell-overview-crash--states)))
    (unless (memq state agent-shell-overview-attention-states)
      (push state agent-shell-overview-attention-states)
      (push state agent-shell-overview-crash--added-attention)))
  (add-hook 'agent-shell-overview-state-functions #'agent-shell-overview-crash--check)
  (add-hook 'agent-shell-overview-help-functions #'agent-shell-overview-crash--help)
  (add-hook 'agent-shell-overview-refresh-hook #'agent-shell-overview-crash--watch)
  (let ((own (agent-shell-overview-crash--own-key)))
    (unless (eq own #'agent-shell-overview-crash-reload-all)
      (setq agent-shell-overview-crash--previous-key own)
      (keymap-set agent-shell-overview-mode-map "M-r"
                  #'agent-shell-overview-crash-reload-all)))
  (easy-menu-remove-item agent-shell-overview-menu nil
                         (aref agent-shell-overview-crash--menu-item 0))
  (easy-menu-add-item agent-shell-overview-menu nil
                      agent-shell-overview-crash--menu-item "Restart"))

(defun agent-shell-overview-crash--disable ()
  "Remove what `agent-shell-overview-crash--enable' added."
  (setq agent-shell-overview-states
        (seq-remove (lambda (state)
                      (memq (car state) agent-shell-overview-crash--added-states))
                    agent-shell-overview-states)
        agent-shell-overview-attention-states
        (seq-remove (lambda (state)
                      (memq state agent-shell-overview-crash--added-attention))
                    agent-shell-overview-attention-states)
        agent-shell-overview-crash--added-states nil
        agent-shell-overview-crash--added-attention nil)
  (remove-hook 'agent-shell-overview-state-functions #'agent-shell-overview-crash--check)
  (remove-hook 'agent-shell-overview-help-functions #'agent-shell-overview-crash--help)
  (remove-hook 'agent-shell-overview-refresh-hook #'agent-shell-overview-crash--watch)
  (when (eq (agent-shell-overview-crash--own-key)
            #'agent-shell-overview-crash-reload-all)
    (if agent-shell-overview-crash--previous-key
        (keymap-set agent-shell-overview-mode-map "M-r"
                    agent-shell-overview-crash--previous-key)
      (keymap-unset agent-shell-overview-mode-map "M-r" t)))
  (setq agent-shell-overview-crash--previous-key nil)
  (easy-menu-remove-item agent-shell-overview-menu nil
                         (aref agent-shell-overview-crash--menu-item 0))
  (when (process-live-p agent-shell-overview-crash--sample-process)
    (delete-process agent-shell-overview-crash--sample-process))
  (setq agent-shell-overview-crash--sample-process nil
        agent-shell-overview-crash--sample-started nil))

;;;###autoload
(define-minor-mode agent-shell-overview-crash-mode
  "Show the agent shells whose agent crashed in the overview.
A crashed shell is in the `crashed' state, or `oom' when earlyoom killed
its agent, see `agent-shell-overview-crash-oom-command'.  Both ask for
attention before the other states, and the tooltip of the row tells the
cause.  An agent has crashed when its process died on its own, or when
its child process is gone, see
`agent-shell-overview-crash-child-command'.

\\<agent-shell-overview-mode-map>\\[agent-shell-overview-crash-reload-all] \
in the overview, also in its menu, restarts the agents of all the
crashed shells, see `agent-shell-overview-crash-reload-all'."
  :global t
  :group 'agent-shell-overview-crash
  (if agent-shell-overview-crash-mode
      (agent-shell-overview-crash--enable)
    (agent-shell-overview-crash--disable))
  (ignore-errors (agent-shell-overview-refresh)))

(provide 'agent-shell-overview-crash)
;;; agent-shell-overview-crash.el ends here
