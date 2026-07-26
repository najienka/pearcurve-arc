// SPDX-License-Identifier: LicenseRef-BUSL
pragma solidity ^0.8.24;

import {PearcurveTestBase} from "./helpers/PearcurveTestBase.sol";
import {TokenAllowlist} from "../src/registry/TokenAllowlist.sol";
import {FeeManager} from "../src/fees/FeeManager.sol";
import {PriceOracle} from "../src/oracles/PriceOracle.sol";
import {MockChainlinkAggregator} from "./mocks/MockChainlinkAggregator.sol";

contract GovernanceTest is PearcurveTestBase {
    function test_governable_twoStepTransfer() public {
        address newGov = makeAddr("newGov");
        vm.prank(governor);
        loanRegistry.transferGovernance(newGov);

        vm.expectRevert("Not pending governor");
        loanRegistry.acceptGovernance();

        vm.prank(newGov);
        loanRegistry.acceptGovernance();
        assertEq(loanRegistry.governor(), newGov);
    }

    function test_tokenAllowlist_registerAndRemove() public {
        address token = makeAddr("token");
        vm.startPrank(governor);
        loanRegistry.registerToken(token);
        assertTrue(loanRegistry.isApproved(token));
        loanRegistry.removeToken(token);
        vm.stopPrank();
        assertFalse(loanRegistry.isApproved(token));

        vm.expectRevert("Token not approved");
        loanRegistry.requireApproved(token);
    }

    function test_feeManager_settersAndCaps() public {
        vm.startPrank(governor);
        feeManager.setFeeRecipient(makeAddr("newRecipient"));
        feeManager.setOriginationFeeBps(500);
        feeManager.setMaxSolverTipBps(500);
        feeManager.setInterestFeeBps(2000);
        feeManager.setMaxEarlyRepaymentFeeBps(10000);
        vm.stopPrank();

        vm.prank(governor);
        vm.expectRevert("Fee too high");
        feeManager.setOriginationFeeBps(501);
    }

    function test_priceOracle_governanceAndStaleness() public {
        address asset = makeAddr("asset");
        MockChainlinkAggregator feed = new MockChainlinkAggregator(8);
        _setFreshFeed(feed, 1e10);

        vm.startPrank(governor);
        priceOracle.setAssetPriceSource(asset, address(feed));
        priceOracle.setDefaultStalenessThreshold(2 days);
        priceOracle.setAssetStalenessThreshold(asset, 1 hours);
        vm.stopPrank();

        assertFalse(priceOracle.isPairPriceStale(asset, address(usdc)));

        vm.warp(block.timestamp + 2 hours);
        assertTrue(priceOracle.isPairPriceStale(asset, address(usdc)));

        vm.prank(governor);
        vm.expectRevert("Bad threshold");
        priceOracle.setDefaultStalenessThreshold(0);
    }
}
