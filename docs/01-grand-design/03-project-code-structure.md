# Project Code Structure Overview

To effectively navigate and contribute to a large project like Reth, having a "map" of the codebase is essential. Reth's deliberate modularity is clearly reflected in its directory and code structure.

## A Monorepo of Crates

The first thing to notice is that Reth is a **monorepo** that uses a **Cargo Workspace**. This means the single `reth` repository contains many individual but interconnected Rust packages (called "crates").

This is confirmed by looking at the root `Cargo.toml` file:

> The root `Cargo.toml` file defines a `[workspace.members]` list that includes all the core libraries under the `crates/` directory and the main application binaries under the `bin/` directory.
>
> *Source: `Cargo.toml`*

This structure perfectly embodies the "Modularity" goal, allowing each component to be developed, tested, and potentially used independently.

## Navigating the Repository: Key Directories

At the highest level, the repository is organized into a few key directories:

- **`bin/`**: This directory contains the entry points for the project's executable binaries. Most importantly, it holds the source for the main `reth` node client (`bin/reth/`). When you run `reth node`, you are running the code compiled from here.
- **`crates/`**: This is the heart of the project. It contains all the core library crates that provide the node's functionality. The vast majority of Reth's logic resides here, organized into modular components.
- **`docs/`**: This directory houses project documentation, including the source for the official Reth Book, providing in-depth explanations of its architecture and features.

## Anatomy of Reth: Core Modules (Crates)

Diving into the `crates/` directory, we find the building blocks of Reth. Here is a brief overview of the most important ones:

- **`reth-primitives`**
  - *Description*: "Commonly used types in reth."
  - *Role*: This is the foundational crate. It defines the basic data structures used everywhere, such as `Address`, `H256` (hashes), `Block`, `Transaction`, and `Header`.

- **`reth-db`**
  - *Description*: "Database primitives used in reth."
  - *Role*: Provides the core abstractions and implementation for storing and retrieving all blockchain data. It wraps the underlying MDBX key-value store.

- **`reth-network`**
  - *Description*: "Ethereum network support."
  - *Role*: Manages all P2P networking. This includes discovering other nodes, managing peer connections, and handling the exchange of blockchain data like blocks and transactions.

- **`reth-stages`**
  - *Description*: "Staged syncing primitives used in reth."
  - *Role*: The implementation of the Staged Sync architecture. It contains the `Pipeline` and `Stage` logic that drives the node's high-performance synchronization.

- **`reth-rpc`**
  - *Description*: "Reth RPC implementation."
  - *Role*: Implements the Ethereum JSON-RPC API. This is the interface that allows external applications like wallets, block explorers, and dapps to communicate with the Reth node.

- **`reth-revm`**
  - *Description*: "reth specific revm utilities."
  - *Role*: Integrates the `revm` (Rust Ethereum Virtual Machine) library. This crate is responsible for executing transactions and smart contracts.

- **`reth-transaction-pool`**
  - *Description*: "Transaction pool implementation."
  - *Role*: Manages the "mempool" of pending transactions. It's responsible for validating, ordering, and storing transactions that are waiting to be included in a block.

## The Starting Point

For any developer wanting to trace the program's execution from the very beginning, the entry point is clear:

> The main function (`main`) of the Reth node is located at `bin/reth/src/main.rs`.
>
> *Source: `bin/reth/src/main.rs`*

This function is responsible for initializing the command-line interface (CLI), parsing arguments, and launching the node.