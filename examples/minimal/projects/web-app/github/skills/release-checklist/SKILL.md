---
name: release-checklist
description: Use when cutting a web-app release. Triggers - "release", "cut a version", "ship it".
---

# Release checklist

1. `npm test -- --run` is green.
2. `CHANGELOG.md` has an entry under the new version.
3. The version in `package.json` matches the tag you are about to push.
4. Ask before pushing a tag. Tags are not cheap to undo.
