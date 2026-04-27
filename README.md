# Verlo Contracts

Compliant settlement layer for tokenized assets on Base.

KYC enforcement, ERC-3643-style security tokens, and atomic delivery-versus-payment in USDC. Built for retail.

---

## What's in here

Three contracts that together form the core protocol:

- **KYCRegistry** — wallet verification registry. Admin verifies wallets; security tokens read from this on every transfer.
- **SecurityToken** — ERC-20-compatible token with KYC enforcement on transfers, transfer pause, and a built-in fee model (0.3% standard, 0.2% for $VERLO holders).
- **DvPSettlement** — atomic delivery-versus-payment. Buyer's USDC and seller's security token move in a single transaction. If anything fails, everything reverts.

Plus a 33-test Foundry suite covering KYC flows, transfer restrictions, atomic settlement edge cases, pause mechanics, fee math, zero-address validation, reentrancy, and fuzz testing.

---

## Why this exists

Most existing tokenized securities platforms (Securitize, Tokeny, INX) target institutions. Minimum tickets are often six figures. Onboarding takes weeks.

Retail users on Base get nothing.

Verlo's bet: take the same compliance primitives (ERC-3643, on-chain KYC, DvP) and build them retail-first. Same legal rigor, drastically lower friction.

---

## Architecture

```
              ┌────────────────────┐
              │    KYCRegistry     │
              │  (wallet → bool)   │
              └─────────┬──────────┘
                        │ reads
                        │
              ┌─────────▼──────────┐         ┌──────────────────┐
              │   SecurityToken    │◄────────┤   DvPSettlement  │
              │   (ERC-3643-ish)   │ swaps   │   (atomic DvP)   │
              └────────────────────┘         └──────────────────┘
                                                      │
                                                      │ pulls
                                                      ▼
                                              ┌──────────────────┐
                                              │      USDC        │
                                              └──────────────────┘
```

Every security token transfer (including the one inside `settleTradeAtomic`) checks the KYCRegistry. Unverified wallets cannot send or receive — no exceptions.

---

## Deployments

### Base Sepolia (testnet)

| Contract | Address |
| --- | --- |
| KYCRegistry | `0xab634e36Fa5adc9eB60021d0f2dcC9299cC5c572` |
| SecurityToken (VTE) | `0xFEA2A98bb8b387Fd1C9509ccDf42476ABf037761` |
| DvPSettlement | `0xBE857F0d91d1ff276EAc74e81E57f90D5F0511A2` |
| USDC (Circle testnet) | `0x036CbD53842c5426634e7929541eC2318f3dCF7e` |

### Base mainnet

Coming soon. Addresses will be added here once deployed.

---

## Build & test

This repo uses [Foundry](https://book.getfoundry.sh/).

```sh
git clone https://github.com/verlo-protocol/contracts.git
cd contracts
forge install
forge build
forge test
```

You should see `33 passed; 0 failed`.

---

## Security

- **Slither**: 0 real vulnerabilities. Three findings flagged and rejected with documented reasoning (admin must remain mutable for wallet-recovery, naming convention is intentional, and the `arbitrary-send-erc20` flag on `settleTradeAtomic` is the standard DEX pattern protected by allowance checks).
- **33 Foundry tests**: KYC flows (8), security token (9), DvP settlement (12), reentrancy (1), fuzz tests with 256 random inputs (2). Total scenarios validated: 545+.
- **Reentrancy guard** on `settleTradeAtomic` via `nonReentrant` modifier.
- **Checks-Effects-Interactions** pattern enforced. State updates happen before external calls.
- **Zero-address validation** in every constructor and admin setter.
- **Immutable variables** where state never changes after deployment (`kycRegistry`, `usdcAddress`, `issuedAt`).

If you find a real vulnerability, please disclose responsibly.

---

## Design choices worth knowing

**Why ERC-3643-style instead of plain ERC-20?**
Securities need transfer restrictions baked into the token itself, not bolted on at the protocol layer. ERC-3643 is the only widely-adopted standard for this. We use the pattern (KYC checks on every transfer) without depending on the full T-REX framework — keeps it auditable.

**Why atomic DvP instead of an order book?**
Retail users don't care about price discovery for tokenized assets that have a known per-token price. They care that "I clicked buy and got the token, or I didn't and kept my money." Atomic DvP gives that guarantee in a single tx.

**Why is admin not immutable?**
Slither flags this. We reject the suggestion. Admin needs to be transferable — wallet compromise recovery, multi-sig migration, governance handoff. Locking admin forever would be reckless.

**Why a flat 0.3% fee?**
Same as Uniswap. Simple to explain. $VERLO holders get 0.2%. No tiered staking, no lock-up gimmicks.

---

## Contributing

Open an issue. Open a PR. Roast the code on Twitter. All welcome.

External code review by independent developers is genuinely encouraged before mainnet deploy.

---

## License

[MIT](LICENSE).
