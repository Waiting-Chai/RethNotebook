import { defineConfig } from 'vitepress'

export default defineConfig({
  title: 'Reth Notebook',
  description: 'A comprehensive guide to understanding Reth - the Rust Ethereum client',
  
  locales: {
    root: {
      label: 'English',
      lang: 'en',
      title: 'Reth Notebook',
      description: 'A comprehensive guide to understanding Reth - the Rust Ethereum client',
      themeConfig: {
        nav: [
          { text: 'Home', link: '/' },
          { text: 'Guide', link: '/01-grand-design/' },
          { text: 'GitHub', link: 'https://github.com/Waiting-Chai/RethNotebook' }
        ],
        sidebar: {
          '/': [
            {
              text: 'Introduction',
              items: [
                { text: 'Overview', link: '/01-grand-design/' },
                { text: 'Reth Positioning', link: '/01-grand-design/01-reth-positioning' },
                { text: 'Staged Sync Architecture', link: '/01-grand-design/02-staged-sync-architecture' },
                { text: 'Project Code Structure', link: '/01-grand-design/03-project-code-structure' }
              ]
            },
            {
              text: 'Core Primitives',
              items: [
                { text: 'Overview', link: '/02-primitives/' },
                { text: 'Introduction to Primitives', link: '/02-primitives/01-introduction-to-primitives' },
                { text: 'Core Data Types', link: '/02-primitives/02-core-data-types' },
                { text: 'RLP Encoding', link: '/02-primitives/03-rlp-encoding' }
              ]
            },
            {
              text: 'Database Layer',
              items: [
                { text: 'Overview', link: '/03-database/' },
                { text: 'Introduction to MDBX', link: '/03-database/01-introduction-to-mdbx' },
                { text: 'Reth DB Abstraction', link: '/03-database/02-reth-db-abstraction' },
                { text: 'Database Schema Map', link: '/03-database/03-database-schema-map' }
              ]
            },
            {
              text: 'Staged Sync',
              items: [
                { text: 'Overview', link: '/04-staged-sync/' },
                { text: 'Pipeline Concept', link: '/04-staged-sync/01-pipeline-concept' },
                { text: 'Stage Trait', link: '/04-staged-sync/02-stage-trait' },
                { text: 'Core Stages Analysis', link: '/04-staged-sync/03-core-stages-analysis' }
              ]
            },
            {
              text: 'EVM & Transaction Execution',
              items: [
                { text: 'Overview', link: '/05-execution/' },
                { text: 'Introduction to REVM', link: '/05-execution/01-introduction-to-revm' },
                { text: 'BlockExecutor Bridge', link: '/05-execution/02-block-executor-bridge' },
                { text: 'Transaction Execution Flow', link: '/05-execution/03-transaction-execution-flow' }
              ]
            },
            {
              text: 'Network & RPC',
              items: [
                { text: 'Overview', link: '/06-network-rpc/' },
                { text: 'P2P Networking', link: '/06-network-rpc/01-p2p-networking' },
                { text: 'Transaction Pool', link: '/06-network-rpc/02-transaction-pool' },
                { text: 'JSON-RPC API', link: '/06-network-rpc/03-json-rpc-api' }
              ]
            },
            {
              text: 'Advanced Topics',
              items: [
                { text: 'Overview', link: '/07-advanced/' },
                { text: 'Blockchain Tree & Reorgs', link: '/07-advanced/01-blockchain-tree-and-reorgs' },
                { text: 'Modular Design in Practice', link: '/07-advanced/02-modular-design-in-practice' },
                { text: 'How to Contribute', link: '/07-advanced/03-how-to-contribute' }
              ]
            }
          ]
        }
      }
    },
    zh: {
      label: '中文',
      lang: 'zh-CN',
      title: 'Reth 学习笔记',
      description: '深入理解 Reth - Rust 以太坊客户端的全面指南',
      themeConfig: {
        nav: [
          { text: '首页', link: '/zh/' },
          { text: '指南', link: '/zh/01-grand-design/' },
          { text: 'GitHub', link: 'https://github.com/Waiting-Chai/RethNotebook' }
        ],
        sidebar: {
          '/zh/': [
            {
              text: '第一章：初识 Reth',
              items: [
                { text: '概览', link: '/zh/01-grand-design/' },
                { text: 'Reth 定位', link: '/zh/01-grand-design/01-reth-positioning' },
                { text: '阶段式同步架构', link: '/zh/01-grand-design/02-staged-sync-architecture' },
                { text: '项目代码结构', link: '/zh/01-grand-design/03-project-code-structure' }
              ]
            },
            {
              text: '第二章：基石之固：核心数据结构',
              items: [
                { text: '概览', link: '/zh/02-primitives/' },
                { text: '为何从 Primitives 开始', link: '/zh/02-primitives/01-introduction-to-primitives' },
                { text: '核心数据类型：Block, Header, Tx', link: '/zh/02-primitives/02-core-data-types' },
                { text: 'RLP 编码与序列化', link: '/zh/02-primitives/03-rlp-encoding' }
              ]
            },
            {
              text: '第三章：立地之本：数据库层',
              items: [
                { text: '概览', link: '/zh/03-database/' },
                { text: '数据库选型：MDBX 简介', link: '/zh/03-database/01-introduction-to-mdbx' },
                { text: 'Reth 的数据库抽象：Table Trait', link: '/zh/03-database/02-reth-db-abstraction' },
                { text: '数据库核心表结构解析', link: '/zh/03-database/03-database-schema-map' }
              ]
            },
            {
              text: '第四章：性能之魂：阶段式同步',
              items: [
                { text: '概览', link: '/zh/04-staged-sync/' },
                { text: 'Pipeline 流水线总指挥', link: '/zh/04-staged-sync/01-pipeline-concept' },
                { text: 'Stage Trait 接口设计', link: '/zh/04-staged-sync/02-stage-trait' },
                { text: '核心 Stages 分析', link: '/zh/04-staged-sync/03-core-stages-analysis' }
              ]
            },
            {
              text: '第五章：状态之变：EVM 与交易执行',
              items: [
                { text: '概览', link: '/zh/05-execution/' },
                { text: 'REVM：高性能的 EVM 实现', link: '/zh/05-execution/01-introduction-to-revm' },
                { text: 'BlockExecutor：连接 Reth 与 REVM', link: '/zh/05-execution/02-block-executor-bridge' },
                { text: '交易执行全流程剖析', link: '/zh/05-execution/03-transaction-execution-flow' }
              ]
            },
            {
              text: '第六章：与世界相连：网络与 RPC',
              items: [
                { text: '概览', link: '/zh/06-network-rpc/' },
                { text: 'P2P 网络与节点发现', link: '/zh/06-network-rpc/01-p2p-networking' },
                { text: '交易池 Mempool 的设计', link: '/zh/06-network-rpc/02-transaction-pool' },
                { text: 'JSON-RPC 接口实现', link: '/zh/06-network-rpc/03-json-rpc-api' }
              ]
            },
            {
              text: '第七章：登堂入室：高级主题',
              items: [
                { text: '概览', link: '/zh/07-advanced/' },
                { text: '区块链树与分叉处理', link: '/zh/07-advanced/01-blockchain-tree-and-reorgs' },
                { text: 'Reth 的模块化实践', link: '/zh/07-advanced/02-modular-design-in-practice' },
                { text: '如何向 Reth 社区贡献代码', link: '/zh/07-advanced/03-how-to-contribute' }
              ]
            }
          ]
        }
      }
    }
  },
  
  themeConfig: {
    logo: '/logo.svg',
    
    socialLinks: [
      { icon: 'github', link: 'https://github.com/Waiting-Chai/RethNotebook' }
    ],
    
    footer: {
      message: 'Released under the MIT License.',
      copyright: 'Copyright © 2024 Reth Notebook'
    },
    
    editLink: {
      pattern: 'https://github.com/your-username/RethNotebook/edit/main/docs/:path'
    },
    
    lastUpdated: {
      text: 'Updated at',
      formatOptions: {
        dateStyle: 'full',
        timeStyle: 'medium'
      }
    }
  },
  
  markdown: {
    lineNumbers: true
  }
})