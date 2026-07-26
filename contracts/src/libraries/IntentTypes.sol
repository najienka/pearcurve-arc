// SPDX-License-Identifier: LicenseRef-BUSL
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

    /// @notice EIP-712 struct hash for a lender intent.
    /// @dev Computes `keccak256(abi.encode(LENDER_INTENT_TYPEHASH, i.owner, i.loanToken, ...))`.
    ///
    ///      A plain 16-argument `abi.encode` hits stack-too-deep when coverage disables `via_ir`,
    ///      so we build the same ABI word buffer manually:
    ///
    ///      1. `LenderIntent` in memory is 15 consecutive 32-byte slots, one per struct field, in
    ///         declaration order (`owner` at offset 0, `loanToken` at 0x20, …, `nonce` at 0x1c0).
    ///         `address`, `uint256`, and `bool` each occupy a full word (`bool` is 0 or 1).
    ///      2. `abi.encode(TYPEHASH, field1, …, fieldN)` for these static types is exactly 16 words
    ///         (512 bytes = 0x200): word 0 is `LENDER_INTENT_TYPEHASH`, words 1–15 are the struct
    ///         slots copied verbatim from `i`.
    ///      3. Assembly writes `typeHash` at `ptr`, copies 0x1e0 bytes (15 words) from `i` into
    ///         `ptr + 0x20`, then `keccak256(ptr, 0x200)`. The free-memory pointer is bumped by
    ///         0x200 so the scratch buffer does not clobber the Solidity allocator.
    ///
    ///      Field order hashed (must match `LENDER_INTENT_TYPEHASH`):
    ///      owner, loanToken, collateralToken, minPrincipal, maxPrincipal, minRate, minDuration,
    ///      maxDuration, originationLtvBps, liquidationLtvBps, earlyRepaymentFeeBps,
    ///      allowPartialFill, maxPerBorrowerAddress, expiry, nonce.
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

    /// @notice EIP-712 struct hash for a borrower intent.
    /// @dev Same manual ABI packing as `hash(LenderIntent)`:
    ///
    ///      `BorrowerIntent` is 10 struct fields → 10 words (0x140 bytes) after the typehash word.
    ///      Total buffer is 11 words (0x160 bytes): word 0 is `BORROWER_INTENT_TYPEHASH`, words
    ///      1–10 are copied from `i` in declaration order.
    ///
    ///      Field order hashed (must match `BORROWER_INTENT_TYPEHASH`):
    ///      owner, loanToken, collateralToken, principal, maxRate, duration, maxCollateralAmount,
    ///      solverTipBps, expiry, nonce.
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
