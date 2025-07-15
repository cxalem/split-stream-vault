# SplitStreamVault Smart Contract Documentation

## Overview

The `SplitStreamVault` is a Solidity smart contract that implements a **streaming token distribution system**. It allows tokens to be deposited and automatically split among multiple participants based on their assigned weights. The contract supports both direct claims and gasless transactions via EIP-712 signatures.

## Table of Contents

1. [Core Concepts](#core-concepts)
2. [Contract Architecture](#contract-architecture)
3. [Key Components](#key-components)
4. [Functions](#functions)
5. [Events](#events)
6. [Security Features](#security-features)
7. [Usage Examples](#usage-examples)
8. [FAQ](#faq)

---

## Core Concepts

### What is a Split-Stream Vault?

A Split-Stream Vault is a smart contract that:
- Accepts token deposits from anyone
- Automatically distributes those tokens among pre-defined participants
- Uses a **streaming mechanism** where participants can claim their accumulated tokens at any time
- Supports **weighted distribution** (some participants get more than others)

### How the Streaming Works

Instead of immediately sending tokens to participants when deposited, the vault:
1. **Accumulates** tokens over time
2. **Tracks** how much each participant is owed
3. **Allows** participants to claim their share whenever they want
4. **Prevents** double-spending through checkpoint systems

---

## Contract Architecture

### Inheritance Chain

```solidity
contract SplitStreamVault is Initializable, UUPSUpgradeable, ReentrancyGuard
```

- **`Initializable`**: Proxy pattern support (constructor replacement)
- **`UUPSUpgradeable`**: Upgradeable contract pattern
- **`ReentrancyGuard`**: Protection against reentrancy attacks

### Storage Layout

```solidity
// Token and governance
IERC20 public token;        // The ERC-20 token being distributed
address public guardian;    // Emergency pause authority
address public governor;    // Administrative authority

// Distribution state
mapping(address => uint256) public weight;     // Participant weights
uint256 public totalWeight;                    // Sum of all weights
uint256 public accPerWeight;                   // Global accumulator
mapping(address => uint256) public prevAcc;    // User checkpoints

// Meta-transaction support
mapping(address => uint256) public nonces;     // EIP-712 replay protection

// Safety
bool public paused;                           // Emergency pause state
```

---

## Key Components

### 1. The Token (`token`)

**Q: How will this token look like? Should I send the symbol and name when calling initialize?**

**A:** No, you don't send the symbol and name. The `token` variable is an **ERC-20 token contract address**, not a string.

```solidity
IERC20 public token;  // Reference to existing ERC-20 contract
```

**Example Usage:**
```javascript
// The token already exists on the blockchain
const USDC_ADDRESS = "0xA0b86a33E6441b8c4C8C8C8C8C8C8C8C8C8C8C8C8C";

// Initialize with the token address
vault.initialize(
    USDC_ADDRESS,        // ← Token contract address
    guardianAddress,
    governorAddress,
    [alice, bob, charlie],
    [100, 200, 300]
);
```

### 2. Delta in Deposits

**Q: What's delta here?**

**A:** `delta` is the **increment to the global accumulator per weight unit**.

```solidity
function deposit(uint256 amount) external {
    token.safeTransferFrom(msg.sender, address(this), amount);
    
    uint256 delta = amount * 1e18 / totalWeight;  // ← This is delta
    accPerWeight += delta;
    
    emit Deposit(msg.sender, amount, delta);
}
```

**How it works:**
- `amount` = tokens being deposited
- `totalWeight` = sum of all participant weights  
- `delta = amount * 1e18 / totalWeight` = tokens per weight unit (scaled for precision)

**Example:**
- Someone deposits 100 tokens
- `totalWeight` is 50
- `delta = 100 * 1e18 / 50 = 2e18`
- This means each weight unit is now worth 2 more tokens

### 3. The 1e18 Scaling Factor

**Q: What's 1e18?**

**A:** `1e18` is **1 followed by 18 zeros** (1,000,000,000,000,000,000).

**Why it's used:**
1. **Ethereum standard**: ETH has 18 decimal places (1 ETH = 1e18 wei)
2. **Most ERC-20 tokens**: Also use 18 decimal places
3. **Fixed-point arithmetic**: Since Solidity doesn't have floating-point numbers
   - `1e18` represents "1.0" in this system
   - `0.5e18` represents "0.5"
   - `2.5e18` represents "2.5"

**In the vault:**
```solidity
uint256 delta = amount * 1e18 / totalWeight;  // Scale up for precision
// Later when claiming:
owed = weight[account] * (accPerWeight - prevAcc[account]) / 1e18;  // Scale back down
```

### 4. Guardian and Governor Roles

**Q: How does the guardian and the governor work?**

**A:** They serve different roles in the access control system:

#### Guardian - Emergency Control
```solidity
function pause()   external onlyGuardian { paused = true; }
function unpause() external onlyGuardian { paused = false; }
```

**Purpose**: Emergency pause mechanism
- Can **pause** the entire vault (stops all deposits/claims)
- Can **unpause** to resume operations
- **Single address** - typically trusted individual or multisig
- **Fast response** - can act immediately in emergencies

#### Governor - Administrative Control
```solidity
function setWeights(address[] calldata accounts, uint256[] calldata newWeights) external onlyGovernor;
function _authorizeUpgrade(address) internal override onlyGovernor {}
```

**Purpose**: Administrative and governance functions
- Can **modify participant weights** (changing how tokens are split)
- Can **upgrade the contract** to new versions
- **Typically a timelock contract** - provides governance delay
- **Slower but more powerful** - requires governance process

**Typical Setup:**
- **Guardian**: Multisig wallet with 2-3 trusted signers
- **Governor**: Timelock contract controlled by DAO governance

### 5. Address(this) Reference

**Q: address(this) is referencing the current smart contract, right?**

**A:** Yes, exactly! `address(this)` refers to the **current smart contract instance**.

```solidity
token.safeTransferFrom(msg.sender, address(this), amount);
```

**Breakdown:**
- `msg.sender` = the user calling the function
- `address(this)` = the vault contract address
- `amount` = tokens to transfer

**Why `address(this)`?**
- **`this`** is a Solidity keyword for the current contract
- **`address(this)`** casts it to an address type
- **Dynamic** - works regardless of deployment address

### 6. Previous Accumulator (prevAcc)

**Q: What's the prevAcc?**

**A:** `prevAcc` stands for "previous accumulator" and is a **checkpoint system** for the streaming mechanism.

```solidity
mapping(address => uint256) public prevAcc;
```

**How it works:**
1. **Each user has their own checkpoint** - stores the global accumulator value from their last claim
2. **Used to calculate owed tokens**:
   ```solidity
   owed = weight[account] * (accPerWeight - prevAcc[account]) / 1e18;
   prevAcc[account] = accPerWeight;  // Update checkpoint
   ```

**Example:**
- Alice has weight = 100
- When Alice was added: `prevAcc[alice] = 0`
- After deposits: `accPerWeight = 50`
- Alice claims: `owed = 100 * (50 - 0) / 1e18 = 5000` tokens
- After claim: `prevAcc[alice] = 50` (checkpoint updated)

**Purpose**: Prevents double-counting and ensures users only get tokens for deposits that happened after their last claim.

### 7. Nonces for Replay Protection

**Q: What's the nonce?**

**A:** `nonces` are **unique sequence numbers** that prevent signature replay attacks.

```solidity
mapping(address => uint256) public nonces;
```

**How it works:**
1. **Each user has a nonce** starting at 0, increments with each signed claim
2. **Included in signatures** - makes each signature unique
3. **Prevents replay** - same signature can't be used twice

**Example:**
- Alice's nonce starts at 0
- Alice signs: `{beneficiary: alice, to: alice, nonce: 0, deadline: 1234567890}`
- Bob submits transaction → Alice gets tokens, nonce becomes 1
- If Bob tries same signature again → **FAILS** (nonce 0 already used)

---

## EIP-712 Structured Data Signing

### Type Hash Definition

**Q: What's this specifically? How does this work? How are these the definitions for EIP-712?**

```solidity
bytes32 private constant _CLAIM_TYPEHASH =
    keccak256("Claim(address beneficiary,address to,uint256 nonce,uint256 deadline)");
bytes32 private _DOMAIN_SEPARATOR;
```

**A:** This is **EIP-712 structured data signing** implementation.

**EIP-712** allows users to sign complex data structures (not just raw bytes) in a human-readable format.

#### Components:

1. **Type Hash**: Pre-computed hash of the function signature
   - Defines the structure: `beneficiary`, `to`, `nonce`, `deadline`

2. **Domain Separator**: Includes contract name, version, chain ID, contract address
   - Prevents cross-chain/contract replay attacks

#### How Signing Works:

1. **User signs off-chain** (in wallet):
   ```javascript
   {
     types: {
       Claim: [
         { name: 'beneficiary', type: 'address' },
         { name: 'to', type: 'address' },
         { name: 'nonce', type: 'uint256' },
         { name: 'deadline', type: 'uint256' }
       ]
     },
     primaryType: 'Claim',
     domain: {
       name: 'SplitStreamVault',
       version: '1',
       chainId: 1,
       verifyingContract: '0x...'
     },
     message: {
       beneficiary: '0x...',
       to: '0x...',
       nonce: 123,
       deadline: 1234567890
     }
   }
   ```

2. **Contract verifies on-chain**:
   ```solidity
   bytes32 structHash = keccak256(abi.encode(_CLAIM_TYPEHASH, beneficiary, to, nonce, deadline));
   bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _DOMAIN_SEPARATOR, structHash));
   require(ecrecover(digest, v, r, s) == beneficiary, "bad signature");
   ```

### Signature Components (v, r, s)

**Q: What's this? What's v, r, s?**

```solidity
require(ecrecover(digest, v, r, s) == beneficiary, "bad signature");
```

**A:** These are **Ethereum signature components**:

- **`r, s`**: The actual signature values (32 bytes each), derived from private key and message
- **`v`**: Recovery identifier (1 byte), tells `ecrecover` which public key to use (values: 27, 28, 29, 30)

**How `ecrecover` works:**
1. Takes signature components (`v`, `r`, `s`)
2. Takes message hash (`digest`) that was signed
3. Recovers the public key that created the signature
4. Returns the address corresponding to that public key
5. Compares it to expected `beneficiary` address

**Example:**
```javascript
// Off-chain signing
const signature = await wallet.signMessage(digest);
// Returns: { v: 27, r: "0x1234...", s: "0x5678..." }

// On-chain verification
address signer = ecrecover(digest, v, r, s);
// signer = 0xAlice... (the address that signed)
```

### Beneficiary in claimWithSig

**Q: Here the beneficiary is the address of the user that's claiming the funds?**

**A:** Yes, exactly! The **`beneficiary`** is the address of the user who owns and is claiming the funds.

```solidity
function claimWithSig(
    address beneficiary,  // ← The user who owns the tokens
    address to,          // ← Where to send the tokens (could be different)
    uint256 deadline,
    uint8 v, bytes32 r, bytes32 s
) external {
    require(ecrecover(digest, v, r, s) == beneficiary, "bad signature");
    _claimInternal(beneficiary, to);  // ← Claim for beneficiary, send to 'to'
}
```

**Key Points:**
- **`beneficiary`** = User who **owns** the tokens
- **`to`** = Address where tokens are **sent** (can be different)
- **Signature verification** = `beneficiary` must have signed the request
- **Token calculation** = Uses `beneficiary`'s weight and checkpoint

**Example Scenarios:**

1. **Self-claim**: Alice claims her own tokens
   ```javascript
   claimWithSig(
       beneficiary: "0xAlice...",  // Alice owns tokens
       to: "0xAlice...",          // Send to Alice
       deadline, v, r, s          // Alice's signature
   )
   ```

2. **Different recipient**: Alice claims but sends to Bob
   ```javascript
   claimWithSig(
       beneficiary: "0xAlice...",  // Alice owns tokens
       to: "0xBob...",            // Send to Bob
       deadline, v, r, s          // Alice's signature
   )
   ```

3. **Gasless transaction**: Alice signs, Bob submits
   ```javascript
   // Alice signs off-chain, Bob pays gas
   claimWithSig(
       beneficiary: "0xAlice...",  // Alice owns tokens
       to: "0xAlice...",          // Alice receives tokens
       deadline, v, r, s          // Alice's signature
   )
   ```

---

## Functions

### Core Functions

#### `initialize()`
Sets up the vault with initial parameters. Called once during deployment.

```solidity
function initialize(
    IERC20 _token,
    address _guardian,
    address _governor,
    address[] calldata accounts,
    uint256[] calldata weights
) external initializer
```

#### `deposit(uint256 amount)`
Deposits tokens into the vault and updates the global accumulator.

```solidity
function deposit(uint256 amount) external nonReentrant whenNotPaused
```

#### `claim(address to)`
Claims owed tokens for the caller.

```solidity
function claim(address to) external nonReentrant whenNotPaused
```

#### `claimWithSig()`
Claims owed tokens using an EIP-712 signature (gasless transaction).

```solidity
function claimWithSig(
    address beneficiary,
    address to,
    uint256 deadline,
    uint8 v, bytes32 r, bytes32 s
) external nonReentrant whenNotPaused
```

### Administrative Functions

#### `setWeights()`
Updates participant weights (governor only).

```solidity
function setWeights(
    address[] calldata accounts,
    uint256[] calldata newWeights
) external onlyGovernor
```

#### `pause()` / `unpause()`
Emergency pause controls (guardian only).

```solidity
function pause() external onlyGuardian
function unpause() external onlyGuardian
```

---

## Events

```solidity
event Deposit(address indexed from, uint256 amount, uint256 delta);
event Claim(address indexed account, address indexed to, uint256 amount);
event WeightsUpdated(address[] accounts, uint256[] weights, uint256 totalWeight);
event Paused();
event Unpaused();
```

---

## Security Features

### 1. Reentrancy Protection
All external functions use `nonReentrant` modifier to prevent reentrancy attacks.

### 2. Pause Mechanism
Guardian can pause all operations in emergencies.

### 3. Access Control
- Guardian: Emergency pause/unpause
- Governor: Administrative functions and upgrades

### 4. Signature Verification
EIP-712 signatures prevent unauthorized claims and replay attacks.

### 5. Upgradeable Pattern
UUPS (Universal Upgradeable Proxy Standard) allows safe contract upgrades.

---

## Usage Examples

### Basic Setup

```javascript
// Deploy and initialize
const vault = await SplitStreamVault.deploy();
await vault.initialize(
    usdcToken.address,
    guardianAddress,
    governorAddress,
    [alice.address, bob.address, charlie.address],
    [100, 200, 300]  // Alice gets 1/6, Bob gets 2/6, Charlie gets 3/6
);
```

### Depositing Tokens

```javascript
// Anyone can deposit
await usdcToken.approve(vault.address, 600);
await vault.deposit(600);
// Alice can claim 100, Bob can claim 200, Charlie can claim 300
```

### Claiming Tokens

```javascript
// Direct claim
await vault.connect(alice).claim(alice.address);

// Gasless claim (Alice signs, Bob submits)
const signature = await alice.signTypedData(domain, types, message);
await vault.connect(bob).claimWithSig(
    alice.address,
    alice.address,
    deadline,
    signature.v,
    signature.r,
    signature.s
);
```

---

## FAQ

### Q: Can I change the token after initialization?
**A:** No, the token is set during initialization and cannot be changed. You would need to deploy a new vault for a different token.

### Q: What happens if someone deposits when the vault is paused?
**A:** The deposit will fail. The `whenNotPaused` modifier prevents all operations when paused.

### Q: Can participants have zero weight?
**A:** Yes, participants can have zero weight, meaning they won't receive any tokens from deposits.

### Q: What happens if I try to claim when I have no tokens owed?
**A:** The claim will succeed but transfer 0 tokens. No error is thrown.

### Q: Can the same address be both guardian and governor?
**A:** Yes, but it's not recommended for security reasons. They should be separate entities.

### Q: How do I calculate how much I can claim?
**A:** Use the formula: `owed = weight[account] * (accPerWeight - prevAcc[account]) / 1e18`

### Q: What's the purpose of the deadline in claimWithSig?
**A:** It prevents old signatures from being used indefinitely. After the deadline, the signature becomes invalid.

### Q: Can I upgrade the contract?
**A:** Yes, if you're the governor. The contract uses UUPS upgradeable pattern.

---

## Technical Notes

### Gas Optimization
- Uses `calldata` instead of `memory` for array parameters
- Batch operations in `setWeights()` to reduce gas costs
- Efficient storage layout to minimize storage slots

### Precision Handling
- Uses 1e18 scaling factor for precise calculations
- Handles integer division carefully to avoid precision loss

### Proxy Pattern
- Uses UUPS instead of transparent proxy for gas efficiency
- Includes storage gap for future upgrades

---

## License

This contract is licensed under the MIT License. 