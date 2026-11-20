;;; agent-shell-overview-memory.el --- Memory column for agent-shell-overview -*- lexical-binding: t; -*-

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

;; `agent-shell-overview-memory-mode' adds a Mem column to the
;; overview of `agent-shell-overview', after the session title: the
;; memory each agent uses, as the summed resident set size of the
;; process tree of its agent process, such as "0.8G", "1.2G" or "12G".
;;
;;   (add-to-list 'load-path "/path/to/agent-shell-overview/extras")
;;   (require 'agent-shell-overview-memory)
;;   (agent-shell-overview-memory-mode 1)
;;
;; The memory is sampled on the polling ticks of the overview, at most
;; every `agent-shell-overview-memory-interval' seconds, by a single
;; `ps' run in the background that lists every process.  That `ps' must
;; support "-o pid=,ppid=,rss=,comm=", as on Linux and the BSDs.

;;; Code:

(require 'agent-shell-overview)
(require 'map)
(require 'seq)
(require 'subr-x)

(defvar agent-shell--state)

(defcustom agent-shell-overview-memory-interval 10
  "Seconds between two samples of the memory of the agents."
  :type 'number
  :group 'agent-shell-overview)

(defvar agent-shell-overview-memory--sample nil
  "The last sample of the memory of the agents, or nil.
It is (TIME . TREES), with TIME the `float-time' the sample was taken
and TREES a list of (PID KB): an agent pid and the RSS of its process
tree in kB.  See `agent-shell-overview-memory--start'.")

(defvar agent-shell-overview-memory--started nil
  "The `float-time' the last sample of the memory started, or nil.")

(defvar agent-shell-overview-memory--process nil
  "The `ps' process of the running sample of the memory, or nil.")

(defun agent-shell-overview-memory--agent-pid (buffer)
  "Return the pid of the agent process of agent shell BUFFER, or nil."
  ;; `agent-shell--state' is internal to agent-shell, `:process' to acp.el.
  (when-let* ((agent (map-nested-elt (buffer-local-value 'agent-shell--state buffer)
                                     '(:client :process)))
              ((processp agent)))
    (process-id agent)))

(defun agent-shell-overview-memory--trees (output pids)
  "Return a (PID KB) list for each of PIDS found in OUTPUT.
KB is the summed RSS of the process tree of PID.  OUTPUT is that of
\"ps -e -o pid=,ppid=,rss=,comm=\", in kB, whose command name may hold
spaces; lines it does not parse are skipped.  A pid missing from OUTPUT
is missing from the result."
  (let ((rss (make-hash-table))
        (children (make-hash-table)))
    (dolist (line (split-string output "\n" t))
      (when (string-match "\\`[ \t]*\\([0-9]+\\)[ \t]+\\([0-9]+\\)[ \t]+\\([0-9]+\\)[ \t]+.*\\'"
                          line)
        (let ((pid (string-to-number (match-string 1 line)))
              (ppid (string-to-number (match-string 2 line))))
          (puthash pid (string-to-number (match-string 3 line)) rss)
          (push pid (gethash ppid children)))))
    (seq-keep
     (lambda (pid)
       (when (gethash pid rss)
         ;; The seen pids guard against a loop in a malformed output.
         (let ((seen (make-hash-table))
               (stack (list pid))
               (total 0))
           (while stack
             (let ((next (pop stack)))
               (unless (gethash next seen)
                 (puthash next t seen)
                 (setq total (+ total (gethash next rss 0)))
                 (setq stack (append (gethash next children) stack)))))
           (list pid total))))
     pids)))

(defun agent-shell-overview-memory--start ()
  "Start a sample of the memory of the agents, unless one is recent.
A single `ps' lists every process; once it ends,
`agent-shell-overview-memory--sample' gets the RSS of the process tree
of each agent, and the overview is redrawn.  A sample starts at most
every `agent-shell-overview-memory-interval' seconds, and never while
one runs.  A failed sample leaves no sizes.  Never signals, as it runs
from a timer and a sentinel."
  (ignore-errors
    (let ((now (float-time)))
      (unless (or (process-live-p agent-shell-overview-memory--process)
                  (and agent-shell-overview-memory--started
                       (< (- now agent-shell-overview-memory--started)
                          agent-shell-overview-memory-interval)))
        (setq agent-shell-overview-memory--started now)
        (let ((pids (seq-keep #'agent-shell-overview-memory--agent-pid
                              (agent-shell-overview-shells)))
              (chunks nil))
          (setq agent-shell-overview-memory--process
                (condition-case nil
                    (make-process
                     :name "agent-shell-overview-memory"
                     :command '("ps" "-e" "-o" "pid=,ppid=,rss=,comm=")
                     :buffer nil
                     :connection-type 'pipe
                     :noquery t
                     :filter (lambda (_process output) (push output chunks))
                     :sentinel
                     (lambda (process _event)
                       ;; A sample whose process was deleted, as the mode
                       ;; was disabled, is dropped.
                       (when (and (not (process-live-p process))
                                  (eq process agent-shell-overview-memory--process))
                         (setq agent-shell-overview-memory--process nil
                               agent-shell-overview-memory--sample
                               (ignore-errors
                                 (and (eq (process-status process) 'exit)
                                      (zerop (process-exit-status process))
                                      (cons now (agent-shell-overview-memory--trees
                                                 (apply #'concat (nreverse chunks))
                                                 pids)))))
                         (ignore-errors (agent-shell-overview-refresh)))))
                  (error (setq agent-shell-overview-memory--sample nil)))))))))

(defun agent-shell-overview-memory--size (kb)
  "Return KB kilobytes as \"0.8G\" or \"12G\".
Below 10 GiB in GiB with one decimal, and in whole GiB above, so that
the sizes of a column compare at a glance.  The result is empty when KB
is nil."
  (cond ((null kb) "")
        ;; From 9.95 GiB, one decimal would round up to "10.0G".
        ((< kb (* 9.95 1048576)) (format "%.1fG" (/ kb 1048576.0)))
        (t (format "%dG" (round kb 1048576)))))

(defun agent-shell-overview-memory-column (id state)
  "Return the memory cell of row ID in STATE, dimmed.
ID is an agent shell buffer, whose memory is that of the last sample,
see `agent-shell-overview-memory--start', or an entry of the overview.
The cell is empty for an entry, a killed shell or an agent the sample
does not know."
  (propertize (agent-shell-overview-memory--size
               (when (and (bufferp id)
                          (buffer-live-p id)
                          (not (eq state 'killed)))
                 (when-let* ((pid (agent-shell-overview-memory--agent-pid id)))
                   (car (alist-get pid (cdr agent-shell-overview-memory--sample))))))
              'face 'agent-shell-overview-dim))

;;;###autoload
(define-minor-mode agent-shell-overview-memory-mode
  "Show the memory of the agents in `agent-shell-overview'.
When enabled, a Mem column follows the session title in
`agent-shell-overview-columns', with the summed RSS of the process tree
of the agent process of each shell.  It is sampled on the polling ticks
of the overview, see `agent-shell-overview-refresh-hook', at most every
`agent-shell-overview-memory-interval' seconds.  Disabling it removes
the column and stops sampling."
  :global t
  :group 'agent-shell-overview
  (if agent-shell-overview-memory-mode
      (progn
        (unless (seq-find (lambda (column)
                            (eq (nth 2 column) #'agent-shell-overview-memory-column))
                          agent-shell-overview-columns)
          (agent-shell-overview-add-column
           '("Mem" 5 agent-shell-overview-memory-column :right-align t :pad-right 2)
           #'agent-shell-overview-column-title))
        (add-hook 'agent-shell-overview-refresh-hook
                  #'agent-shell-overview-memory--start))
    (setq agent-shell-overview-columns
          (seq-remove (lambda (column)
                        (eq (nth 2 column) #'agent-shell-overview-memory-column))
                      agent-shell-overview-columns))
    (remove-hook 'agent-shell-overview-refresh-hook
                 #'agent-shell-overview-memory--start)
    (let ((process agent-shell-overview-memory--process))
      (setq agent-shell-overview-memory--process nil
            agent-shell-overview-memory--sample nil
            agent-shell-overview-memory--started nil)
      (when (processp process)
        (delete-process process))))
  (agent-shell-overview-refresh))

(provide 'agent-shell-overview-memory)
;;; agent-shell-overview-memory.el ends here
