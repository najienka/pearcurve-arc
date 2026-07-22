// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @title ArcAddresses
/// @notice Well-known Arc Testnet utility / Circle infra addresses (not Pearcurve-deployed).
/// @dev https://docs.arc.io/arc/references/contract-addresses
library ArcAddresses {
    /// @notice Arachnid deterministic CREATE2 proxy (same address on most EVMs, including Arc).
    address internal constant CREATE2_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @notice Multicall3 — aggregate read calls (already deployed on Arc Testnet).
    address internal constant MULTICALL3 = 0xcA11bde05977b3631167028862bE2a173976CA11;

    /// @notice Arc Testnet USDC ERC-20 interface (native gas token also denominated in USDC).
    address internal constant USDC = 0x3600000000000000000000000000000000000000;

    /// @notice Circle GatewayWallet (domain 26).
    address internal constant GATEWAY_WALLET = 0x0077777d7EBA4688BDeF3E311b846F25870A19B9;

    /// @notice Circle GatewayMinter (domain 26).
    address internal constant GATEWAY_MINTER = 0x0022222ABE238Cc2C7Bb1f21003F0a260052475B;

    /// @notice Chainlink Arc ETH/USD proxy (RDD `feeds-arc-mainnet.json`). May be empty on testnet.
    address internal constant CHAINLINK_ETH_USD = 0x50FCDD99D6762D1C170DC6A9111db944AEE6D364;
}
