// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {SeerToken} from "../src/SeerToken.sol";

/// @dev Does what the launch factory does with the supply, in one transaction: deploys the token,
/// forwards the swarm's ten percent to a distributor, a pool share to a pool manager stand-in and the
/// remainder to the requester. Returns what each recipient actually received.
contract LaunchFlowProbe {
    function launch(address distributor, address poolManager, address requester, uint256 poolBps)
        external
        returns (SeerToken token, uint256 toDistributor, uint256 toPool, uint256 toRequester)
    {
        token = new SeerToken();
        uint256 supply = token.totalSupply();
        uint256 swarm = (supply * 1_000) / 10_000;
        uint256 pool = (supply * poolBps) / 10_000;
        require(token.transfer(distributor, swarm), "swarm transfer");
        require(token.transfer(poolManager, pool), "pool transfer");
        require(token.transfer(requester, token.balanceOf(address(this))), "remainder transfer");
        return (token, token.balanceOf(distributor), token.balanceOf(poolManager), token.balanceOf(requester));
    }
}

contract SeerTokenEdgeTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    // secp256k1 group order
    uint256 internal constant N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    SeerToken internal token;
    uint256 internal ownerKey = 0x0E1;
    address internal owner;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        vm.warp(1_700_000_000);
        token = new SeerToken();
        owner = vm.addr(ownerKey);
        token.transfer(owner, 100 ether);
    }

    function _digest(address o, address spender, uint256 value, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                o,
                spender,
                value,
                nonce,
                deadline
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
    }

    function _domainSeparator(uint256 chainId) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("SeerIMD"),
                keccak256("1"),
                chainId,
                address(token)
            )
        );
    }

    // ---------------------------------------------------------------------------------------------
    // Launch flows: exact amounts, one transaction
    // ---------------------------------------------------------------------------------------------

    function test_launchFlowsArriveExact() public {
        LaunchFlowProbe probe = new LaunchFlowProbe();
        address distributor = address(0xD157);
        address manager = address(0x4444);
        address requester = address(0x7E9);
        (SeerToken t, uint256 d, uint256 p, uint256 r) = probe.launch(distributor, manager, requester, 5_000);
        assertEq(d, SUPPLY / 10, "swarm share short");
        assertEq(p, SUPPLY / 2, "pool share short");
        assertEq(r, SUPPLY - SUPPLY / 10 - SUPPLY / 2, "remainder short");
        assertEq(t.balanceOf(address(probe)), 0);
        assertEq(t.totalSupply(), SUPPLY);

        // the distributor pays claims out whole, down to the last wei
        vm.prank(distributor);
        t.transfer(alice, d - 1);
        vm.prank(distributor);
        t.transfer(bob, 1);
        assertEq(t.balanceOf(distributor), 0);
        assertEq(t.balanceOf(alice) + t.balanceOf(bob), SUPPLY / 10);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_launchFlowsExactForAnyPoolShare(uint256 poolBps) public {
        poolBps = bound(poolBps, 0, 9_000);
        LaunchFlowProbe probe = new LaunchFlowProbe();
        (SeerToken t, uint256 d, uint256 p, uint256 r) =
            probe.launch(address(0xD157), address(0x4444), address(0x7E9), poolBps);
        assertEq(d, SUPPLY / 10);
        assertEq(p, (SUPPLY * poolBps) / 10_000);
        assertEq(d + p + r, SUPPLY);
        assertEq(t.totalSupply(), SUPPLY);
    }

    // ---------------------------------------------------------------------------------------------
    // Edge amounts and callers
    // ---------------------------------------------------------------------------------------------

    function test_transferFromZeroAmountNeedsNoAllowance() public {
        // OZ: spending 0 against an allowance of 0 is fine; nothing moves, no error.
        vm.prank(alice);
        assertTrue(token.transferFrom(owner, bob, 0));
        assertEq(token.balanceOf(owner), 100 ether);
        assertEq(token.allowance(owner, alice), 0);
    }

    function test_transferFromToZeroAddressRevertsAndKeepsAllowance() public {
        vm.prank(owner);
        token.approve(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(owner, address(0), 1 ether);
        // the revert unwinds the allowance spend
        assertEq(token.allowance(owner, alice), 10 ether);
        assertEq(token.balanceOf(owner), 100 ether);
    }

    function test_transferFromZeroAddressOwnerReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(address(0), bob, 1);
    }

    function test_transferFromExactAllowanceLeavesZero() public {
        vm.prank(owner);
        token.approve(alice, 100 ether);
        vm.prank(alice);
        token.transferFrom(owner, bob, 100 ether);
        assertEq(token.allowance(owner, alice), 0);
        assertEq(token.balanceOf(owner), 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(owner, bob, 1);
    }

    function test_maxAllowanceStillBoundedByBalance() public {
        vm.prank(owner);
        token.approve(alice, type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, 100 ether, 100 ether + 1)
        );
        token.transferFrom(owner, bob, 100 ether + 1);
        assertEq(token.allowance(owner, alice), type(uint256).max);
    }

    function test_transferMaxUintReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY - 100 ether, type(uint256).max
            )
        );
        token.transfer(alice, type(uint256).max);
    }

    function test_selfApprovalAndSelfTransferFrom() public {
        vm.startPrank(owner);
        token.approve(owner, 5 ether);
        assertTrue(token.transferFrom(owner, owner, 5 ether));
        vm.stopPrank();
        assertEq(token.balanceOf(owner), 100 ether);
        assertEq(token.allowance(owner, owner), 0);
    }

    function test_transferFromDoesNotEmitApproval() public {
        vm.prank(owner);
        token.approve(alice, 10 ether);
        vm.recordLogs();
        vm.prank(alice);
        token.transferFrom(owner, bob, 1 ether);
        assertEq(vm.getRecordedLogs().length, 1, "only the Transfer event");
    }

    // ---------------------------------------------------------------------------------------------
    // Permit edges
    // ---------------------------------------------------------------------------------------------

    function test_eip712DomainMatchesNameAndVersion() public view {
        (bytes1 fields, string memory name, string memory version, uint256 chainId, address verifying,,) =
            token.eip712Domain();
        assertEq(fields, hex"0f");
        assertEq(name, "SeerIMD");
        assertEq(version, "1");
        assertEq(chainId, block.chainid);
        assertEq(verifying, address(token));
        assertEq(token.DOMAIN_SEPARATOR(), _domainSeparator(block.chainid));
    }

    function test_domainSeparatorFollowsChainId() public {
        bytes32 before = token.DOMAIN_SEPARATOR();
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, _digest(owner, alice, 1 ether, 0, deadline));
        vm.chainId(block.chainid + 1);
        assertTrue(token.DOMAIN_SEPARATOR() != before);
        assertEq(token.DOMAIN_SEPARATOR(), _domainSeparator(block.chainid));
        // a signature for the old chain does not replay on the fork
        vm.expectRevert();
        token.permit(owner, alice, 1 ether, deadline, v, r, s);
        assertEq(token.allowance(owner, alice), 0);
        assertEq(token.nonces(owner), 0);
    }

    function test_permitAtExactDeadlineSucceeds() public {
        uint256 deadline = block.timestamp;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, _digest(owner, alice, 1 ether, 0, deadline));
        token.permit(owner, alice, 1 ether, deadline, v, r, s);
        assertEq(token.allowance(owner, alice), 1 ether);
    }

    function test_permitEmitsApproval() public {
        uint256 deadline = block.timestamp + 1;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, _digest(owner, alice, 3 ether, 0, deadline));
        vm.expectEmit(true, true, true, true);
        emit Approval(owner, alice, 3 ether);
        token.permit(owner, alice, 3 ether, deadline, v, r, s);
    }

    function test_permitRejectsMalleableHighS() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, _digest(owner, alice, 1 ether, 0, deadline));
        bytes32 highS = bytes32(N - uint256(s));
        uint8 flippedV = v == 27 ? 28 : 27;
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureS.selector, highS));
        token.permit(owner, alice, 1 ether, deadline, flippedV, r, highS);
        assertEq(token.nonces(owner), 0);
    }

    function test_permitRejectsBadV() public {
        uint256 deadline = block.timestamp + 1 hours;
        (, bytes32 r, bytes32 s) = vm.sign(ownerKey, _digest(owner, alice, 1 ether, 0, deadline));
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignature.selector));
        token.permit(owner, alice, 1 ether, deadline, 0, r, s);
    }

    function test_permitForZeroOwnerWithGarbageSignatureReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignature.selector));
        token.permit(address(0), alice, 1 ether, block.timestamp, 27, bytes32(0), bytes32(0));
        assertEq(token.allowance(address(0), alice), 0);
    }

    function test_permitToZeroSpenderReverts() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, _digest(owner, address(0), 1 ether, 0, deadline));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.permit(owner, address(0), 1 ether, deadline, v, r, s);
        assertEq(token.nonces(owner), 0, "a reverted permit must not burn the nonce");
    }

    function test_permitOutOfOrderNonceRejected() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, _digest(owner, alice, 1 ether, 1, deadline));
        vm.expectRevert();
        token.permit(owner, alice, 1 ether, deadline, v, r, s);
    }

    function test_permitOverwritesExistingAllowance() public {
        vm.prank(owner);
        token.approve(alice, 50 ether);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, _digest(owner, alice, 0, 0, deadline));
        token.permit(owner, alice, 0, deadline, v, r, s);
        assertEq(token.allowance(owner, alice), 0);
    }

    function test_permitRevertsWhenSpenderChanged() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, _digest(owner, alice, 1 ether, 0, deadline));
        vm.expectRevert();
        token.permit(owner, bob, 1 ether, deadline, v, r, s);
        assertEq(token.allowance(owner, bob), 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Fuzzed properties
    // ---------------------------------------------------------------------------------------------

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_transferChainConservesSupply(address a, address b, uint256 x, uint256 y) public {
        a = address(uint160(bound(uint160(a), 1, type(uint160).max)));
        b = address(uint160(bound(uint160(b), 1, type(uint160).max)));
        uint256 start = token.balanceOf(address(this));
        x = bound(x, 0, start);
        token.transfer(a, x);
        uint256 balA = token.balanceOf(a);
        y = bound(y, 0, balA);
        vm.prank(a);
        token.transfer(b, y);
        assertEq(token.totalSupply(), SUPPLY);
        // a and b may coincide with each other, this contract or the owner: check conservation by set
        uint256 sum = token.balanceOf(address(this));
        if (a != address(this)) sum += token.balanceOf(a);
        if (b != address(this) && b != a) sum += token.balanceOf(b);
        if (owner != address(this) && owner != a && owner != b) sum += token.balanceOf(owner);
        assertEq(sum, SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_approveAnyValueThenSpend(uint256 allowance_, uint256 spend) public {
        vm.prank(owner);
        token.approve(alice, allowance_);
        assertEq(token.allowance(owner, alice), allowance_);
        spend = bound(spend, 0, 100 ether);
        vm.prank(alice);
        if (spend > allowance_) {
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, allowance_, spend)
            );
            token.transferFrom(owner, bob, spend);
        } else {
            token.transferFrom(owner, bob, spend);
            assertEq(token.balanceOf(bob), spend);
            assertEq(token.allowance(owner, alice), allowance_ == type(uint256).max ? allowance_ : allowance_ - spend);
        }
    }
}
