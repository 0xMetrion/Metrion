# Security

## Reporting

Use this repository's **Security > Report a vulnerability** feature to send a private report to the maintainers. If private reporting is unavailable, contact the project through its official [website](https://metrion.network) to arrange a private channel. Do not put credentials, exploitable details or user information in a public issue.

Include the affected file or contract, prerequisites, expected and observed behavior, and a minimal local reproduction. Reports do not require interaction with production funds. This repository does not authorize attacks against the hosted service, other users or third-party systems, and it does not announce a bounty program.

## Boundaries

- A provider worker signs scoped API messages using its local key. It is not a general transaction signer or a remote shell. Keep its key dedicated and its state directory private.
- The buyer client can sign a USDG payment authorization. Its saved authorization is sensitive. Preserve it after a timeout and resume the original request rather than creating a replacement payment.
- x402 authorizes payment under the quoted terms. It does not prove an arbitrary output is correct.
- The contribution verifier and authorized payment worker are trusted components. The rewards contract limits allocations and spending and rejects reused contribution identifiers. It does not independently prove off-chain work or collected fee data.
- Owner powers, pauses, changes and withdrawals differ between contracts. Inspect each contract and the actual deployed instance before relying on it.
- On-chain records and transactions are public. Nothing in this release provides anonymous wallet use or hides payment history.

The checked source and tests are review evidence, not a guarantee against attacks or an independent audit. Source updates do not alter previously deployed immutable contracts. See [release notes](docs/release-notes.md) for that distinction.
