# PayRail — Cross-Border B2B Payment Rails on Arc

Predictable, dollar-denominated payment infrastructure for businesses moving money across borders, built on Circle's Arc blockchain.

> **Status: early-stage, testnet only.** Arc mainnet is not yet live. These contracts are unaudited. Do not use for production payments.

---

## Problem

Cross-border B2B payments today are slow (1–5 business days), expensive (correspondent banking fees, FX spreads), and opaque (no real-time settlement confirmation). Existing crypto rails solve speed but introduce a new problem: volatile gas tokens make treasury planning impossible for finance teams who need to forecast costs in dollars, not ETH or SOL.

## Why Arc

- **USDC-native gas** means every transaction fee is quoted and paid in the same unit as the payment itself — no separate gas token to hold, hedge, or account for.
- **Sub-second deterministic finality** (via the Malachite consensus engine) means payment confirmation is fast enough to support real-time invoicing and payout workflows.
- **EVM-compatible execution** (Reth-based) means the settlement contracts here are built and tested with standard Solidity tooling.

Because gas is denominated in USDC, runtime gas is a direct line item on a finance team's books rather than an exchange-rate problem. The contracts are compiled with the optimizer biased toward runtime cost over bytecode size for exactly this reason.

---

## What's in this repository

This repo is the **settlement layer** — the Solidity contracts and their tests. The API, SDK, and indexer described in the architecture below are not yet implemented.

| Contract | Custody | Purpose |
| --- | --- | --- |
| `InvoiceRegistry` | No | USDC invoices with due dates, partial payments, and compliance references |
| `BatchPayout` | No | Pay many vendors in one atomic transaction |
| `PaymentEscrow` | **Yes** | Hold funds against a delivery obligation until released, refunded, or reclaimed |
| `ComplianceRegistry` | No | Counterparty KYC attestations shared by the three payment contracts |

```
src/
├── ComplianceRegistry.sol        KYC attestations, AccessControl officer role
├── InvoiceRegistry.sol           invoice lifecycle
├── BatchPayout.sol               multi-recipient settlement
├── PaymentEscrow.sol             delivery-conditional settlement
└── interfaces/
    └── IComplianceRegistry.sol
```

### Design decisions worth knowing

- **Two of the three payment contracts hold no funds.** Invoices and batch payouts move value directly from payer to recipient in the same call, so a bug puts allowances at risk rather than balances. `PaymentEscrow` necessarily takes custody and is written more defensively as a result.
- **Batches are atomic.** One failing recipient reverts the whole run. A half-applied payroll is worse to reconcile than one that plainly failed — but the practical consequence is that a single USDC-blacklisted recipient blocks the batch, so validate recipients off-chain and split large runs.
- **Pausing never traps money.** The pause switch gates *entry* — creating invoices, opening escrows, executing batches. Cancellation, release, refund, and expiry claims stay available while paused. An incident switch that locked customer funds inside a contract would be worse than the incident.
- **Amounts are `uint96`.** USDC has 6 decimals, so `uint96` covers ~7.9 × 10²² USDC and lets records pack into fewer storage slots.
- **No PII on-chain.** Invoice references, PO numbers, and KYC evidence are stored as hashes or opaque identifiers pointing at off-chain systems of record.
- **KYC is re-checked at payment time**, not at invoice creation, so a counterparty suspended between tranches cannot continue paying.

---

## Getting started

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation).

```bash
git clone git@github.com:meshackyaro/payrail.git
cd payrail
forge install          # fetch forge-std and OpenZeppelin submodules
forge build
forge test
```

Useful variations:

```bash
forge test --profile lite     # fast: optimizer off, 32 fuzz runs
forge test --profile deep     # thorough: 10,000 fuzz runs
forge test --gas-report
forge coverage --no-match-coverage "(test|script)/" --report summary
```

### Configuration

```bash
cp .env.example .env
```

`.env.example` documents every value. **Arc's RPC URL and chain ID are deliberately left blank** rather than guessed — take them from Circle's Arc documentation. Deployment requires two values: `USDC_ADDRESS` and `EXPECTED_CHAIN_ID`.

### Deploying

Against a local node — `EXPECTED_CHAIN_ID` may be omitted on chain 31337:

```bash
anvil
forge script script/Deploy.s.sol:Deploy --rpc-url local --broadcast
```

Against Arc testnet, using a keystore account rather than a raw key:

```bash
cast wallet import payrail-deployer --interactive
forge script script/Deploy.s.sol:Deploy \
  --rpc-url arc_testnet --account payrail-deployer --broadcast
```

The script refuses to broadcast until three things check out:

| Guard | Failure |
| --- | --- |
| Connected chain matches `EXPECTED_CHAIN_ID` | `ChainIdMismatch(expected, actual)` |
| `EXPECTED_CHAIN_ID` is set at all, on any non-local chain | `ExpectedChainIdNotSet(actual)` |
| `USDC_ADDRESS` has deployed code | `UsdcAddressHasNoCode(usdc)` |

The chain check runs first and before `vm.startBroadcast()`, so a misconfigured RPC costs nothing — no nonce burned, no signed transaction left replayable on the network you actually meant to target. Leaving `EXPECTED_CHAIN_ID` blank is tolerated only on a local dev chain; anywhere else it is itself an error, because trusting whatever the RPC happens to point at is the mistake being guarded against.

The script also warns if ownership is left on the deployer EOA. Contracts use `Ownable2Step`, so a successor owner must call `acceptOwnership()`.

---

## Architecture

```
┌─────────────┐     ┌──────────────────┐     ┌────────────────┐
│  Web / API  │────▶│  Payment Router   │────▶│  Arc Settlement │
│   Client    │     │  (fee estimation, │     │    Contract     │
└─────────────┘     │   batching logic) │     └────────────────┘
                     └──────────────────┘              │
                                                          ▼
                                                ┌──────────────────┐
                                                │  Webhook / Event  │
                                                │     Listener      │
                                                └──────────────────┘
```

- `contracts/` — **implemented** (this repo: `src/`)
- `api/` — planned: REST/GraphQL layer for creating invoices and querying payment status
- `sdk/` — planned: client libraries (JS/TS, Python)
- `indexer/` — planned: event listener syncing on-chain payment state to Postgres

Every state change emits an indexer-ready event carrying its correlation id (`invoiceId`, `batchId`, `escrowId`) and the off-chain reference supplied at creation, so the indexer can join on-chain settlement to ERP records without replaying calldata.

## Tech stack

- Solidity 0.8.28, Foundry, OpenZeppelin 5.7
- Node.js / TypeScript for the API and SDK (planned)
- Postgres for off-chain indexing (planned)
- Arc public testnet for development

---

## Roadmap

- [x] Invoice creation and payment contracts, verified end-to-end on a local node
- [x] Batch payout contract
- [x] Escrow with arbiter and deadline-based reclaim
- [ ] Deploy to Arc public testnet (blocked on RPC/chain-id configuration)
- [ ] Gas-cost simulation tooling denominated in USDC
- [ ] Webhook/event indexer for accounting integrations
- [ ] REST/GraphQL API and client SDKs
- [ ] Multi-currency support (USDC + EURC — a second registry per currency)
- [ ] Security audit
- [ ] Mainnet launch alignment with Arc's mainnet release

## Testing

102 tests, 100% line and function coverage on all four contracts.

```
| File                       | % Lines           | % Funcs         |
| src/BatchPayout.sol        | 100.00% (39/39)   | 100.00% (7/7)   |
| src/ComplianceRegistry.sol | 100.00% (16/16)   | 100.00% (4/4)   |
| src/InvoiceRegistry.sol    | 100.00% (63/63)   | 100.00% (13/13) |
| src/PaymentEscrow.sol      | 100.00% (59/59)   | 100.00% (11/11) |
```

Coverage is a floor, not a guarantee — these contracts have not been audited.

## License

MIT
