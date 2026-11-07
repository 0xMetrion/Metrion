# Verification scope

This is an inspection and local-testing source snapshot. It does not deploy contracts, sign transactions, or establish that any deployed instance uses these source files.

The payroll base includes a correction to pending recipient updates: applying an immediate split update also cancels an older queued split proposal. Reintroducing a removed recipient requires a new proposal and the full configured notice period. The FeeVault regression test covers cancellation, rejection of the stale proposal, and a fresh notice period.

Existing deployed contracts retain their original behavior. This corrected payroll source and contracts that include it must not be presented as byte-for-byte equivalents of earlier deployments.

Use the pinned compiler settings and dependencies described in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) to run the local test suite. The dependency installer verifies the selected upstream source and license files against committed SHA-256 hashes. Tests are engineering checks, not an independent security audit.
