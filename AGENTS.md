# runnerctl

Single-file bash tool: `runnerctl`. Everything else in the repo is docs, the
generated `config.example`, and the gates.

- Manifest: `.agents/repo.json`. Gate traps: `.agents/gates.md`.
- Public repo: nothing site-specific (host names, paths under `/etc/<org>/`,
  ticket keys, secret names beyond generic placeholders) goes in the script,
  the README or the example config. Site values live in each host's
  `/etc/runnerctl/config`, which is never committed anywhere.
- Bump `RUNNERCTL_VERSION` in the same PR as any behaviour change — that is
  what `runnerctl upgrade` compares.
