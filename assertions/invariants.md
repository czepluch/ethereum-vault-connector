# Assertion Invariants

This document describes the invariants being protected by the assertions in this directory.

## VaultSharePriceAssertion

**Contract File:** `VaultSharePriceAssertion.a.sol`

### Invariant: VAULT_SHARE_PRICE_INVARIANT

**Description:** A vault's share price cannot decrease unless bad debt socialization occurs.

**Mathematical Definition:**

```
For any vault V and any transaction T that interacts with V:

Let:
- SP_pre(V) = totalAssets(V) * 1e18 / totalSupply(V) before transaction T
- SP_post(V) = totalAssets(V) * 1e18 / totalSupply(V) after transaction T
- BDS(T,V) = true if bad debt socialization events occurred for vault V in transaction T

Then the following invariant must hold:
SP_post(V) >= SP_pre(V) ∨ BDS(T,V)
```

**In Plain English:**
"A vault's share price cannot decrease unless bad debt socialization occurs"

### What This Protects Against

- **Malicious vault implementations** that steal funds from depositors
- **Protocol bugs** that cause unexpected share price decreases
- **Economic attacks** that drain vault value
- **Implementation errors** in vault logic

### What This Allows

- **Normal vault operations** (deposits, withdrawals, yield generation)
- **Bad debt socialization** (as designed in the Euler protocol)
- **Legitimate share price increases** from yield or other mechanisms

### Bad Debt Socialization Detection

The assertion detects bad debt socialization by monitoring for these events occurring together in the same transaction:

1. **Repay events** where the account is not `address(0)` (repay from liquidator)
2. **Withdraw events** where the sender is `address(0)` (withdraw from address(0))

Both events must occur together to indicate legitimate bad debt socialization.

### Monitored Operations

The assertion intercepts and validates all EVC operations that can affect vault share prices:

- `EVC.batch()` - Batch operations (primary vault interaction method)
- `EVC.call()` - Single call operations
- `EVC.controlCollateral()` - Collateral control operations

### Edge Cases Handled

- Non-contract addresses (skipped)
- Vaults that don't implement ERC4626 (graceful failure)
- Zero total supply (share price = 0)
- Failed static calls to vault functions
