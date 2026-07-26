// SPDX-License-Identifier: LicenseRef-BUSL
pragma solidity ^0.8.24;

/// @title CreateAddress
/// @notice `CREATE` address prediction for nonce < 128 (enough for one-shot core deploy).
library CreateAddress {
    function compute(address deployer, uint256 nonce) internal pure returns (address) {
        if (nonce == 0) {
            return
                address(
                    uint160(uint256(keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), deployer, bytes1(0x80)))))
                );
        }
        require(nonce <= type(uint8).max, "nonce too high");
        return
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), deployer, uint8(nonce))))));
    }
}
