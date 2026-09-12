# runnerctl

Single-file bash tool: `runnerctl`. Everything else in the repo is docs, the
generated `config.example`, and the gates.

- Manifest: `.agents/repo.json`. Gate traps: `.agents/gates.md`.
- Public repo: nothing site-specific (host names, paths under `/etc/<org>/`,
  ticket keys, secret names beyond generic placeholders) goes in the script,
  the README or the example config. Site values live in each host's
  `/etc/runnerctl/config`, which is never committed anywhere.
- Never bump `RUNNERCTL_VERSION` by hand. release-please does it in its own
  release PR from the conventional-commit subjects (`feat:` → minor, `fix:` →
  patch while < 1.0), so keep the commit type honest — it is the changelog
  entry and the version bump. The `# x-release-please-version` annotation on
  that line is what the bump matches; `make version-drift` fails if it and
  `.release-please-manifest.json` disagree. Details: `.agents/gates.md`.
