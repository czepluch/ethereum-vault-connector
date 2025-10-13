# Assertion Invariants

This document describes the invariants being protected by the assertions in this directory.

## 1. VaultSharePriceAssertion

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

## 2. AccountHealthAssertion

**Contract File:** `AccountHealthAssertion.a.sol`

### Invariant: ACCOUNT_HEALTH_INVARIANT

**Description:** No vault action can make a healthy account unhealthy.

**Mathematical Definition:**

```
For any vault V, any account A, and any transaction T that interacts with V through EVC:

Let:
- (CV_pre(A), LV_pre(A)) = V.accountLiquidity(A, false) before transaction T
  where CV = collateralValue, LV = liabilityValue
- (CV_post(A), LV_post(A)) = V.accountLiquidity(A, false) after transaction T
- isHealthy(A) = CV(A) >= LV(A)

Then the following invariant must hold:
isHealthy_pre(A) → isHealthy_post(A)

In plain English:
"If an account was healthy before a vault operation, it must remain healthy afterwards"

Or equivalently (contrapositive):
"A vault operation cannot make a healthy account unhealthy"
```

**In Plain English:**
"A vault operation cannot make a healthy account unhealthy"

### What This Protects Against

- **Unauthorized account liquidation** - Prevents vault operations from making accounts vulnerable to liquidation
- **Collateral manipulation attacks** - Detects operations that improperly reduce account health
- **Protocol bugs** that cause unexpected solvency violations
- **Cross-vault attacks** where operations on one vault harm account health in another
- **Economic attacks** that drain account value below safe thresholds

### What This Allows

- **Normal vault operations** that maintain or improve account health
- **Health-neutral operations** like transfers between healthy accounts
- **Legitimate health improvements** from deposits, repayments, etc.

### Affected Account Detection

The assertion determines which accounts to validate by using `getCallInputs()` to parse EVC function calls and extract vault operation parameters.

**Monitored EVC Operations:**

- `batch(BatchItem[] items)` - Parse BatchItems for vault calls
- `call(address targetContract, address onBehalfOfAccount, uint256 value, bytes data)` - Parse call parameters
- `controlCollateral(address targetCollateral, address onBehalfOfAccount, uint256 value, bytes data)` - Parse parameters

**Vault Function Classification:**

For each vault function called through the EVC, the assertion extracts affected accounts based on the function selector:

**Type 1 - Use `onBehalfOfAccount` from EVC call:**

- `transfer(address to, uint256 amount)` - Check the sender (`onBehalfOfAccount`)
- `borrow(uint256 amount, address receiver)` - Check the borrower (`onBehalfOfAccount`)
- `repayWithShares(uint256 amount, address receiver)` - Check the repayer (`onBehalfOfAccount`)
- `pullDebt(uint256 amount, address from)` - Check the account pulling debt (`onBehalfOfAccount`)

**Type 2 - Decode parameter from vault calldata:**

- `transferFrom(address from, address to, uint256 amount)` - Check `from` (1st parameter)
- `transferFromMax(address from, address to)` - Check `from` (1st parameter)
- `withdraw(uint256 amount, address receiver, address owner)` - Check `owner` (3rd parameter)
- `redeem(uint256 amount, address receiver, address owner)` - Check `owner` (3rd parameter)

### Health Check Mechanism

For each affected account A and the vault V being called:

1. **Pre-transaction check:**
   - Fork to pre-transaction state: `ph.forkPreTx()`
   - Query vault: `V.accountLiquidity(A, false)` → `(collateralValue, liabilityValue)`
   - Determine if account was healthy: `collateralValue >= liabilityValue`

2. **Post-transaction check:**
   - Fork to post-transaction state: `ph.forkPostTx()`
   - Query vault: `V.accountLiquidity(A, false)` → `(collateralValue, liabilityValue)`
   - Determine if account is healthy: `collateralValue >= liabilityValue`

3. **Invariant validation:**
   - Assert: `healthy_pre → healthy_post`
   - Revert with descriptive message if healthy account became unhealthy

**Note:** The `liquidation` parameter is set to `false` to check health using borrow LTV thresholds rather than liquidation LTV thresholds.

### Monitored Operations

The assertion intercepts and validates all EVC operations that can affect account health:

- `EVC.batch()` - Batch operations (primary vault interaction method)
- `EVC.call()` - Single call operations
- `EVC.controlCollateral()` - Collateral control operations

### Edge Cases Handled

- **Non-vault contracts** (no `accountLiquidity()` function) - Skipped gracefully
- **Accounts without a controller** - Cannot query health, skipped
- **Already-unhealthy accounts** (CV < LV before transaction) - Skipped, invariant only prevents healthy→unhealthy transitions
- **Failed `accountLiquidity()` calls** - Graceful skip (vault may not support interface)
- **Multiple accounts in single transaction** - All unique accounts validated
- **Unknown vault function selectors** - Non-monitored functions are ignored
- **Liquidations** - Skipped for now (operate on already-unhealthy accounts)

## 3. VaultAccountingIntegrityAssertion

**Contract File:** `VaultAccountingIntegrityAssertion.a.sol`

### Invariant: VAULT_ACCOUNTING_INTEGRITY_INVARIANT

**Description:** A vault's actual asset balance must always match its internal accounting, both in absolute terms and for changes during transactions.

**Mathematical Definition:**

```
For any vault V and any transaction T that interacts with V:

Let:
- asset = V.asset()
- balance_post = asset.balanceOf(V) after transaction T
- cash_post = V.cash() after transaction T
- balance_pre = asset.balanceOf(V) before transaction T
- cash_pre = V.cash() before transaction T
- borrows_pre = V.totalBorrows() before transaction T
- borrows_post = V.totalBorrows() after transaction T

Then the following invariants must hold:

1. Absolute Integrity Check:
   balance_post >= cash_post

2. Change Integrity Check:
   (balance_post - balance_pre) == (cash_post + borrows_post) - (cash_pre + borrows_pre)
```

**In Plain English:**
"The vault's actual balance must always be at least its cash, AND any change in balance must exactly match the change in internal accounting (cash + borrows)"

### What This Protects Against

- **Accounting bugs** where internal tracking diverges from reality
- **Asset theft** or unauthorized withdrawals not properly tracked
- **Flash loan attacks** that manipulate internal accounting
- **Implementation errors** in deposit/withdrawal/borrow/repay logic
- **Unauthorized asset extraction** without proper accounting updates
- **Exploits** that manipulate internal state without moving assets
- **Compensating errors** where multiple bugs cancel out in absolute terms but show up in deltas

### What This Allows

- **Normal vault operations** where balance and accounting move together correctly
- **Donations to vault** (balance > cash is acceptable in absolute check)
- **Deposits** (balance↑, cash↑, accounting change matches)
- **Withdrawals** (balance↓, cash↓, accounting change matches)
- **Borrows** (balance↓, borrows↑, net accounting unchanged)
- **Repays** (balance↑, borrows↓, net accounting unchanged)
- **Unaccounted assets** that can be claimed via skim()

### Implementation Approach

The assertion performs two complementary checks:

**Check 1: Absolute Integrity (Post-transaction only)**
- Query vault's asset token via `vault.asset()`
- Get actual balance via `asset.balanceOf(vault)`
- Get internal cash accounting via `vault.cash()`
- Assert: `balance >= cash`

**Check 2: Change Integrity (Pre/Post comparison)**
- Fork to pre-transaction state and capture:
  - `asset.balanceOf(vault)` → balancePre
  - `vault.cash()` → cashPre
  - `vault.totalBorrows()` → borrowsPre
- Fork to post-transaction state and capture same values
- Calculate changes: `ΔBalance = balancePost - balancePre`
- Calculate accounting change: `ΔAccounting = (cashPost + borrowsPost) - (cashPre + borrowsPre)`
- Assert: `ΔBalance == ΔAccounting`

**Vault Detection:** Use `getCallInputs()` to find all vault operations through EVC (batch/call/controlCollateral)

### Two-Level Protection

This assertion provides defense in depth:

1. **First Guard (Absolute Check):**
   - Fast, simple comparison: `balance >= cash`
   - Catches vaults already in bad state from previous issues
   - Low computational cost
   - Immediate detection of critical accounting failures

2. **Second Guard (Change Check):**
   - Precise tracking: `ΔBalance == Δ(Cash + Borrows)`
   - Identifies exact transaction that caused divergence
   - Catches subtle bugs that might pass absolute check
   - Detects compensating errors

### Monitored Operations

The assertion intercepts and validates all EVC operations that can affect vault accounting:

- `EVC.batch()` - Batch operations (primary vault interaction method)
- `EVC.call()` - Single call operations
- `EVC.controlCollateral()` - Collateral control operations

### Edge Cases Handled

- **Non-EVault contracts** (no asset(), cash(), or totalBorrows() functions) - Skipped gracefully
- **Failed staticcalls** - Skipped gracefully
- **Balance > cash** - Allowed in absolute check (unaccounted assets can be skimmed)
- **Negative changes** (withdrawals/borrows) - Handled with signed integers in change check
- **Multiple operations in batch** - Net change checked across entire transaction
- **Vaults starting in bad state** - Caught immediately by absolute check

### Future Enhancements

- **Note:** Could track individual operations (deposits, withdrawals, borrows, repays) and verify each one updates accounting correctly, providing even more granular detection
- **Note:** Could allow small tolerance (1-2 wei) for rounding differences if needed in practice
- **Note:** Consider checking fees separately if they affect balance without affecting cash+borrows in some vault implementations
- **Note:** Could extend to track interest accrual explicitly if that affects totalBorrows without immediate balance changes

## 4. VaultExchangeRateSpikeAssertion

**Contract File:** `VaultExchangeRateSpikeAssertion.a.sol`

### Invariant: VAULT_EXCHANGE_RATE_SPIKE_INVARIANT

**Description:** A vault's exchange rate (assets per share) cannot increase or decrease by more than a threshold percentage in a single transaction.

**Mathematical Definition:**

```
For any vault V and any transaction T that interacts with V:

Let:
- totalAssets_pre = V.totalAssets() before transaction T
- totalSupply_pre = V.totalSupply() before transaction T
- totalAssets_post = V.totalAssets() after transaction T
- totalSupply_post = V.totalSupply() after transaction T
- exchangeRate_pre = totalAssets_pre * 1e18 / totalSupply_pre
- exchangeRate_post = totalAssets_post * 1e18 / totalSupply_post
- changePct = |exchangeRate_post - exchangeRate_pre| * 100 / exchangeRate_pre

Then the following invariant must hold:
changePct <= THRESHOLD (5%)
```

**In Plain English:**
"The exchange rate cannot suddenly change by more than 5% in a single transaction"

### What This Protects Against

- **Donation attacks** where attackers manipulate share price
- **Price manipulation** through flash loans
- **Accounting bugs** that cause sudden rate changes
- **Exploits** that drain value from existing depositors

### What This Allows

- **Normal interest accrual** (gradual rate increases)
- **Small rate fluctuations** from deposits/withdrawals
- **Bad debt socialization** (covered by VaultSharePriceAssertion)

### Implementation Approach

**Vault Detection:** Use `getCallInputs()` to find vault operations through EVC

**Pre and Post-transaction checks:**
- Fork to pre-transaction state:
  - Calculate exchange rate: `ratePre = vault.totalAssets() * 1e18 / vault.totalSupply()`
- Fork to post-transaction state:
  - Calculate exchange rate: `ratePost = vault.totalAssets() * 1e18 / vault.totalSupply()`
- Calculate absolute percentage change in basis points
- Assert: change <= 500 basis points (5%)
- Check both increases and decreases

**Threshold:** 5% (500 basis points)

### Monitored Operations

The assertion intercepts and validates all EVC operations that can affect exchange rates:

- `EVC.batch()` - Batch operations (primary vault interaction method)
- `EVC.call()` - Single call operations
- `EVC.controlCollateral()` - Collateral control operations

### Edge Cases Handled

- **Zero total supply** (new or empty vault) - Skipped
- **First deposit into empty vault** - Skipped
- **Exchange rate changes in both directions** - Both checked against threshold

### Exemptions

- **`skim()` operations** - Exempted (claims unaccounted assets, legitimately changes rate)

### Future Enhancements

- **Note:** Threshold of 5% may need adjustment based on vault characteristics
- **Note:** Smaller vaults (< $1M TVL) might need higher thresholds due to rounding impact
- **Note:** Some vault types might legitimately have higher volatility and need custom thresholds
- **Note:** Consider per-vault configurable thresholds in future versions
