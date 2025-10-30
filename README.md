# cg

`cg` = Crockeo's Git (UI)

Building out something like [magit](https://magit.vc/) as a TUI.
Similar to [gitu](https://github.com/altsem/gitu),
but laser focused on "fast enough to use in the monolith at $JOB."

## Roadmap

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

## Contributing

Requires `zig` and the `git` CLI:

```
zig build run
```
