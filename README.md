# SeerIMD (SEER)

A fixed-supply ERC-20 for the IMD custom-token launch on Ethereum (chain id 1).

| Property | Value |
| --- | --- |
| Solidity contract | `SeerToken` (`src/SeerToken.sol`) |
| `name()` | `SeerIMD` |
| `symbol()` | `SEER` |
| `decimals()` | `18` |
| `totalSupply()` | `1_000_000_000_000_000_000_000_000_000` minor units (1,000,000,000 SEER) |
| Constructor arguments | none |
| Owner / admin | none |
| Mint after deployment | impossible (no mint function) |
| Burn | none (no burn function; supply is constant) |
| Transfer fee / tax | none |
| Pause / blocklist / freeze | none |
| Upgradeability | none (no proxy, no `DELEGATECALL`, no `SELFDESTRUCT`) |
| Extras | EIP-2612 `permit` (OpenZeppelin `ERC20Permit`) |

## What it does

`SeerToken` is OpenZeppelin v5 `ERC20` plus `ERC20Permit`. The constructor mints the whole
supply once to `msg.sender` and nothing else ever changes `totalSupply()`. There is no owner,
no privileged function, and no hook on transfer, so every transfer moves exactly the amount
asked for. The token holds no ether and has no `receive`/`fallback`.

The contract name `SeerToken` is the Solidity identifier the launch manifest records (at most 32
characters). It is distinct from the token name `SeerIMD` and symbol `SEER`, which `name()` and
`symbol()` return.

## Assumptions

- The requester asked for exactly 1,000,000,000 tokens with 18 decimals, all minted once to the
  deployer. No other behaviour (tax, burn, reflection, vesting, governance) was requested, so
  none is implemented.
- "The deployer" is `msg.sender` of the constructor. On the IMD launch that is the
  `ProjectFactory`, which then distributes the supply per the launch economics (10% to the
  swarm's MerkleDistributor, 80% to seed the Uniswap v4 pool, 10% to the requester's
  `remainderTo` address). The token itself has no knowledge of, and needs no exemption for, any
  of those addresses because it applies no fee or restriction to anyone.
- Permit was added as a convenience for holders (gasless approvals). It introduces no admin
  surface. The EIP-712 domain uses name `SeerIMD` and version `1`.
- OpenZeppelin v5.4.0 and forge-std v1.11.0 are vendored as ordinary files under `lib/`
  (no git submodules) so the project builds offline.

## Deployment parameters

The token takes no constructor arguments. The launch manifest step fills:

- `token.contract`: `SeerToken`
- `token.name`: `SeerIMD`
- `token.symbol`: `SEER`
- `token.decimals`: `18`
- `token.constructorArgs`: `[]`
- `token.totalSupply`: `1000000000000000000000000000`
- `contracts`: `[]` (no application contracts)

Pool and economics values are the launch's and are copied by the manifest step from the job:
pair IMD (`0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`), fee 12500, tick spacing 60,
`poolBps` 8000, `initialMarketCapWei` 3500000000000000000000,
`remainderTo` `0x18e0a43cb0236c3e2e6f6f229fc2ca36299a4636`.

Compiler settings (`foundry.toml`): solc 0.8.26, EVM `cancun`, optimizer on at 200 runs,
`via_ir = false`, `bytecode_hash = "none"`, `ffi = false`, no filesystem permissions.

### Named constants

| Constant | Value | Where |
| --- | --- | --- |
| `TOKEN_NAME` | `"SeerIMD"` | `src/SeerToken.sol` |
| `TOKEN_SYMBOL` | `"SEER"` | `src/SeerToken.sol` |
| `DECIMALS` | `18` | `src/SeerToken.sol` |
| `TOTAL_SUPPLY` | `1_000_000_000 * 10**18` | `src/SeerToken.sol` |

The brief left no number open; nothing was chosen on the requester's behalf.

## After launch

Nothing to configure. The token has no owner-settable value, no setter, and no post-deployment
initialisation. Once deployed it is final.

## Operational responsibilities

- **The launch (IMD's deployer)** deploys the creation code through the factory and moves the
  supply per the economics above. This repository does not deploy, broadcast or sign anything.
- **The requester** receives the remainder at `remainderTo` and is responsible for the custody
  of that wallet. There is no admin key to rotate or secure because there is no admin.
- **Holders** are responsible for their own approvals. `permit` signatures are bound to a nonce
  and a deadline; a signature cannot be replayed, but a holder should still sign only for the
  spender and amount they intend. Prefer bounded approvals over `type(uint256).max`.
- **Explorer verification** of the deployed source is a deployer step after launch
  (`forge verify-contract` with the settings in `foundry.toml`); it is reported here as an open
  item, not done by this job.
- **No emergency controls exist.** There is no pause, freeze or recovery function. That is by
  design for a fixed-supply token and should be understood as a trust assumption: nobody,
  including the requester, can intervene in transfers after deployment.

## Security notes

Checked against the `eth-security` reference (pinned ethskills guide):

- Reentrancy: no external calls in any state-changing path.
- Access control: no privileged functions, so nothing to gate.
- Decimals: fixed at 18 and exposed via `decimals()`; `TOTAL_SUPPLY` is expressed in minor units.
- Delegatecall / upgradeability: none; a test scans the runtime bytecode for reachable
  `DELEGATECALL`, `CALLCODE` and `SELFDESTRUCT`.
- Signatures: `permit` is OpenZeppelin's `ERC20Permit` (EIP-712 domain, nonce, deadline,
  `ECDSA` with malleability protection), not a hand-rolled implementation.
- Tools run: `forge build`, `forge test` (unit, fuzz, invariant), `forge fmt --check`.
  Slither and Mythril were not available in this environment and did not run.

Tests passing are not an audit. An independent adversarial review is still appropriate before
anything holding other people's funds is built on top of this token.

## Layout

```
foundry.toml                   compiler pins and profile
remappings.txt                 forge-std/ and @openzeppelin/contracts/
src/SeerToken.sol              the token
script/DeploySeerToken.s.sol   deploy script; tests call deploy() directly
test/SeerToken.t.sol           unit and fuzz tests (success and failure paths)
test/SeerToken.invariant.t.sol supply-conservation invariants
lib/                           vendored forge-std 1.11.0 and openzeppelin-contracts 5.4.0
```

## Running the checks

```
forge build
FOUNDRY_FUZZ_SEED=0x809a95961df6b9d9ba70927e7125c95e29856fc4fe8e2f3d4039b95e00a4ba37 forge test
forge fmt --check
```

Tests read no environment variables and do not depend on which address calls them, so they pass
in any order and in parallel.
