// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {PearcurveTestBase} from "./helpers/PearcurveTestBase.sol";
import {PriceOracle} from "../src/oracles/PriceOracle.sol";
import {ChainlinkAggregatorV2V3} from "../src/oracles/ChainlinkAggregatorV2V3.sol";
import {WBTCOracle} from "../src/oracles/WBTCOracle.sol";
import {MockChainlinkAggregator} from "./mocks/MockChainlinkAggregator.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract PriceOracleTest is PearcurveTestBase {
    function test_getPrice_sameDecimals() public view {
        uint256 price = priceOracle.getPrice(address(col), address(usdc));
        assertEq(price, 2_000_000_000); // 2000 USDC per 1 COL (raw 6-dec scale)
    }

    function test_getAssetPrice_baseCurrency() public view {
        assertEq(priceOracle.getAssetPrice(address(weth)), 1e18);
    }

    function test_getAssetPrice_zeroWhenUnregistered() public {
        assertEq(priceOracle.getAssetPrice(makeAddr("missing")), 0);
    }

    function test_getPrice_zeroWhenFeedReturnsZero() public {
        _setFreshFeed(colFeed, 0);
        assertEq(priceOracle.getPrice(address(col), address(usdc)), 0);
    }

    function test_staleFeedViaIncompleteRound() public {
        colFeed.mockSetIncompleteRound(666666666666666666);
        assertTrue(priceOracle.isPairPriceStale(address(col), address(usdc)));
    }

    function test_staleFeedViaV2TimestampFallback() public {
        MockChainlinkAggregator v2Only = new MockChainlinkAggregator(8);
        v2Only.mockSetValidAnswer(1e10);
        address asset = makeAddr("v2asset");
        vm.prank(governor);
        priceOracle.setAssetPriceSource(asset, address(v2Only));

        assertFalse(priceOracle.isPairPriceStale(asset, address(usdc)));

        vm.warp(block.timestamp + 2 days);
        assertTrue(priceOracle.isPairPriceStale(asset, address(usdc)));
    }

    function test_chainlinkAggregatorV2V3_compositePrice() public {
        MockChainlinkAggregator underlyingUsd = new MockChainlinkAggregator(8);
        MockChainlinkAggregator baseUsd = new MockChainlinkAggregator(8);
        _setFreshFeed(underlyingUsd, 2e8); // $2
        _setFreshFeed(baseUsd, 2000e8); // $2000

        ChainlinkAggregatorV2V3 composite =
            new ChainlinkAggregatorV2V3(address(underlyingUsd), address(baseUsd), "TKN / ETH");
        assertEq(composite.latestAnswer(), 1e15); // 2e8 * 1e18 / 2000e8
        assertEq(composite.decimals(), 18);
        assertEq(composite.latestTimestamp(), block.timestamp);
    }

    function test_wbtcOracle_compositePrice() public {
        MockChainlinkAggregator wbtcBtc = new MockChainlinkAggregator(8);
        MockChainlinkAggregator btcEth = new MockChainlinkAggregator(18);
        _setFreshFeed(wbtcBtc, 1e8); // 1 WBTC = 1 BTC
        _setFreshFeed(btcEth, 20e18); // 1 BTC = 20 ETH

        WBTCOracle oracle = new WBTCOracle(address(wbtcBtc), address(btcEth));
        assertEq(oracle.latestAnswer(), 20e18);
        assertEq(oracle.description(), "WBTC / base");
    }

    function test_wbtcOracle_latestTimestampUsesOlderFeed() public {
        MockChainlinkAggregator wbtcBtc = new MockChainlinkAggregator(8);
        MockChainlinkAggregator btcEth = new MockChainlinkAggregator(18);
        _setFreshFeed(wbtcBtc, 1e8);
        _setFreshFeed(btcEth, 20e18);

        vm.warp(block.timestamp + 100);
        wbtcBtc.mockSetValidAnswer(1e8);

        WBTCOracle oracle = new WBTCOracle(address(wbtcBtc), address(btcEth));
        assertEq(oracle.latestTimestamp(), block.timestamp - 100);
    }

    function test_wbtcOracle_returnsZeroOnBadFeed() public {
        MockChainlinkAggregator wbtcBtc = new MockChainlinkAggregator(8);
        MockChainlinkAggregator btcEth = new MockChainlinkAggregator(18);
        _setFreshFeed(wbtcBtc, -1);
        _setFreshFeed(btcEth, 20e18);

        WBTCOracle oracle = new WBTCOracle(address(wbtcBtc), address(btcEth));
        assertEq(oracle.latestAnswer(), 0);
    }

    function test_chainlinkAggregator_revertsOnDecimalMismatch() public {
        MockChainlinkAggregator a = new MockChainlinkAggregator(8);
        MockChainlinkAggregator b = new MockChainlinkAggregator(18);
        vm.expectRevert("Feed decimals mismatch");
        new ChainlinkAggregatorV2V3(address(a), address(b), "bad");
    }

    function test_priceOracle_revertsOnDecimalRange() public {
        MockERC20 badCol = new MockERC20("BAD", "BAD", 30);
        MockChainlinkAggregator feed = new MockChainlinkAggregator(18);
        _setFreshFeed(feed, 1e18);
        address asset = address(badCol);
        vm.prank(governor);
        priceOracle.setAssetPriceSource(asset, address(feed));

        vm.expectRevert("Decimals out of range");
        priceOracle.getPrice(asset, address(usdc));
    }

    function test_priceOracle_unregisteredAssetIsStale() public {
        assertTrue(priceOracle.isPairPriceStale(makeAddr("unknown"), address(usdc)));
    }
}
