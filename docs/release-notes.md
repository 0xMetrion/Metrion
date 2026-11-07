# Source release 0.1.0

This release contains selected Metrion contracts, public agent clients and local tests. Package dependencies use exact versions; contract dependencies use exact upstream revisions and per-file hashes.

## Client hardening

- Buyer responses are size-limited while streaming, including responses without a content-length header.
- Buyer payment journals use bounded regular-file reads, reject symlinks and broad file permissions, and use exclusive private temporary files with durable replacement.
- Marketplace work must match the configured service revision before execution.
- Contribution monitoring validates assignment timing and supports bounded, cancellable waits.

Recovery keeps the original payment authorization and completed report across unknown responses. The tests exercise rejection and recovery paths, not just successful requests.

## Payroll source correction

The included payroll source cancels an older queued recipient split proposal when an immediate split update is applied. A regression checks that a removed recipient cannot be restored through the older queue entry and must instead pass a fresh delay.

Existing deployed contracts are unchanged by this repository. Earlier immutable payroll deployments can retain an older queued proposal after an immediate change; only the owner can execute it, after its original delay. Owners of those instances must explicitly cancel obsolete proposals. Deploying the corrected source creates a different runtime and does not patch an existing hook or vault implementation.

Source inclusion is not a claim that every included bytecode version is deployed. Match compiler settings, constructor arguments, linked dependencies and the actual on-chain runtime when reviewing any deployment.

## Review scope

The release checks cover selected contract accounting and authorization paths, client boundary validation, payment recovery and exported-file hygiene. They are not a comprehensive independent audit of the entire hosted platform. No credential, deployment authority, operator database or repository history is part of this release.
