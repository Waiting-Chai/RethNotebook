# Core Data Types: Block, Header, and Transaction

## Overview

<mcreference link="https://github.com/paradigmxyz/reth/blob/main/docs/crates/stages.md" index="1">1</mcreference> The core data types in Reth represent the fundamental structures of the Ethereum blockchain. These types are used throughout the syncing pipeline, from the HeaderStage to the BodyStage and beyond.

## Block Structure

### SealedBlock

<mcreference link="https://github.com/paradigmxyz/reth/blob/main/docs/crates/stages.md" index="1">1</mcreference> A `SealedBlock` is created using the block header, ommers hash, and block body. This represents a complete, validated block that has been sealed (finalized) on the blockchain.

```rust
pub struct SealedBlock {
    pub header: SealedHeader,
    pub body: BlockBody,
    pub ommers: Vec<Header>,
    pub withdrawals: Option<Vec<Withdrawal>>,
}
```

### Block Components

#### Block Header
The block header contains essential metadata about the block:

<mcreference link="https://github.com/paradigmxyz/reth/issues/11127" index="5">5</mcreference> The `BlockHeader` trait provides access to key block data:

```rust
pub trait BlockHeader {
    /// Retrieves the beneficiary (miner) of the block
    fn beneficiary(&self) -> Address;
    
    /// Retrieves the difficulty of the block
    fn difficulty(&self) -> U256;
    
    /// Retrieves the block number
    fn number(&self) -> BlockNumber;
    
    /// Retrieves the gas limit of the block
    fn gas_limit(&self) -> u64;
    
    /// Retrieves the timestamp of the block
    fn timestamp(&self) -> u64;
    
    /// Retrieves the mix hash of the block
    fn mix_hash(&self) -> B256;
    
    /// Retrieves the base fee per gas of the block, if available
    fn base_fee_per_gas(&self) -> Option<u64>;
    
    /// Retrieves the excess blob gas of the block, if available
    fn excess_blob_gas(&self) -> Option<u64>;
}
```

#### Block Body
The block body contains the actual transaction data and other block contents:

```rust
pub struct BlockBody {
    pub transactions: Vec<TransactionSigned>,
    pub ommers: Vec<Header>,
    pub withdrawals: Option<Vec<Withdrawal>>,
}
```

## Header Deep Dive

### Header Fields

The Ethereum block header contains critical information for block validation:

```rust
pub struct Header {
    pub parent_hash: B256,
    pub ommers_hash: B256,
    pub beneficiary: Address,
    pub state_root: B256,
    pub transactions_root: B256,
    pub receipts_root: B256,
    pub logs_bloom: Bloom,
    pub difficulty: U256,
    pub number: BlockNumber,
    pub gas_limit: u64,
    pub gas_used: u64,
    pub timestamp: u64,
    pub extra_data: Bytes,
    pub mix_hash: B256,
    pub nonce: u64,
    pub base_fee_per_gas: Option<u64>,
    pub withdrawals_root: Option<B256>,
    pub blob_gas_used: Option<u64>,
    pub excess_blob_gas: Option<u64>,
    pub parent_beacon_block_root: Option<B256>,
}
```

### Merkle Roots in Headers

<mcreference link="https://github.com/paradigmxyz/reth/blob/main/docs/crates/stages.md" index="1">1</mcreference> Headers contain several important merkle roots:

#### Transactions Root
The transactions root is derived by creating a merkle tree from the block's transaction list and taking the Keccak 256-bit hash of the root node.

#### State Root
Represents the root hash of the state trie after all transactions in the block have been executed.

#### Receipts Root
The root hash of the trie containing all transaction receipts for the block.

#### Ommers Hash
<mcreference link="https://github.com/paradigmxyz/reth/blob/main/docs/crates/stages.md" index="1">1</mcreference> The Keccak 256-bit hash of the ommers list portion of the block. While ommers blocks were important during Ethereum's proof-of-work era, they are not needed in post-merge Ethereum since proof-of-stake selects exactly one block proposer at a time.

## Transaction Types

### Transaction Evolution

<mcreference link="https://github.com/paradigmxyz/reth/releases" index="3">3</mcreference> Reth supports multiple transaction types, and all transaction types have been unified with Alloy's implementations:

- `reth_ethereum_primitives::TransactionSigned` 
- `reth_op_primitives::TransactionSigned`

These are now just aliases to the underlying Alloy types.

### Transaction Structure

```rust
pub enum Transaction {
    Legacy(TxLegacy),
    Eip2930(TxEip2930),
    Eip1559(TxEip1559),
    Eip4844(TxEip4844),
}

pub struct TransactionSigned {
    pub transaction: Transaction,
    pub signature: Signature,
    pub hash: TxHash,
}
```

### Transaction Types Breakdown

#### Legacy Transactions (Pre-EIP-155)
```rust
pub struct TxLegacy {
    pub nonce: u64,
    pub gas_price: u64,
    pub gas_limit: u64,
    pub to: TxKind,
    pub value: U256,
    pub input: Bytes,
}
```

#### EIP-1559 Transactions (Type 2)
```rust
pub struct TxEip1559 {
    pub nonce: u64,
    pub max_fee_per_gas: u64,
    pub max_priority_fee_per_gas: u64,
    pub gas_limit: u64,
    pub to: TxKind,
    pub value: U256,
    pub input: Bytes,
    pub access_list: AccessList,
}
```

#### EIP-4844 Blob Transactions (Type 3)
```rust
pub struct TxEip4844 {
    pub nonce: u64,
    pub max_fee_per_gas: u64,
    pub max_priority_fee_per_gas: u64,
    pub gas_limit: u64,
    pub to: Address,
    pub value: U256,
    pub input: Bytes,
    pub access_list: AccessList,
    pub blob_versioned_hashes: Vec<B256>,
    pub max_fee_per_blob_gas: u64,
}
```

## Validation and Integrity

### Block Validation Process

<mcreference link="https://github.com/paradigmxyz/reth/blob/main/docs/crates/stages.md" index="1">1</mcreference> During the syncing process, blocks undergo rigorous validation:

1. **Header Validation**: Each header is validated according to consensus specifications
2. **Body Pre-validation**: Checking that ommers hash and transactions root in the block header match the block body
3. **Transaction Validation**: Individual transaction validation including signature verification
4. **State Transition**: Ensuring the state root correctly represents the post-execution state

### Empty Block Detection

<mcreference link="https://github.com/paradigmxyz/reth/blob/main/docs/crates/stages.md" index="1">1</mcreference> The BodyStage optimizes by skipping blocks where `header.ommers_hash` and `header.transaction_root` are empty, indicating an empty block.

## Memory Layout and Performance

### Zero-Copy Operations

The primitive types are designed to minimize memory allocations:

- Headers are often passed by reference
- Transaction data uses `Bytes` for efficient sharing
- Hash types use fixed-size arrays for optimal performance

### Serialization Efficiency

All core types implement efficient RLP encoding/decoding:

```rust
use alloy_rlp::{RlpEncodable, RlpDecodable};

#[derive(RlpEncodable, RlpDecodable)]
pub struct Header {
    // ... fields
}
```

## Type Safety Features

### Sealed Types

Sealed types prevent modification after creation, ensuring data integrity:

```rust
pub struct SealedHeader {
    header: Header,
    hash: B256,
}

impl SealedHeader {
    pub fn new(header: Header) -> Self {
        let hash = header.hash();
        Self { header, hash }
    }
    
    pub fn hash(&self) -> B256 {
        self.hash
    }
}
```

### Address and Hash Types

Strong typing prevents common errors:

```rust
// These are distinct types, preventing mix-ups
let address: Address = "0x...".parse()?;
let hash: B256 = "0x...".parse()?;

// This would be a compile error:
// let wrong: Address = hash; // ❌
```

## Integration Points

### RPC Conversion

<mcreference link="https://github.com/paradigmxyz/reth/blob/main/docs/repo/layout.md" index="1">1</mcreference> The `rpc/rpc-convert` crate provides conversion utilities between Reth primitive types and RPC types, enabling seamless API interactions.

### Database Storage

Core types integrate with the storage layer through codecs that efficiently serialize/deserialize data for database operations.

### Network Protocol

These types are used directly in the networking layer for peer-to-peer communication, ensuring consistency across the entire system.

## Best Practices

### When to Use Each Type

1. **Use `SealedBlock`** when you have a complete, validated block
2. **Use `Header`** when you only need block metadata
3. **Use `TransactionSigned`** for complete transaction data with signatures
4. **Use specific transaction types** when you know the transaction format

### Performance Tips

1. **Avoid unnecessary cloning** - use references when possible
2. **Leverage sealed types** for immutable data
3. **Use appropriate transaction types** to avoid enum matching overhead
4. **Cache computed hashes** when performing multiple operations

This deep understanding of core data types is essential for working effectively with Reth's codebase and building robust Ethereum applications.