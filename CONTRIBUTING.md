# Contributing

Cartridge is early-stage. Small, tested changes are welcome.

1. Install Node.js 22+ and run `npm ci`.
2. Run `npm run check` before proposing changes.
3. Type-check Edge Functions using the Deno command in the README.
4. Add regression tests for every security or transaction behavior change.
5. Keep source, comments, documentation, and generated instructions in English.

Do not commit credentials, generated deployment configuration, or production data.
Discuss changes to billing semantics, permission grants, OAuth, and undo contracts before implementation. Never weaken isolation merely to shorten domain SQL.

A pull request should explain its motivation, observable behavior, test evidence, and migration/compatibility implications. Do not describe untested provider integrations as verified.
