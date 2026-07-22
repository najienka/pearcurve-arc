// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {FeeManager} from "../src/fees/FeeManager.sol";
import {PriceOracle} from "../src/oracles/PriceOracle.sol";
import {ChainlinkOracle} from "../src/oracles/ChainlinkOracle.sol";
import {TokenAllowlist} from "../src/registry/TokenAllowlist.sol";
import {LoanManager} from "../src/LoanManager.sol";
import {IntentSettlement} from "../src/IntentSettlement.sol";
import {LoanHealthViewer} from "../src/LoanHealthViewer.sol";
import {ArcAddresses} from "../src/libraries/ArcAddresses.sol";
import {DeployConstants} from "./constants/DeployConstants.sol";
import {MockChainlinkAggregator} from "../test/mocks/MockChainlinkAggregator.sol";

/// @title DeployCore
/// @notice Deploys Pearcurve core directly from this script (no on-chain deployer helper).
///         Periphery uses Arachnid CREATE2 + numeric salts in `DeployConstants`.
///         LoanManager + IntentSettlement use sequential CREATE (circular immutables).
///         Writes `deployments/<chainId>.json`.
///
/// Usage (from `contracts/`):
///   forge script script/DeployCore.s.sol:DeployCore \
///     --rpc-url arc_testnet --broadcast --skip-simulation -vvvv
contract DeployCore is Script {
    int256 internal constant MOCK_ETH_USD_8DEC = 3_000e8;

    struct Deployed {
        address feeManager;
        address priceOracle;
        address loanRegistry;
        address collateralRegistry;
        address loanManager;
        address settlement;
        address healthViewer;
        address chainlinkOracle;
    }

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address governor = vm.addr(pk);
        address feeRecipient = vm.envOr("FEE_RECIPIENT", governor);
        address baseCurrency = vm.envOr("BASE_CURRENCY", ArcAddresses.USDC);
        uint256 baseCurrencyUnit = vm.envOr("BASE_CURRENCY_UNIT", uint256(1e6));
        address gatewayMinter = vm.envOr("GATEWAY_MINTER", ArcAddresses.GATEWAY_MINTER);

        console2.log("=== DeployCore ===");
        console2.log("chainId         ", block.chainid);
        console2.log("CREATE2 factory ", ArcAddresses.CREATE2_FACTORY);
        console2.log("Multicall3      ", ArcAddresses.MULTICALL3);
        console2.log("governor        ", governor);

        vm.startBroadcast(pk);
        Deployed memory d = _deploy(governor, feeRecipient, baseCurrency, baseCurrencyUnit, gatewayMinter);
        vm.stopBroadcast();

        _writeDeploymentJson(d, governor, baseCurrency, gatewayMinter);
        _log(d);
    }

    function _deploy(
        address governor,
        address feeRecipient,
        address baseCurrency,
        uint256 baseCurrencyUnit,
        address gatewayMinter
    ) internal returns (Deployed memory d) {
        d.feeManager = _deployFeeManager(governor, feeRecipient);
        d.priceOracle = _deployPriceOracle(governor, baseCurrency, baseCurrencyUnit);
        d.loanRegistry = _deployAllowlist(DeployConstants.SALT_LOAN_REGISTRY, governor, "LoanRegistry");
        d.collateralRegistry =
            _deployAllowlist(DeployConstants.SALT_COLLATERAL_REGISTRY, governor, "CollateralRegistry");

        address predictedSettlement = vm.computeCreateAddress(governor, vm.getNonce(governor) + 1);
        d.loanManager = address(new LoanManager(predictedSettlement, d.priceOracle, d.feeManager));
        d.settlement = address(
            new IntentSettlement(
                d.loanManager,
                gatewayMinter,
                d.feeManager,
                d.priceOracle,
                d.collateralRegistry,
                d.loanRegistry
            )
        );
        require(d.settlement == predictedSettlement, "Settlement address mismatch");
        console2.log("LoanManager      ", d.loanManager);
        console2.log("IntentSettlement ", d.settlement);

        d.healthViewer = _deployHealthViewer(d.loanManager);

        address ethUsdFeed = _resolveEthUsdFeed();
        if (ethUsdFeed != address(0)) {
            d.chainlinkOracle = _deployChainlinkOracle(ethUsdFeed, _decimalsOf(baseCurrencyUnit));
        }

        _configureFees(FeeManager(d.feeManager));
        if (!TokenAllowlist(d.loanRegistry).isApproved(baseCurrency)) {
            TokenAllowlist(d.loanRegistry).registerToken(baseCurrency);
        }
        _maybeWireWeth(PriceOracle(d.priceOracle), TokenAllowlist(d.collateralRegistry), d.chainlinkOracle);
    }

    function _deployFeeManager(address governor, address feeRecipient) internal returns (address addr) {
        bytes32 s = DeployConstants.salt(DeployConstants.SALT_FEE_MANAGER);
        bytes32 initHash =
            keccak256(abi.encodePacked(type(FeeManager).creationCode, abi.encode(governor, feeRecipient)));
        addr = vm.computeCreate2Address(s, initHash);
        if (addr.code.length == 0) {
            addr = address(new FeeManager{salt: s}(governor, feeRecipient));
            console2.log("FeeManager deployed", addr);
        } else {
            console2.log("FeeManager exists  ", addr);
        }
    }

    function _deployPriceOracle(address governor, address baseCurrency, uint256 baseCurrencyUnit)
        internal
        returns (address addr)
    {
        bytes32 s = DeployConstants.salt(DeployConstants.SALT_PRICE_ORACLE);
        bytes32 initHash = keccak256(
            abi.encodePacked(type(PriceOracle).creationCode, abi.encode(governor, baseCurrency, baseCurrencyUnit))
        );
        addr = vm.computeCreate2Address(s, initHash);
        if (addr.code.length == 0) {
            addr = address(new PriceOracle{salt: s}(governor, baseCurrency, baseCurrencyUnit));
            console2.log("PriceOracle deployed", addr);
        } else {
            console2.log("PriceOracle exists  ", addr);
        }
    }

    function _deployAllowlist(uint256 saltSeed, address governor, string memory label)
        internal
        returns (address addr)
    {
        bytes32 s = DeployConstants.salt(saltSeed);
        bytes32 initHash = keccak256(abi.encodePacked(type(TokenAllowlist).creationCode, abi.encode(governor)));
        addr = vm.computeCreate2Address(s, initHash);
        if (addr.code.length == 0) {
            addr = address(new TokenAllowlist{salt: s}(governor));
            console2.log(string.concat(label, " deployed"), addr);
        } else {
            console2.log(string.concat(label, " exists  "), addr);
        }
    }

    function _deployHealthViewer(address loanManager) internal returns (address addr) {
        bytes32 s = DeployConstants.salt(DeployConstants.SALT_HEALTH_VIEWER);
        bytes32 initHash =
            keccak256(abi.encodePacked(type(LoanHealthViewer).creationCode, abi.encode(loanManager)));
        addr = vm.computeCreate2Address(s, initHash);
        if (addr.code.length == 0) {
            addr = address(new LoanHealthViewer{salt: s}(loanManager));
            console2.log("LoanHealthViewer deployed", addr);
        } else {
            console2.log("LoanHealthViewer exists  ", addr);
        }
    }

    function _deployChainlinkOracle(address ethUsdFeed, uint8 targetDecimals) internal returns (address addr) {
        bytes32 s = DeployConstants.salt(DeployConstants.SALT_CHAINLINK_ORACLE);
        bytes memory ctor = abi.encode(ethUsdFeed, targetDecimals, "ETH / USD (Arc)");
        bytes32 initHash = keccak256(abi.encodePacked(type(ChainlinkOracle).creationCode, ctor));
        addr = vm.computeCreate2Address(s, initHash);
        if (addr.code.length == 0) {
            addr = address(new ChainlinkOracle{salt: s}(ethUsdFeed, targetDecimals, "ETH / USD (Arc)"));
            console2.log("ChainlinkOracle deployed", addr);
        } else {
            console2.log("ChainlinkOracle exists  ", addr);
        }
    }

    function _configureFees(FeeManager feeManager) internal {
        if (feeManager.originationFeeBps() == 0) feeManager.setOriginationFeeBps(100);
        if (feeManager.interestFeeBps() == 0) feeManager.setInterestFeeBps(500);
        if (feeManager.maxSolverTipBps() == 0) feeManager.setMaxSolverTipBps(500);
        if (feeManager.maxEarlyRepaymentFeeBps() == 0) feeManager.setMaxEarlyRepaymentFeeBps(10_000);
    }

    function _writeDeploymentJson(
        Deployed memory d,
        address governor,
        address baseCurrency,
        address gatewayMinter
    ) internal {
        vm.createDir("deployments", true);

        string memory root = "deployment";
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeAddress(root, "governor", governor);
        vm.serializeAddress(root, "baseCurrency", baseCurrency);
        vm.serializeAddress(root, "gatewayMinter", gatewayMinter);
        vm.serializeAddress(root, "create2Factory", ArcAddresses.CREATE2_FACTORY);
        vm.serializeAddress(root, "multicall3", ArcAddresses.MULTICALL3);
        vm.serializeAddress(root, "feeManager", d.feeManager);
        vm.serializeAddress(root, "priceOracle", d.priceOracle);
        vm.serializeAddress(root, "loanRegistry", d.loanRegistry);
        vm.serializeAddress(root, "collateralRegistry", d.collateralRegistry);
        vm.serializeAddress(root, "loanManager", d.loanManager);
        vm.serializeAddress(root, "intentSettlement", d.settlement);
        vm.serializeAddress(root, "loanHealthViewer", d.healthViewer);
        string memory json = vm.serializeAddress(root, "chainlinkOracle", d.chainlinkOracle);

        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        vm.writeJson(json, path);
        console2.log("Wrote", path);
    }

    function _maybeWireWeth(PriceOracle priceOracle, TokenAllowlist collateralRegistry, address chainlinkOracle)
        internal
    {
        address weth = vm.envOr("WETH_ADDRESS", address(0));
        if (weth == address(0) || weth.code.length == 0) {
            console2.log("WETH_ADDRESS unset; skip collateral/oracle wiring");
            return;
        }
        require(chainlinkOracle != address(0), "Need ChainlinkOracle to price WETH");
        if (!collateralRegistry.isApproved(weth)) {
            collateralRegistry.registerToken(weth);
        }
        if (priceOracle.assetPriceSource(weth) == address(0)) {
            priceOracle.setAssetPriceSource(weth, chainlinkOracle);
        }
        console2.log("Wired WETH collateral + price source", weth);
    }

    function _resolveEthUsdFeed() internal returns (address feed) {
        if (_envBool("SKIP_CHAINLINK_ORACLE", false)) {
            console2.log("SKIP_CHAINLINK_ORACLE=true; no ChainlinkOracle");
            return address(0);
        }

        feed = vm.envOr("ETH_USD_FEED", ArcAddresses.CHAINLINK_ETH_USD);
        if (feed.code.length > 0) {
            console2.log("Using live ETH/USD feed", feed);
            return feed;
        }

        console2.log("WARN: ETH/USD feed has no code; deploying mock stand-in", feed);
        MockChainlinkAggregator mock = new MockChainlinkAggregator(8);
        mock.mockSetValidAnswer(MOCK_ETH_USD_8DEC);
        return address(mock);
    }

    function _decimalsOf(uint256 unit) internal pure returns (uint8) {
        if (unit == 1e18) return 18;
        if (unit == 1e8) return 8;
        if (unit == 1e6) return 6;
        revert("Unsupported BASE_CURRENCY_UNIT");
    }

    function _log(Deployed memory d) internal pure {
        console2.log("=== Deployed ===");
        console2.log("FeeManager         ", d.feeManager);
        console2.log("PriceOracle        ", d.priceOracle);
        console2.log("LoanRegistry       ", d.loanRegistry);
        console2.log("CollateralRegistry ", d.collateralRegistry);
        console2.log("LoanManager        ", d.loanManager);
        console2.log("IntentSettlement   ", d.settlement);
        console2.log("LoanHealthViewer   ", d.healthViewer);
        console2.log("ChainlinkOracle    ", d.chainlinkOracle);
    }

    function _envBool(string memory key, bool defaultValue) internal view returns (bool) {
        try vm.envString(key) returns (string memory raw) {
            bytes32 h = keccak256(bytes(raw));
            if (h == keccak256("true") || h == keccak256("1") || h == keccak256("TRUE")) return true;
            if (h == keccak256("false") || h == keccak256("0") || h == keccak256("FALSE")) return false;
            return defaultValue;
        } catch {
            return defaultValue;
        }
    }
}
