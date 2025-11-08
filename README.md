# cg

`cg` = Crockeo's Git (UI)

Building out something like [magit](https://magit.vc/) as a TUI.
Similar to [gitu](https://github.com/altsem/gitu),
but laser focused on "fast enough to use in the monolith at $JOB."

<!--
## Features

Look sparse? I started creating after building out some of the basic features.

- Features
    - [ ] View a diff (tab expand deltas)
    - [x] Commit
    - [x] Push
    - [ ] Pull
    - [ ] Create new branch
        - Receive longform user input
    - [ ] Open GitHub PR for current branch
    - [ ] Track unmerged commits
    - [ ] Show branch upstream (if exists) when rendering
    - [ ] Render stashes
    - [ ] Support complex inputs
        - [ ] Support multi-character inputs
    - [ ] Stream output from git commands into a terminal
        - E.g. when `git commit`-ing, I want to see pre-commit output.
        - Or when `git push`-ing, I want to see it pushing to the remote.
        - Or when `git pull`-ing, I want to see progress.
- Speed
    - [ ] Profile on large repo (e.g. $JOB monolith).
    - [ ] Some ideas:
        - [ ] Server/client architecture:
            - [ ] Server can watch directory and maintain up-to-date git information
            - [ ] Client interacts with server and:
                - [ ] Does optimistic local updates
                - [ ] Offloads the actual work to the server
        - [ ] Don't update git status in main thread, update in background.
        - [ ] Custom (lazier?) git implementation
        - [ ] Look at how `git` CLI stays fast
- Correctness
    - [x] Fix staging a deletion.
- Cosmetics
    - [ ] Highlight an entire line when hovering, not just the text.
!-->

## Plan

Keeping notes on what I should do, in what order :)

### Architecture

- **Foreground**
    - Responsible for all user interaction, input processing + painting the frontend.
    - Painting thread
        - Receives signals that it should paint from any source (background job or user input)
        - Takes mutex on shared state and paints
    - Input thread
        - Reads input from stdin as byte strings, and translates it to a logical input
        - Takes mutex on user state and performs some action based on that input
        - Can send messages to background job
- **User State**
    - Stores information related to the user.
    - E.g. "what index have I selected"
    - Or "what partial input have I applied"
        - This is to capture the idea of an input sequence resulting in one action.
        - E.g. `c` -> should open up the "commit" menu,
          and there should be many options inside of the commit menu.
    - Can be "merged" with a repo state to make sure it is valid w.r.t. the current state of the repo.
- **Repo State**
    - Stores information related to the repo.
    - E.g. the current status, branches, remotes, etc.
- **Background**
    - Just a single background thread, which can accept a queue of work.
    - Each job looks like:
        - Take job description
        - Do <some action>
        - Produce a new repo state
        - Take mutex on current repo state and swap it out for the new repo state

## Contributing

Requires `zig` and the `git` CLI:

```
zig build run
```
