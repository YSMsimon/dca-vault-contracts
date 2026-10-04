// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Minimal SafeERC20. Handles tokens that return nothing or return
///         false, and refuses an address with no code at all.
/// @dev    Base USDC does return a bool, but B20 tokens are native precompiles
///         and route tokens are admitted by governance over time — so the vault
///         must not assume any particular return convention.
///
///         The code-size check matters because a low-level `call` to an address
///         with no code SUCCEEDS with empty return data, which the
///         "returns nothing" branch would otherwise read as a transfer that
///         happened. B20 precompiles carry a one-byte `0xef` stub precisely so
///         checks like this one pass for them.
library SafeTransfer {
    error TransferFailed();
    error ApproveFailed();
    error NoCode();

    function safeTransfer(address token, address to, uint256 amount) internal {
        if (token.code.length == 0) revert NoCode();
        (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(0xa9059cbb, to, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    function safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        if (token.code.length == 0) revert NoCode();
        (bool ok, bytes memory data) =
            token.call(abi.encodeWithSelector(0x23b872dd, from, to, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    function safeApprove(address token, address spender, uint256 amount) internal {
        if (token.code.length == 0) revert NoCode();
        (bool ok, bytes memory data) =
            token.call(abi.encodeWithSelector(0x095ea7b3, spender, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert ApproveFailed();
    }
}
