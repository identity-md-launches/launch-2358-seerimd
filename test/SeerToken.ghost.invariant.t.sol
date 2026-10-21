// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {SeerToken} from "../src/SeerToken.sol";

/// @dev Stateful handler with a ghost model of every balance, allowance and nonce. Unlike the
/// all-valid handler in SeerToken.invariant.t.sol it also drives the failure paths (overdrafts,
/// over-allowance spends, zero-address receivers and spenders, expired / forged / replayed permits)
/// and checks, inside the call, that each one reverts with the expected error and changes nothing.
/// Failure paths are exercised through try/catch so the run stays compatible with
/// `fail_on_revert = true`; an unexpected success or a wrong error is recorded and fails an invariant.
contract SeerGhostHandler is Test {
    SeerToken internal immutable token;

    uint256 internal constant N_ACTORS = 5;
    address[] internal actors;
    uint256[] internal keys;

    mapping(address => uint256) public ghostBalance;
    mapping(address => mapping(address => uint256)) public ghostAllowance;
    mapping(address => uint256) public ghostNonce;

    uint256 public ghostMinted;
    uint256 public unexpected; // count of calls whose outcome disagreed with the model
    string public lastUnexpected;

    // coverage counters, so a vacuous run is visible
    uint256 public okTransfers;
    uint256 public okTransferFroms;
    uint256 public okPermits;
    uint256 public rejected;

    constructor(SeerToken token_, address deployer) {
        token = token_;
        actors.push(deployer);
        keys.push(0); // the deployer is a contract: it cannot sign permits
        for (uint256 i = 1; i < N_ACTORS; ++i) {
            uint256 key = 0x5EE0 + i;
            keys.push(key);
            actors.push(vm.addr(key));
        }
        ghostBalance[deployer] = token_.totalSupply();
        ghostMinted = token_.totalSupply();
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _flag(string memory what) internal {
        unexpected++;
        lastUnexpected = what;
    }

    // ------------------------------------------------------------------ transfer

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 bal = ghostBalance[from];
        // Mostly in range, sometimes just over the balance, sometimes far over it.
        amount = bound(amount, 0, bal + bal / 4 + 2);

        vm.prank(from);
        try token.transfer(to, amount) returns (bool ok) {
            if (!ok) _flag("transfer returned false");
            if (amount > bal) _flag("transfer above balance succeeded");
            ghostBalance[from] -= amount;
            ghostBalance[to] += amount;
            okTransfers++;
        } catch (bytes memory err) {
            if (amount <= bal) _flag("valid transfer reverted");
            if (
                keccak256(err)
                    != keccak256(
                        abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, bal, amount)
                    )
            ) {
                _flag("transfer overdraft: wrong error");
            }
            rejected++;
        }
    }

    function transferToZero(uint256 fromSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        amount = bound(amount, 0, ghostBalance[from]);
        vm.prank(from);
        try token.transfer(address(0), amount) {
            _flag("transfer to zero succeeded");
        } catch (bytes memory err) {
            if (
                keccak256(err)
                    != keccak256(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)))
            ) {
                _flag("transfer to zero: wrong error");
            }
            rejected++;
        }
    }

    // ------------------------------------------------------------------ approve / transferFrom

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount, bool infinite) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        if (infinite) amount = type(uint256).max;
        vm.prank(owner);
        try token.approve(spender, amount) returns (bool ok) {
            if (!ok) _flag("approve returned false");
            ghostAllowance[owner][spender] = amount;
        } catch {
            _flag("approve reverted");
        }
    }

    function approveZeroSpender(uint256 ownerSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        vm.prank(owner);
        try token.approve(address(0), amount) {
            _flag("approve to zero spender succeeded");
        } catch (bytes memory err) {
            if (
                keccak256(err)
                    != keccak256(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)))
            ) {
                _flag("approve zero spender: wrong error");
            }
            rejected++;
        }
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 bal = ghostBalance[owner];
        uint256 allowed = ghostAllowance[owner][spender];
        uint256 cap = bal > allowed ? bal : allowed;
        amount = bound(amount, 0, cap == type(uint256).max ? cap : cap + 1);

        vm.prank(spender);
        try token.transferFrom(owner, to, amount) returns (bool ok) {
            if (!ok) _flag("transferFrom returned false");
            if (amount > allowed) _flag("transferFrom above allowance succeeded");
            if (amount > bal) _flag("transferFrom above balance succeeded");
            if (allowed != type(uint256).max) ghostAllowance[owner][spender] = allowed - amount;
            ghostBalance[owner] -= amount;
            ghostBalance[to] += amount;
            okTransferFroms++;
        } catch (bytes memory err) {
            // OZ checks the allowance first, then the balance.
            bytes memory expected;
            if (amount > allowed) {
                expected =
                    abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, amount);
            } else if (amount > bal) {
                expected = abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, bal, amount);
            } else {
                _flag("valid transferFrom reverted");
            }
            if (keccak256(err) != keccak256(expected)) _flag("transferFrom: wrong error");
            rejected++;
        }
    }

    // ------------------------------------------------------------------ permit

    function _digest(address owner, address spender, uint256 value, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                owner,
                spender,
                value,
                nonce,
                deadline
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
    }

    struct PermitCase {
        address owner;
        address spender;
        uint256 value;
        uint256 mode;
        uint256 nonce;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    /// @param mode 0 valid, 1 expired, 2 signed by the wrong key, 3 replay of an already-used nonce
    function permit(uint256 ownerSeed, uint256 spenderSeed, uint256 value, uint256 mode, uint256 relayerSeed) external {
        PermitCase memory c;
        uint256 idx = 1 + (ownerSeed % (actors.length - 1)); // a key-holding actor
        c.owner = actors[idx];
        c.spender = _actor(spenderSeed);
        c.value = value;
        c.mode = mode % 4;
        c.nonce = ghostNonce[c.owner];
        if (c.mode == 3 && c.nonce == 0) c.mode = 0;
        c.deadline = c.mode == 1 ? block.timestamp - 1 : block.timestamp + 1 days;
        (c.v, c.r, c.s) = vm.sign(
            c.mode == 2 ? 0xBAD : keys[idx],
            _digest(c.owner, c.spender, c.value, c.mode == 3 ? c.nonce - 1 : c.nonce, c.deadline)
        );
        vm.prank(_actor(relayerSeed)); // anyone may relay
        _submitPermit(c);
    }

    function _submitPermit(PermitCase memory c) internal {
        try token.permit(c.owner, c.spender, c.value, c.deadline, c.v, c.r, c.s) {
            if (c.mode != 0) _flag("invalid permit accepted");
            ghostAllowance[c.owner][c.spender] = c.value;
            ghostNonce[c.owner] = c.nonce + 1;
            okPermits++;
        } catch (bytes memory err) {
            if (c.mode == 0) _flag("valid permit rejected");
            if (c.mode == 1) {
                if (
                    keccak256(err)
                        != keccak256(abi.encodeWithSelector(ERC20Permit.ERC2612ExpiredSignature.selector, c.deadline))
                ) {
                    _flag("expired permit: wrong error");
                }
            } else if (bytes4(err) != ERC20Permit.ERC2612InvalidSigner.selector) {
                _flag("forged/replayed permit: wrong error");
            }
            rejected++;
        }
    }

    // ------------------------------------------------------------------ time

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 0, 30 days));
    }
}

contract SeerTokenGhostInvariantTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    SeerToken internal token;
    SeerGhostHandler internal handler;

    function setUp() public {
        vm.warp(1_700_000_000);
        token = new SeerToken();
        handler = new SeerGhostHandler(token, address(this));
        // The deployer (this contract) is the handler's first actor; the handler pranks as it.
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_noUnexpectedOutcome() public view {
        assertEq(handler.unexpected(), 0, handler.lastUnexpected());
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_supplyFixedAndFullyAccounted() public view {
        assertEq(token.totalSupply(), SUPPLY, "supply changed");
        assertEq(handler.ghostMinted(), SUPPLY);
        uint256 sum;
        for (uint256 i; i < handler.actorCount(); ++i) {
            sum += token.balanceOf(handler.actorAt(i));
        }
        assertEq(sum, SUPPLY, "balances do not sum to the supply");
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_stateMatchesGhostModel() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            address a = handler.actorAt(i);
            assertEq(token.balanceOf(a), handler.ghostBalance(a), "balance diverged from model");
            assertEq(token.nonces(a), handler.ghostNonce(a), "nonce diverged from model");
            for (uint256 j; j < n; ++j) {
                address b = handler.actorAt(j);
                assertEq(token.allowance(a, b), handler.ghostAllowance(a, b), "allowance diverged from model");
            }
        }
    }

    /// @dev Guards against a vacuous campaign: each run must have both moved tokens and been refused.
    function afterInvariant() public view {
        assertGt(handler.okTransfers() + handler.okTransferFroms(), 0, "no transfer ever succeeded");
        assertGt(handler.rejected(), 0, "no failure path was ever exercised");
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_metadataNeverChanges() public view {
        assertEq(token.name(), "SeerIMD");
        assertEq(token.symbol(), "SEER");
        assertEq(token.decimals(), 18);
    }
}
