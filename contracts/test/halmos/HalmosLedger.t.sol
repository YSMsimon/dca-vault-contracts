// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface Vm {
    function prank(address) external;
    function assume(bool) external;
}
import {DcaVault} from "../../src/DcaVault.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";
import {
    MockERC20,
    MockStock,
    MockYieldAdapter,
    MockPriceOracle,
    MockSwapAdapter
} from "../../src/mocks/Mocks.sol";

/// @notice Halmos symbolic checks from the 2026-09-28 hard test.
/// @dev    NOT run by `forge test`: the functions are `check_*`, which forge
///         ignores, so plain `forge test` stays green and fast. Run them with
///
///             bash scripts/halmos.sh          (or: pnpm halmos)
///
///         which builds into a separate out dir with dynamic test linking OFF.
///         Foundry 1.8's dynamic linking rewrites `new X()` in test files into
///         `vm.deployCode`, a cheatcode Halmos 0.3.3 does not implement, so
///         the harness fails in setUp against the default build.
///
///         Against the unfixed code (an earlier revision), P4 produced
///         counterexamples (d = 0x40000000 at share prices just above par): a
///         one-shot plan Panicked at create. P1-P3 are proved by the default
///         run. Every form of P4 is `prove_` and opt-in: on the unfixed code
///         the solver found a counterexample (SAT) in
///         ~4 minutes, but proving the fixed code has NONE (UNSAT) goes
///         through 256-bit divisions and did not finish — the joint P4 ran 19
///         minutes and the single-symbol halves 13 minutes with no solver
///         timeout. C4 is instead proved by testFuzz_C4_OneShotPlanNeverReverts
///         and Echidna's createOneShot, and pinned by test_C4_* directly.
contract HalmosLedger {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    MockERC20 usdc;
    MockStock stock;
    MockYieldAdapter yield_;
    MockPriceOracle oracle;
    MockSwapAdapter swapper;
    DcaVault vault;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    uint256 constant CAP = 5_000e6;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        stock = new MockStock("Mock NVDAc", "NVDAc");
        yield_ = new MockYieldAdapter(usdc);
        oracle = new MockPriceOracle();
        swapper = new MockSwapAdapter(usdc, stock, oracle);
        oracle.setPrice(address(stock), 227_56000000);
        vault = new DcaVault(IERC20(address(usdc)), yield_, swapper, oracle, CAP);
        yield_.bindVault(address(vault));
        vault.initRoute(1, DcaVault.Route(address(stock), address(0xDEAD), address(oracle), 0, true));
        vault.finishSetup();
        usdc.mint(alice, 10_000e6);
        usdc.mint(bob, 10_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(vault), type(uint256).max);
    }

    function _create(address who, uint256 d, uint256 i) internal returns (bool ok, uint256 id) {
        vm.prank(who);
        bytes memory ret;
        (ok, ret) = address(vault).call(
            abi.encodeCall(DcaVault.createPlan, (uint32(1), d, i, uint64(30 days)))
        );
        if (ok) id = abi.decode(ret, (uint256));
    }

    function _shares(uint256 id) internal view returns (uint256 s) {
        (,,,, s,,,,) = vault.plans(id);
    }

    /// P1: outstanding principal never exceeds the cap after any two creates.
    function check_capHolds(uint256 d1, uint256 i1, uint256 d2, uint256 i2) public {
        vm.assume(d1 <= 10_000e6 && d2 <= 10_000e6);
        _create(alice, d1, i1);
        _create(bob, d2, i2);
        assert(vault.totalPrincipal() <= CAP);
    }

    /// P2: ledger conservation. After two creates, a solvent accrual and one
    ///     exit, the vault's total ledger equals the adapter's real share count
    ///     and equals the survivor's shares.
    function check_ledgerConservation(uint256 d1, uint256 d2, uint256 px) public {
        vm.assume(d1 >= 2e6 && d1 <= 2_000e6 && d2 >= 2e6 && d2 <= 2_000e6);
        vm.assume(px >= 1e18 && px <= 1.2e18);
        (bool okA, uint256 a) = _create(alice, d1, d1 / 2);
        (bool okB, uint256 b) = _create(bob, d2, d2 / 2);
        vm.assume(okA && okB);
        yield_.accrueTo(px);
        vm.prank(alice);
        vault.exitPlan(a);
        assert(vault.totalManagedShares() == yield_.totalShares());
        assert(vault.totalManagedShares() == _shares(b));
    }

    /// P3: an active plan can always be exited when the adapter is liquid,
    ///     at any share price, including a loss.
    function check_exitAlwaysWorks(uint256 d, uint256 i, uint256 px) public {
        vm.assume(d >= 1 && d <= 4_000e6 && i >= 1 && i < d);
        vm.assume(px >= 0.5e18 && px <= 1.5e18);
        (bool ok, uint256 id) = _create(alice, d, i);
        vm.assume(ok);
        yield_.accrueTo(px); // mints real assets if price rose
        yield_.setSharePrice(px); // and allows a loss
        vm.prank(alice);
        (bool exited,) = address(vault).call(abi.encodeCall(DcaVault.exitPlan, (id)));
        assert(exited);
    }

    /// P4: a single-installment plan (installment == deposit) can be created at
    ///     any solvent, non-par share price. (C4: failed on the unfixed code.)
    /// @dev  Named `prove_`, so the default run skips it. On the unfixed code the solver
    ///       found counterexamples in ~4 minutes. After the fix, proving there
    ///       are NONE is nonlinear in two symbols (shares × price) and did not
    ///       finish in 19 minutes with no solver timeout, and neither did the
    ///       single-symbol halves below (13 minutes). The fuzz test
    ///       testFuzz_C4_OneShotPlanNeverReverts covers the full domain
    ///       concretely. Run it anyway with:
    ///         bash scripts/halmos.sh --match-test '^prove_' --solver-timeout-assertion 0
    function prove_singleInstallmentCreates(uint256 d, uint256 px) public {
        vm.assume(d >= 1e6 && d <= 2_000e6);
        vm.assume(px > 1e18 && px <= 1.1e18);
        _create(bob, 1_000e6, 100e6); // pooled shares exist
        yield_.accrueTo(px);
        (bool ok,) = _create(alice, d, d);
        assert(ok);
    }

    /// P4a: P4 with the price pinned to the unfixed code's counterexamples and the size
    ///      fully symbolic. Opt-in (see the contract note).
    function prove_singleInstallmentCreatesAtCounterexamplePrices(uint256 d) public {
        vm.assume(d >= 1e6 && d <= 2_000e6);
        _create(bob, 1_000e6, 100e6);
        yield_.accrueTo(0xe00000000000000); // ~1.0088e18
        (bool ok,) = _create(alice, d, d);
        assert(ok);
    }

    function prove_singleInstallmentCreatesAtNearPar(uint256 d) public {
        vm.assume(d >= 1e6 && d <= 2_000e6);
        _create(bob, 1_000e6, 100e6);
        yield_.accrueTo(0xde0b6b3e77b2dff);
        (bool ok,) = _create(alice, d, d);
        assert(ok);
    }

    /// P4b: P4 with the size pinned to the counterexample and the share price
    ///      fully symbolic over (1.0, 1.1]. Opt-in.
    function prove_singleInstallmentCreatesAtCounterexampleSize(uint256 px) public {
        vm.assume(px > 1e18 && px <= 1.1e18);
        _create(bob, 1_000e6, 100e6);
        yield_.accrueTo(px);
        (bool ok,) = _create(alice, 0x40000000, 0x40000000);
        assert(ok);
    }
}
