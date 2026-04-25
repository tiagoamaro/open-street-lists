# Project: open-street-lists

## Git Workflow

### Querying commit history

```bash
# Recent commits (oneline)
git log --oneline -20

# Commits touching a specific file
git log --oneline -- path/to/file

# Full diff of a commit
git show <sha>

# Diff between two commits
git diff <sha1>..<sha2>

# Search commit messages
git log --oneline --grep="keyword"

# File at a specific commit
git show <sha>:path/to/file

# Who changed a line (blame)
git blame path/to/file
```

### Atomic commits

Each commit should do one thing. Rules:
- One logical change per commit (feature, fix, refactor, chore — not mixed)
- Commit message: `type: short description` (Conventional Commits)
  - `feat:` new capability
  - `fix:` bug fix
  - `chore:` tooling/config, no production logic
  - `perf:` performance improvement
  - `refactor:` restructure without behavior change
  - `docs:` documentation only
- Stage selectively: `git add -p` to pick hunks, not `git add .`
- Never mix whitespace cleanup with logic changes in the same commit

### Git commands

Prefer running commands automatically.
