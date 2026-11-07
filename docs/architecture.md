# Architecture

## Buyer-funded services

1. A provider publishes a supported capability and an exact USDG price.
2. The buyer retrieves the listing and quote through HTTP or MCP.
3. The buyer client checks the chain, token, recipient, amount, service revision and authorization lifetime before signing.
4. A provider worker leases and executes the requested work using its configured capability.
5. The hosted service coordinates settlement and returns the payment receipt. The buyer retains its original authorization while the result is unresolved.

USDG uses six decimal places in the clients: `1000000` atomic units equal 1 USDG. The client's per-call maximum is a payment control, not the service's price or a recurring subscription. A private journal and exclusive lock prevent the same local payment file from being used by concurrent buyer processes.

HTTP and MCP are interfaces to the same marketplace. A different interface does not create a different payment entitlement. The provider's marketplace price is independent of contribution policy.

## Funded contributions

The contribution runner attaches to an existing published `protocol.monitor` service. A locally signed enrollment identifies its provider, service and revision. The scheduler issues work only when the corresponding program has available funding and an eligible assignment.

The runner checks the assignment identity, funding queue, minimum reward, input and expiry. It reads a fresh chain snapshot and submits the report. The hosted verifier compares it against independent reads. Reports and acknowledgments are retained for recovery so an unknown response does not silently trigger replacement work.

The reference pilot policy pays 0.10 USDG for an accepted complete report covering three fixed protocol targets. It uses one globally payable monitoring window per 30 minutes and a shared 5 USDG daily spending limit. The initial reserve is finite. Read the current contribution catalogue for actual availability, terms and funding; this document does not promise future assignments or earnings.

Contribution tiers affect scheduling priority under the hosted policy. They do not multiply a task's quoted payment or bypass the shared budget. Creating accounts, listing a service or sending repeated reports is not a payable outcome by itself.

`MetrionEpochRewards` separates the initial pilot allocation from later fee-funded epochs. The authorized worker supplies collected-fee attestations and evidence references. The contract enforces its configured allocation percentage, caps, available token balance and payment uniqueness. It reserves allocated commitments against owner withdrawals. The owner can pause and withdraw unallocated funds under the contract's rules.

Fee-funded rewards depend on eligible collected fees, not gross token trading volume or an unverified volume estimate. The contract trusts the authorized attestation worker for that input. Unsolicited third-party marketplace sales do not automatically become protocol fee revenue.

## Pool fee payments

`MetrionFeeVault` accepts fees directed to it by compatible existing infrastructure. `MetrionHook` integrates with new compatible Uniswap v4 pools. Payroll splits determine how eligible native ETH funds stream recipients. A flush moves available fees into those streams outside the swap's settlement path.

`MetrionStreaming` tracks funded accrual and withdrawals. Funding exhaustion stops further accrual; a top-up does not retroactively create pay for an unfunded interval. `MetrionStake` supplies optional bonding checks. `MetrionFeeController` supplies the protocol fee policy. Direct-agent hook contracts provide their own separate fee distribution mechanism.

A pool stream, a marketplace order and a contribution payment have different funding sources, controls and receipts. They must not be represented as interchangeable balances.

## What remains outside this source release

Hosted scheduling, verification, persistence, anti-abuse policy and transaction submission are operated services. Their implementation and deployment credentials are not included. The selected source still exposes the client signing boundaries, contract accounting, payment limits and local regression tests for review.

Jobs, stock allocation and privacy modules are not part of this snapshot. Their availability and terms must be checked in the application; this repository grants no stock ownership, reward entitlement or privacy guarantee.
