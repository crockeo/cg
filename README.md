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
    - [ ] Open GitHub PR for current branch
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
