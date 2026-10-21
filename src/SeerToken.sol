// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title SeerIMD (SEER)
/// @notice A fixed-supply ERC-20. The whole supply is minted once, in the constructor, to the
/// deployer (`msg.sender`). There is no owner, no minter, no pause, no blocklist, no fee and no
/// burn hook: after deployment the contract has no privileged function of any kind.
/// @dev The contract name is `SeerToken` (the launch manifest records the Solidity identifier,
/// at most 32 characters); the token's `name()` is "SeerIMD" and its `symbol()` is "SEER".
///
/// Design notes:
/// - Plain OpenZeppelin v5 `ERC20` semantics: transfers to the zero address revert, transfers
///   above a balance revert, allowances are decremented unless set to `type(uint256).max`.
/// - EIP-2612 `permit` (OpenZeppelin `ERC20Permit`) so holders can approve by signature; it adds
///   no admin surface.
/// - No constructor arguments. The launch factory deploys the creation code as built and
///   receives the entire supply because it is `msg.sender` of the constructor.
/// - `totalSupply()` can never grow: nothing calls `_mint` after the constructor. It can never
///   shrink either: there is no burn function.
contract SeerToken is ERC20, ERC20Permit {
    /// @notice The token name returned by `name()` and used as the EIP-712 domain name.
    string public constant TOKEN_NAME = "SeerIMD";

    /// @notice The token symbol returned by `symbol()`.
    string public constant TOKEN_SYMBOL = "SEER";

    /// @notice Number of decimals; the same as `decimals()`.
    uint8 public constant DECIMALS = 18;

    /// @notice The whole supply in minor units: 1,000,000,000 SEER with 18 decimals.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** uint256(DECIMALS);

    /// @notice Mints `TOTAL_SUPPLY` once to the deployer (`msg.sender`).
    /// @dev Emits a single `Transfer(address(0), msg.sender, TOTAL_SUPPLY)`.
    constructor() ERC20(TOKEN_NAME, TOKEN_SYMBOL) ERC20Permit(TOKEN_NAME) {
        _mint(msg.sender, TOTAL_SUPPLY);
    }

    /// @inheritdoc ERC20
    function decimals() public pure override returns (uint8) {
        return DECIMALS;
    }
}
