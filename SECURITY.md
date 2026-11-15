# Security

Cartridge v0.1 is experimental and has not received an independent security audit.

## Reporting

Do not publish exploitable vulnerabilities, tokens, or user data in public issues. Use the repository host's private vulnerability reporting feature when enabled, or contact a maintainer privately. A dedicated reporting address must be established before a public production release.

## Trust boundaries

- Domain SQL, migrations, tool manifests, and SOP content are trusted operator code.
- Users and agents must not receive membership in `cartridge_executor`, database owner credentials, or service-role keys.
- Keep `cartridge` out of PostgREST's exposed schemas. Engine tables and helper functions are not client APIs.
- Only registered, reviewed single-row update targets may use generic undo.
- OAuth identity verification does not replace row-level ownership checks.
- Polar fulfillment requires raw-body signature verification, an operator-owned product mapping, a trusted external customer ID, and a unique order ledger entry. User-supplied metadata is not an identity fallback.
- Checkout and customer portal sessions bind to the verified user, never to a tool-supplied user ID. Portal URLs are sensitive credentials.
- Stripe fulfillment requires raw-body signature verification, an operator-owned price mapping, and a unique Checkout Session ledger entry.
- Do not accept alternate token issuers, arbitrary browser origins, or unrestricted OAuth clients.
- SOP instructions guide an agent but are not an authorization mechanism.

Review the README's limitations before deployment. Apply request limits, rate limits, secure static hosting headers, dependency updates, monitoring, and backup/recovery procedures appropriate to your deployment.
