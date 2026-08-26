# web-app - shared agent instructions

This file is linked into the checkout as `.github/copilot-instructions.md`.
It lives in the context repo, so every machine and every teammate gets the same
text, and a fix here is a fix everywhere after the next `graft`.

## Stack

- TypeScript, React, Vite. Node 22.
- Tests: vitest. Run `npm test -- --run` before proposing a diff.

## House rules for agents

- Never edit `dist/` or `package-lock.json` by hand.
- Public components need a story in `*.stories.tsx`.
- Commit messages follow Conventional Commits.
