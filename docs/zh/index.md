---
layout: home

hero:
  name: "Reth 学习笔记"
  text: "深入理解 Rust 以太坊客户端"
  tagline: 从架构设计到源码实现的全面指南
  image:
    src: /reth-chip-logo.png
    alt: Reth
  actions:
    - theme: brand
      text: 开始学习
      link: /zh/01-introduction/
    - theme: alt
      text: GitHub
      link: https://github.com/paradigmxyz/reth

features:
  - icon: 🏗️
    title: 宏观设计与架构
    details: 理解 Reth 的定位、阶段式同步架构以及项目整体代码结构的高层次设计。
  
  - icon: 🧱
    title: 核心原语与数据库
    details: 探索基础数据类型、RLP 编码、MDBX 数据库集成以及 Reth 的数据库抽象层。
  
  - icon: ⚡
    title: 阶段式同步与执行
    details: 深入了解管道概念、阶段特征、REVM 集成以及交易执行流程。
  
  - icon: 🌐
    title: 网络与 RPC
    details: 学习 P2P 网络、交易池管理以及 JSON-RPC API 的实现。
  
  - icon: 🔧
    title: 高级主题
    details: 掌握区块链树处理、重组、模块化设计模式以及贡献指南。
  
  - icon: 📚
    title: 双语支持
    details: 提供中英文双语版本，包含全面的源码分析和实践示例。
---

## 关于本项目

这是一个专注于 Reth（Rust Ethereum client）学习的综合性笔记项目。我们将从多个维度深入探索这个用 Rust 编写的高性能以太坊客户端。

### 学习路径

1. **初识 Reth** - 了解项目背景和整体架构
2. **核心数据结构** - 掌握基础的区块链数据类型
3. **数据库层** - 理解数据存储和管理机制
4. **阶段式同步** - 学习高效的区块链同步策略
5. **交易执行** - 深入 EVM 执行引擎
6. **网络与 RPC** - 探索节点通信和接口设计
7. **高级主题** - 掌握分叉处理和模块化设计

### 贡献指南

欢迎提交 Issue 和 Pull Request 来完善这个学习资源！