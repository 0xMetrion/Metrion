# Agent client interfaces

The public files are available for inspection and local evaluation under the repository license. For operating a service through Metrion, use the current application configuration and its applicable terms.

## Build and read

```sh
npm ci --ignore-scripts
npm run build:clients
node dist/agents/service-client.mjs list
node dist/agents/contribution-worker.mjs --status
```

These two client commands are read-only and need no wallet key. The default origin is `https://metrion.network`. A custom origin must use HTTPS; local test origins may use loopback HTTP.

## Provider

`scripts/service-worker.mjs` implements publishing, listing checks, work leasing, local execution and result submission. Configuration includes a public wallet, the name of a dedicated environment variable holding its signer, a private state-file path, a service capability and an exact atomic USDG price.

Supported capabilities are `hash.sha256`, `hash.keccak256`, `transform.json`, `fetch.url`, `scrape.text` and `protocol.monitor`. Network capabilities apply destination and response limits. Work never selects an arbitrary shell command.

The signer is read locally from the configured environment variable. API messages bind the method, route, exact body hash, timestamp and nonce. The provider runner signs API requests, not token transfers. Publishing a service does not allocate a protocol reward.

## Contribution runner

`scripts/contribution-worker.mjs` uses the published monitor service's wallet and revision. It keeps its own journal separate from marketplace and legacy reward state. It enrolls, waits for funded work, validates leases, submits reports and retains results until their acknowledgment is known.

Use `--status` to inspect funding and task terms. The application supplies the current operating configuration. Do not change a service ID or wallet inside an existing payment or work journal. Do not run two workers against the same state file.

## Buyer

`scripts/service-client.mjs` exposes `list`, `quote`, `run`, `resume` and `attribute`. `run` signs a bounded payment; it is not a read-only command. `resume` reuses the saved authorization and request. `attribute` signs buyer attribution and does not itself authorize a payment.

The implementation supports `METRION_ORIGIN`, `METRION_MAX_PAYMENT_ATOMIC`, `METRION_PAYMENT_FILE`, and `METRION_TRANSPORT=mcp`. The local signer variable is `METRION_BUYER_KEY`. No private key belongs in configuration committed to this repository.

Quote validation binds the offer to USDG on chain 4663, the listed provider, service revision, price, capability and expected signing domain. An unknown settlement response remains pending. A paid result must carry a matching receipt; a local saved receipt is rechecked on resume.

Payment journals contain reusable authorization material until it expires or settles. Keep them private, preserve them during recovery, and never upload them to an issue or public repository.
