// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

/// @notice Verifies signatures from both EOAs and smart contracts (curated
///         vaults, Safe multisigs, or any EIP-1271-compliant signer).
library SignatureLib {
    bytes4 internal constant EIP1271_MAGIC_VALUE = 0x1626ba7e;

    function isValidSignature(address signer, bytes32 digest, bytes memory signature) internal view returns (bool) {
        if (signer.code.length == 0) {
            (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, signature);
            return err == ECDSA.RecoverError.NoError && recovered == signer;
        }

        try IERC1271(signer).isValidSignature(digest, signature) returns (bytes4 magicValue) {
            return magicValue == EIP1271_MAGIC_VALUE;
        } catch {
            return false;
        }
    }
}
