// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {PearcurveTestBase} from "./helpers/PearcurveTestBase.sol";
import {IntentTypes} from "../src/libraries/IntentTypes.sol";

contract IntentTypesTest is PearcurveTestBase {
    function test_lenderHash_isDeterministic() public view {
        IntentTypes.LenderIntent memory i = _defaultLenderIntent();
        assertEq(_lenderHash(i), _lenderHash(i));
    }

    function test_borrowerHash_isDeterministic() public view {
        IntentTypes.BorrowerIntent memory i = _defaultBorrowerIntent(1000e6);
        assertEq(_borrowerHash(i), _borrowerHash(i));
    }

    function test_lenderHash_changesWithField() public view {
        IntentTypes.LenderIntent memory a = _defaultLenderIntent();
        IntentTypes.LenderIntent memory b = _defaultLenderIntent();
        b.nonce = 2;
        assertTrue(_lenderHash(a) != _lenderHash(b));
    }

    function test_borrowerHash_matchesAbiEncodeReference() public pure {
        IntentTypes.BorrowerIntent memory i = IntentTypes.BorrowerIntent({
            owner: address(0xBEEF),
            loanToken: address(0x1),
            collateralToken: address(0x2),
            principal: 100e6,
            maxRate: 900,
            duration: 30 days,
            maxCollateralAmount: 1 ether,
            solverTipBps: 25,
            expiry: 999,
            nonce: 7
        });

        bytes32 typeHash = keccak256(
            "BorrowerIntent(address owner,address loanToken,address collateralToken,"
            "uint256 principal,uint256 maxRate,uint256 duration,uint256 maxCollateralAmount,"
            "uint256 solverTipBps,uint256 expiry,uint256 nonce)"
        );
        bytes32 expected = keccak256(
            abi.encode(
                typeHash,
                i.owner,
                i.loanToken,
                i.collateralToken,
                i.principal,
                i.maxRate,
                i.duration,
                i.maxCollateralAmount,
                i.solverTipBps,
                i.expiry,
                i.nonce
            )
        );
        assertEq(IntentTypesTestHelper.borrowerHash(i), expected);
    }
}

library IntentTypesTestHelper {
    using IntentTypes for IntentTypes.BorrowerIntent;

    function borrowerHash(IntentTypes.BorrowerIntent memory i) internal pure returns (bytes32) {
        return i.hash();
    }
}
