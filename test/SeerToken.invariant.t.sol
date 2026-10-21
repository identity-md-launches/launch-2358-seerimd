// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SeerToken} from "../src/SeerToken.sol";

/// @dev Drives the token with random, always-valid transfers and approvals among a fixed set of
/// actors so the invariants below are checked across many interleavings. Every call is bounded to
/// succeed; `fail_on_revert = true` in foundry.toml then turns any unexpected revert into a failure.
contract SeerTokenHandler is Test {
    SeerToken internal token;
    address[] public actors;

    constructor(SeerToken token_, address initialHolder) {
        token = token_;
        actors.push(initialHolder);
        for (uint256 i = 1; i < 6; ++i) {
            actors.push(address(uint160(0xA000 + i)));
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        amount = bound(amount, 0, token.balanceOf(from));
        vm.prank(from);
        token.transfer(to, amount);
    }

    function approveAndTransferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        address to = actors[toSeed % actors.length];
        amount = bound(amount, 0, token.balanceOf(owner));
        vm.prank(owner);
        token.approve(spender, amount);
        vm.prank(spender);
        token.transferFrom(owner, to, amount);
    }
}

contract SeerTokenInvariantTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    SeerToken internal token;
    SeerTokenHandler internal handler;

    function setUp() public {
        token = new SeerToken();
        handler = new SeerTokenHandler(token, address(this));
        // The handler's first actor is this contract, the deployer, which already holds everything.
        targetContract(address(handler));
    }

    function invariant_totalSupplyIsConstant() public view {
        assertEq(token.totalSupply(), SUPPLY);
    }

    function invariant_balancesSumToSupply() public view {
        uint256 sum;
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            sum += token.balanceOf(handler.actors(i));
        }
        assertEq(sum, SUPPLY, "tokens leaked out of or into the actor set");
    }

    function invariant_zeroAddressHoldsNothing() public view {
        assertEq(token.balanceOf(address(0)), 0);
    }
}
