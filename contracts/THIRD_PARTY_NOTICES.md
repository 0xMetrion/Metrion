# Contract dependency notices

The first-party contract and test source retains its existing SPDX identifiers. Dependencies are not vendored in this release. `DEPENDENCIES.json` records exact public upstream revisions, required source-file hashes, and license-file hashes. Run `python3 tools/install-dependencies.py` to fetch them for local verification. Python 3 and curl are required. The installer does not create Git repositories.

Production imports used by the included Metrion contracts have MIT SPDX identifiers. The test dependency closure contains additional licensing terms; it must not be described as entirely MIT. Original copyright and license notices are preserved byte-for-byte when dependencies are installed.

| Dependency | Applicable source labels | License files retained locally |
|---|---|---|
| forge-std | MIT OR Apache-2.0 | LICENSE-MIT; LICENSE-APACHE |
| Uniswap v4-periphery | MIT | LICENSE |
| Uniswap v4-core | MIT; BUSL-1.1; selected upstream test helpers marked UNLICENSED | licenses/MIT_LICENSE; licenses/BUSL_LICENSE; existing file headers |
| OpenZeppelin Contracts | MIT | LICENSE |
| Solmate test dependencies | AGPL-3.0-only; repository also contains individually licensed files | LICENSE; existing file headers |

The pinned v4-core BUSL text lists June 15, 2027 as its change date, subject to the additional grants and change-date mechanism specified there. No earlier conversion to MIT is asserted. `PoolManager` is used by local hook tests; the included Metrion production contracts use the MIT interface/library source closure.

Three upstream test helpers (`PoolSwapTest.sol`, `PoolModifyLiquidityTest.sol`, and `PoolTestBase.sol`) declare UNLICENSED. They are not included in this public source snapshot. Their existing labels remain intact when fetched for local verification; this release does not grant redistribution rights to those upstream files.

The GPL privacy circuit, prover and generated verifier are outside this initial release. Their source and attribution have not been relicensed, rewritten, or removed from their original module.

For local verification, use Foundry 1.7.1, Solidity 0.8.26 and the committed configuration:

```sh
python3 tools/install-dependencies.py
forge build
forge test
forge build --sizes --skip test --skip script
```

These tests run in a local EVM. No deployment, production signing or network payment operation is included. Test gas and a green test suite are not an independent security audit.

The explicit remapping list also retains unused public dependency aliases from the original compiler settings. Automatic remapping discovery is disabled so local dependency installation does not change compiler metadata or runtime fingerprints. Only imports in the selected source/test closure are downloaded.
