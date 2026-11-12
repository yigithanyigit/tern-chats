# Chats: a Tern sidebar for omp chats on every machine

A left sidebar listing every omp chat on every machine your Tern window is attached to (this
computer and remote hosts), with closed chats, forks as a tree, and a folder browser for new chats.

Each open chat has a dot: purple pulsing while it works, amber when it needs you, green when it
finished while you were in another chat, and grey once you have opened it.

The sidebar is for desktop windows. In the Tern iOS app the plugin does nothing, so the phone keeps
its full screen.

## Install

1. Install it in Tern: `tern plugin install github.com/yigithanyigit/tern-chats`
   (or clone it and `tern plugin link <path-to>/tern-chats`).
2. Every machine needs `python3`. The helper (`omp-recent`, in this folder) runs from here on this
   computer, and is streamed to remote hosts over ssh, so nothing is installed there.
3. Remote hosts are reached with `ssh <host>`, where `<host>` is the host's name in Tern without
   `user@`. Make that an ssh alias that logs in without a prompt.

## Projects folder

New chats start in a folder you pick. The browser opens at the projects root, which
`omp-recent` finds on each machine: `$OMP_PROJECTS` (several joined with `:`), else the first of
`~/Desktop/projects`, `~/projects`, `~/code`, `~/src` that exists, else your home folder.

## Use

| Do | How |
| --- | --- |
| Open a chat | click it (another machine's chat switches the window to that machine) |
| Chat menu: Rename, Fork, Close, Delete | click the chat you're in |
| Closed chat: Reopen, Fork, Delete | click it |
| New chat | `+` next to a machine, then pick or create a folder |
| Hide / show the sidebar | ⌃⌘B |
| Narrower / wider | ⌃⌘[ / ⌃⌘] |
| Search chats | ⌃⌘C |
| Rename the chat in front | ⌃⌘R |
| Fork the chat in front | ⌃⌘F |
| Delete the chat in front (asks first) | ⌃⌘⌫ |
| Close a chat | ⌘W twice (an empty chat closes at once) |

Delete is permanent: it removes the session file and its saved outputs, after asking twice.

## Fork links for imported chats

omp records the parent of a chat it forked. For chats it didn't fork (for example ones imported
from Claude Code with `omp --from-claude`, where worktree chats belong under the main chat), list
the links in `~/.omp/agent/chats-parents.json` on that machine: `{"<child id>": "<parent id>"}`.
