// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @notice Shared structs and EIP-712 type hashes for Pearcurve intents.
/// @dev Intents are always signed off-chain (free, instant, zero gas until matched) and
///      converge on IntentSettlement.matchIntents(). TYPEHASH must list exactly the fields
///      that `hash()` encodes — nothing more.
library IntentTypes {
    struct LenderIntent {
        address owner; // EOA or vault contract (EIP-1271)
        address loanToken;
        address collateralToken;
        uint256 minPrincipal;
        uint256 maxPrincipal;
        uint256 minRate; // bps
        uint256 minDuration; // seconds
        uint256 maxDuration; // seconds
        uint256 originationLtvBps; // max LTV at origination
        uint256 liquidationLtvBps; // LTV that triggers liquidation
        uint256 earlyRepaymentFeeBps; // % of REMAINING interest, 0-10000. repay() is NEVER
        // blocked outright; 10000 = borrower can still repay
        // early but pays full remaining interest as if held
        // to maturity, the economic equivalent of a block.
        bool allowPartialFill;
        uint256 maxPerBorrowerAddress; // 0 = unlimited
        uint256 expiry;
        uint256 nonce;
    }

    struct BorrowerIntent {
        address owner;
        address loanToken;
        address collateralToken;
        uint256 principal;
        uint256 maxRate; // bps
        uint256 duration; // seconds
        uint256 maxCollateralAmount; // 0 = unlimited
        uint256 solverTipBps; // paid by borrower, in `loanToken`
        uint256 expiry;
        uint256 nonce;
    }

    bytes32 internal constant LENDER_INTENT_TYPEHASH = keccak256(
        "LenderIntent(address owner,address loanToken,address collateralToken,"
        "uint256 minPrincipal,uint256 maxPrincipal,uint256 minRate,"
        "uint256 minDuration,uint256 maxDuration,uint256 originationLtvBps,"
        "uint256 liquidationLtvBps,uint256 earlyRepaymentFeeBps,bool allowPartialFill,"
        "uint256 maxPerBorrowerAddress,uint256 expiry,uint256 nonce)"
    );

    bytes32 internal constant BORROWER_INTENT_TYPEHASH = keccak256(
        "BorrowerIntent(address owner,address loanToken,address collateralToken,"
        "uint256 principal,uint256 maxRate,uint256 duration,uint256 maxCollateralAmount,"
        "uint256 solverTipBps,uint256 expiry,uint256 nonce)"
    );

    /// @dev EIP-712 struct hash: `keccak256(abi.encode(TYPEHASH, fields...))`. Packed manually
    ///      because a 16-argument `abi.encode` hits stack-too-deep under coverage builds.
    function hash(LenderIntent memory i) internal pure returns (bytes32 result) {
        bytes32 typeHash = LENDER_INTENT_TYPEHASH;
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, typeHash)
            let src := i
            let dest := add(ptr, 0x20)
            for { let o := 0 } lt(o, 0x1e0) { o := add(o, 0x20) } {
                mstore(add(dest, o), mload(add(src, o)))
            }
            result := keccak256(ptr, 0x200)
            mstore(0x40, add(ptr, 0x200))
        }
    }

    /// @dev Same packing approach as `hash(LenderIntent)`.
    function hash(BorrowerIntent memory i) internal pure returns (bytes32 result) {
        bytes32 typeHash = BORROWER_INTENT_TYPEHASH;
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, typeHash)
            let src := i
            let dest := add(ptr, 0x20)
            for { let o := 0 } lt(o, 0x140) { o := add(o, 0x20) } {
                mstore(add(dest, o), mload(add(src, o)))
            }
            result := keccak256(ptr, 0x160)
            mstore(0x40, add(ptr, 0x160))
        }
    }
}
