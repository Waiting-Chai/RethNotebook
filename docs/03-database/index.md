# Chapter 3: Database (`reth-db`)

This chapter explores Reth's database layer, which is built on top of MDBX (a high-performance LMDB fork). The database layer is crucial for storing blockchain data efficiently and providing fast access to historical information.

## Overview

Reth's database architecture is designed for high performance and reliability. It uses MDBX as the underlying storage engine and provides a clean abstraction layer that makes it easy to work with blockchain data. The database stores everything from block headers and transactions to state data and receipts.

## Key Features

- **High Performance**: Built on MDBX for optimal read/write performance
- **Type Safety**: Strongly typed database operations with Rust's type system
- **Flexible Schema**: Well-designed database schema that supports efficient queries
- **Transaction Support**: Full ACID transaction support for data integrity
- **Compression**: Efficient data compression to minimize storage requirements

## Chapter Contents

### [Introduction to MDBX](01-introduction-to-mdbx.md)
Learn about MDBX, the high-performance database engine that powers Reth's storage layer. This section covers MDBX's architecture, performance characteristics, and why it was chosen for Reth.

### [Reth Database Abstraction](02-reth-db-abstraction.md)
Explore how Reth builds a clean, type-safe abstraction layer on top of MDBX. This section covers the database traits, transaction handling, and the overall architecture of Reth's database layer.

### [Database Schema & Table Mapping](03-database-schema-map.md)
Dive deep into Reth's database schema design. Learn about the various tables, their relationships, and how blockchain data is organized and stored efficiently.

## What You'll Learn

By the end of this chapter, you'll understand:

- How MDBX provides high-performance storage for blockchain data
- Reth's database abstraction layer and its design principles
- The complete database schema and how different types of data are stored
- Best practices for working with Reth's database APIs
- Performance considerations and optimization techniques

## Prerequisites

Before diving into this chapter, you should be familiar with:

- Basic database concepts (ACID properties, transactions, indexing)
- Rust programming language fundamentals
- Blockchain data structures (blocks, transactions, receipts)

---

*This chapter provides the foundation for understanding how Reth efficiently stores and retrieves blockchain data, which is essential for building high-performance Ethereum clients.*