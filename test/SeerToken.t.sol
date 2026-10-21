// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {SeerToken} from "../src/SeerToken.sol";
import {DeploySeerToken} from "../script/DeploySeerToken.s.sol";

/// @dev Stands in for the launch factory: deploys the creation code through CREATE2 and so is
/// `msg.sender` of the constructor. Lets the tests check that the supply lands on whoever deploys.
contract FactoryProbe {
    function deploy(bytes memory code, bytes32 salt) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
        require(deployed != address(0) && deployed.code.length > 0, "constructor failed");
    }
}

contract SeerTokenTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    SeerToken internal token;
    address internal deployer;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal stranger = makeAddr("stranger");

    uint256 internal signerKey = 0xA11CE;
    address internal signer;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        deployer = address(this);
        token = new SeerToken();
        signer = vm.addr(signerKey);
    }

    // ---------------------------------------------------------------------------------------------
    // Metadata and supply
    // ---------------------------------------------------------------------------------------------

    function test_metadata() public view {
        assertEq(token.name(), "SeerIMD");
        assertEq(token.symbol(), "SEER");
        assertEq(token.decimals(), 18);
        assertEq(token.TOKEN_NAME(), "SeerIMD");
        assertEq(token.TOKEN_SYMBOL(), "SEER");
        assertEq(token.DECIMALS(), 18);
    }

    function test_supplyConstantMatchesBrief() public view {
        // 1,000,000,000 tokens with 18 decimals.
        assertEq(token.TOTAL_SUPPLY(), 1_000_000_000 * 10 ** 18);
        assertEq(token.TOTAL_SUPPLY(), SUPPLY);
    }

    function test_constructorMintsWholeSupplyToDeployer() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(address(0)), 0);
    }

    function test_constructorEmitsSingleMintTransfer() public {
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(0), address(this), SUPPLY);
        new SeerToken();
    }

    /// @dev The launch factory deploys the creation code via CREATE2; it is `msg.sender` of the
    /// constructor and must end up holding every unit, with no constructor arguments involved.
    function test_supplyGoesToWhoeverDeploysTheCreationCode() public {
        FactoryProbe factory = new FactoryProbe();
        bytes memory code = type(SeerToken).creationCode;
        bytes32 salt = bytes32(uint256(42));
        address predicted = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(factory), salt, keccak256(code)))))
        );

        address deployed = factory.deploy(code, salt);

        assertEq(deployed, predicted, "CREATE2 prediction mismatch");
        SeerToken fromFactory = SeerToken(deployed);
        assertEq(fromFactory.totalSupply(), SUPPLY);
        assertEq(fromFactory.balanceOf(address(factory)), SUPPLY, "the factory does not hold the whole supply");
        assertEq(fromFactory.balanceOf(address(this)), 0, "the test contract got tokens it should not have");
    }

    function test_deployScriptFunctionMintsToCaller() public {
        DeploySeerToken script = new DeploySeerToken();
        SeerToken deployed = script.deploy();
        assertEq(deployed.totalSupply(), SUPPLY);
        assertEq(deployed.balanceOf(address(script)), SUPPLY, "the script contract is the deployer and must hold it");
        assertEq(deployed.name(), "SeerIMD");
        assertEq(deployed.symbol(), "SEER");
    }

    function test_deployScriptRunWorksUnderAnyBroadcaster() public {
        DeploySeerToken script = new DeploySeerToken();
        SeerToken deployed = script.run();
        assertEq(deployed.totalSupply(), SUPPLY);
        assertEq(deployed.name(), "SeerIMD");
    }

    // ---------------------------------------------------------------------------------------------
    // Transfers: success
    // ---------------------------------------------------------------------------------------------

    function test_transferMovesBalanceAndEmits() public {
        uint256 amount = 1_234 ether;
        vm.expectEmit(true, true, true, true);
        emit Transfer(deployer, alice, amount);
        assertTrue(token.transfer(alice, amount));
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(deployer), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferWholeBalanceLeavesZero() public {
        token.transfer(alice, SUPPLY);
        assertEq(token.balanceOf(deployer), 0);
        assertEq(token.balanceOf(alice), SUPPLY);
        vm.prank(alice);
        assertTrue(token.transfer(bob, SUPPLY));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), SUPPLY);
    }

    function test_transferZeroAmountSucceeds() public {
        assertTrue(token.transfer(alice, 0));
        assertEq(token.balanceOf(alice), 0);
        vm.prank(stranger);
        assertTrue(token.transfer(alice, 0));
    }

    function test_transferToSelfKeepsBalance() public {
        assertTrue(token.transfer(deployer, 5 ether));
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_noFeeOnTransferAtAnyAmount() public {
        uint256[4] memory amounts = [uint256(1), 1 ether, 123_456_789_123_456_789, SUPPLY / 10];
        for (uint256 i; i < amounts.length; ++i) {
            address to = address(uint160(0x1000 + i));
            token.transfer(to, amounts[i]);
            assertEq(token.balanceOf(to), amounts[i], "transfer arrived short");
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Transfers: failure
    // ---------------------------------------------------------------------------------------------

    function test_transferRevertsWhenBalanceInsufficient() public {
        token.transfer(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 10 ether, 11 ether)
        );
        token.transfer(bob, 11 ether);
        assertEq(token.balanceOf(alice), 10 ether);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferRevertsFromEmptyAccount() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, stranger, 0, 1));
        token.transfer(alice, 1);
    }

    function test_transferToZeroAddressReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    // ---------------------------------------------------------------------------------------------
    // Allowances: success
    // ---------------------------------------------------------------------------------------------

    function test_approveSetsAllowanceAndEmits() public {
        vm.expectEmit(true, true, true, true);
        emit Approval(deployer, alice, 7 ether);
        assertTrue(token.approve(alice, 7 ether));
        assertEq(token.allowance(deployer, alice), 7 ether);
        // approve overwrites rather than adds
        token.approve(alice, 3 ether);
        assertEq(token.allowance(deployer, alice), 3 ether);
    }

    function test_transferFromSpendsAllowance() public {
        token.approve(alice, 10 ether);
        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit Transfer(deployer, bob, 4 ether);
        assertTrue(token.transferFrom(deployer, bob, 4 ether));
        assertEq(token.balanceOf(bob), 4 ether);
        assertEq(token.balanceOf(deployer), SUPPLY - 4 ether);
        assertEq(token.allowance(deployer, alice), 6 ether);
    }

    function test_transferFromWithMaxAllowanceDoesNotDecrement() public {
        token.approve(alice, type(uint256).max);
        vm.prank(alice);
        token.transferFrom(deployer, bob, 4 ether);
        assertEq(token.allowance(deployer, alice), type(uint256).max);
    }

    function test_transferFromBySelfStillNeedsAllowance() public {
        // OpenZeppelin v5 semantics: no implicit self-allowance.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, 1 ether));
        token.transferFrom(deployer, alice, 1 ether);
    }

    // ---------------------------------------------------------------------------------------------
    // Allowances: failure
    // ---------------------------------------------------------------------------------------------

    function test_transferFromRevertsWithoutAllowance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1 ether));
        token.transferFrom(deployer, bob, 1 ether);
    }

    function test_transferFromRevertsAboveAllowance() public {
        token.approve(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 1 ether, 1 ether + 1)
        );
        token.transferFrom(deployer, bob, 1 ether + 1);
        assertEq(token.allowance(deployer, alice), 1 ether);
    }

    function test_transferFromRevertsWhenOwnerBalanceInsufficient() public {
        token.transfer(alice, 1 ether);
        vm.prank(alice);
        token.approve(bob, 5 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 1 ether, 2 ether));
        token.transferFrom(alice, stranger, 2 ether);
        assertEq(token.allowance(alice, bob), 5 ether, "a failed transferFrom must not spend allowance");
    }

    function test_approveZeroSpenderReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    // ---------------------------------------------------------------------------------------------
    // Permit (EIP-2612)
    // ---------------------------------------------------------------------------------------------

    function _permitDigest(address owner, address spender, uint256 value, uint256 nonce, uint256 deadline)
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

    function test_permitSetsAllowanceAndBumpsNonce() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _permitDigest(signer, alice, 9 ether, 0, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);

        vm.prank(stranger); // anyone may submit a permit
        token.permit(signer, alice, 9 ether, deadline, v, r, s);

        assertEq(token.allowance(signer, alice), 9 ether);
        assertEq(token.nonces(signer), 1);
    }

    function test_permitThenTransferFrom() public {
        token.transfer(signer, 20 ether);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, _permitDigest(signer, alice, 20 ether, 0, deadline));
        token.permit(signer, alice, 20 ether, deadline, v, r, s);
        vm.prank(alice);
        token.transferFrom(signer, bob, 20 ether);
        assertEq(token.balanceOf(bob), 20 ether);
        assertEq(token.balanceOf(signer), 0);
    }

    function test_permitRevertsWhenExpired() public {
        uint256 deadline = block.timestamp - 1;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, _permitDigest(signer, alice, 1 ether, 0, deadline));
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612ExpiredSignature.selector, deadline));
        token.permit(signer, alice, 1 ether, deadline, v, r, s);
        assertEq(token.allowance(signer, alice), 0);
    }

    function test_permitRevertsOnWrongSigner() public {
        uint256 deadline = block.timestamp + 1 hours;
        uint256 otherKey = 0xB0B;
        address other = vm.addr(otherKey);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(otherKey, _permitDigest(signer, alice, 1 ether, 0, deadline));
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612InvalidSigner.selector, other, signer));
        token.permit(signer, alice, 1 ether, deadline, v, r, s);
        assertEq(token.allowance(signer, alice), 0);
    }

    function test_permitCannotBeReplayed() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, _permitDigest(signer, alice, 1 ether, 0, deadline));
        token.permit(signer, alice, 1 ether, deadline, v, r, s);
        // Same signature again: the nonce moved on, so the recovered signer differs.
        vm.expectRevert();
        token.permit(signer, alice, 1 ether, deadline, v, r, s);
        assertEq(token.nonces(signer), 1);
    }

    function test_permitRevertsOnTamperedValue() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, _permitDigest(signer, alice, 1 ether, 0, deadline));
        vm.expectRevert();
        token.permit(signer, alice, 2 ether, deadline, v, r, s);
    }

    // ---------------------------------------------------------------------------------------------
    // No admin surface: nothing mints, nothing freezes, nothing moves a holder
    // ---------------------------------------------------------------------------------------------

    function test_noCallIncreasesSupply() public {
        address attacker = makeAddr("attacker");
        string[10] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], attacker, type(uint128).max);
            vm.prank(attacker);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            // from the deployer too, the most plausible trusted address
            (ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            assertEq(token.totalSupply(), SUPPLY, signatures[i]);
            assertEq(token.balanceOf(attacker), 0, signatures[i]);
        }
    }

    function test_noPrivilegedCallMovesOrFreezesAHolder() public {
        token.transfer(alice, SUPPLY / 1_000);
        uint256 held = token.balanceOf(alice);
        string[12] memory signatures = [
            "pause()",
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "burnFrom(address,uint256)",
            "seize(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], alice, true));
            assertFalse(ok, signatures[i]);
        }
        (bool moved,) = address(token).call(abi.encodeWithSelector(IERC20.transferFrom.selector, alice, deployer, 1));
        assertFalse(moved, "the deployer moved a holder's balance without allowance");
        assertEq(token.balanceOf(alice), held);
        vm.prank(alice);
        assertTrue(token.transfer(bob, held / 2));
        assertEq(token.balanceOf(bob), held / 2);
    }

    function test_noOwnerFunctions() public {
        (bool ok, bytes memory ret) = address(token).call(abi.encodeWithSignature("owner()"));
        assertFalse(ok, "owner() exists");
        assertEq(ret.length, 0);
        (ok,) = address(token).call(abi.encodeWithSignature("paused()"));
        assertFalse(ok, "paused() exists");
        (ok,) = address(token).call(abi.encodeWithSignature("burn(uint256)", 1));
        assertFalse(ok, "burn(uint256) exists");
    }

    function test_cannotSendEther() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(token).call{value: 1 wei}("");
        assertFalse(ok, "token accepted ether");
        assertEq(address(token).balance, 0);
    }

    /// @dev Mirrors the launch floor's scan: no reachable DELEGATECALL, CALLCODE or SELFDESTRUCT.
    function test_runtimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576, "runtime exceeds EIP-170");
        bool reachable = true;
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op == 0x5B) reachable = true;
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            if (reachable) {
                assertTrue(op != 0xF4, "DELEGATECALL");
                assertTrue(op != 0xF2, "CALLCODE");
                assertTrue(op != 0xFF, "SELFDESTRUCT");
            }
            if (op == 0x00 || op == 0x56 || op == 0xF3 || op == 0xFD || op == 0xFE || op == 0xFF) reachable = false;
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Fuzz
    // ---------------------------------------------------------------------------------------------

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != deployer);
        amount = bound(amount, 0, SUPPLY);
        assertTrue(token.transfer(to, amount));
        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(deployer), SUPPLY - amount);
        assertEq(token.balanceOf(to) + token.balanceOf(deployer), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferAboveBalanceReverts(address from, uint256 balance, uint256 amount) public {
        vm.assume(from != address(0) && from != deployer);
        balance = bound(balance, 0, SUPPLY);
        amount = bound(amount, balance + 1, type(uint256).max);
        token.transfer(from, balance);
        vm.prank(from);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, balance, amount));
        token.transfer(bob, amount);
        assertEq(token.balanceOf(from), balance);
    }

    function testFuzz_transferFromRespectsAllowance(uint256 allowance_, uint256 amount) public {
        allowance_ = bound(allowance_, 0, SUPPLY);
        amount = bound(amount, 0, SUPPLY);
        token.approve(alice, allowance_);
        vm.prank(alice);
        if (amount > allowance_) {
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, allowance_, amount)
            );
            token.transferFrom(deployer, bob, amount);
            assertEq(token.balanceOf(bob), 0);
        } else {
            assertTrue(token.transferFrom(deployer, bob, amount));
            assertEq(token.balanceOf(bob), amount);
            assertEq(token.allowance(deployer, alice), allowance_ - amount);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_permitFromAnyKey(uint256 key, address spender, uint256 value, uint256 deadline) public {
        // secp256k1 order bound; vm.sign refuses keys outside it
        key = bound(key, 1, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364140);
        vm.assume(spender != address(0));
        deadline = bound(deadline, block.timestamp, type(uint256).max);
        address owner = vm.addr(key);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, _permitDigest(owner, spender, value, 0, deadline));
        token.permit(owner, spender, value, deadline, v, r, s);
        assertEq(token.allowance(owner, spender), value);
        assertEq(token.nonces(owner), 1);
    }
}
