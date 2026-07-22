// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

/// @notice Configurable EIP-1271 wallet for signature tests.
contract MockERC1271 is IERC1271 {
    bytes4 internal constant MAGIC = 0x1626ba7e;

    address public owner;
    bytes32 public validDigest;
    bytes public validSignature;
    bool public requireExactSignature;
    bool public shouldRevert;
    bytes4 public customMagic; // if non-zero and digest matches, return this instead of MAGIC
    bool public useCustomMagic;

    constructor(address _owner) {
        owner = _owner;
    }

    function setValidDigest(bytes32 digest) external {
        require(msg.sender == owner, "Not owner");
        validDigest = digest;
    }

    function setValidSignature(bytes calldata sig) external {
        require(msg.sender == owner, "Not owner");
        validSignature = sig;
        requireExactSignature = true;
    }

    function setShouldRevert(bool value) external {
        require(msg.sender == owner, "Not owner");
        shouldRevert = value;
    }

    function setCustomMagic(bytes4 magic) external {
        require(msg.sender == owner, "Not owner");
        customMagic = magic;
        useCustomMagic = true;
    }

    function isValidSignature(bytes32 digest, bytes memory signature) external view returns (bytes4) {
        if (shouldRevert) revert("ERC1271 revert");
        if (digest != validDigest) return bytes4(0);
        if (requireExactSignature && keccak256(signature) != keccak256(validSignature)) return bytes4(0);
        if (useCustomMagic) return customMagic;
        return MAGIC;
    }
}
