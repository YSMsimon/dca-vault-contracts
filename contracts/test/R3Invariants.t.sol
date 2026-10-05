// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {DcaVault} from "../src/DcaVault.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {ISwapAdapter} from "../src/interfaces/ISwapAdapter.sol";
import {ChainlinkOracle} from "../src/adapters/ChainlinkOracle.sol";
import {MockERC20, MockStock, MockYieldAdapter} from "../src/mocks/Mocks.sol";
import {FakeFeed} from "./utils/HostileVenues.sol";
import {InvStats} from "./utils/InvStats.sol";

/// @notice The round-3 re-test's MODEL-BASED stateful suite, kept as a
///         permanent net (plan item F6).
/// @dev    Every admin verb on the vault and the oracle is predicted by an
///         exact model — success or failure, and the state after — from
///         random callers, with warps aimed at eta-1 / eta / eta+7d /
///         eta+7d+1, interleaved with user money flows checked per call.
///         Changed from the re-test's copy only where round 3 changed the
///         rules: the setup window is open until `finishSetup` (F4: new
///         `finishSetup` and `pauseDeposits` verbs, deposits paused until
///         then, and the model tracks both flags), and an instant bounds
///         change drops any queued loosening (F2).

/// Venue priced off the oracle's CURRENT feed, with a settable premium.
contract R3Swap is ISwapAdapter {
    MockERC20 public usdc;
    ChainlinkOracle public cl;
    uint256 public premBps;

    constructor(MockERC20 u, ChainlinkOracle c) {
        usdc = u;
        cl = c;
    }

    function setPrem(uint256 b) external {
        premBps = b;
    }

    function poolPrice(address, address t) public view returns (uint256) {
        try cl.latestPrice(t) returns (uint256 p, uint256) {
            return p * (10_000 + premBps) / 10_000;
        } catch {
            return 0;
        }
    }

    function swapExactIn(address, address t, uint256 amountIn, uint256 minOut, address to)
        external
        returns (uint256 out)
    {
        usdc.transferFrom(msg.sender, address(this), amountIn);
        out = amountIn * 1e10 / poolPrice(address(0), t);
        require(out >= minOut, "SLIPPAGE");
        MockStock(t).mint(to, out);
    }
}

/// Model-based handler: every admin verb on the vault AND the oracle is
/// predicted by an exact model (success/failure and resulting state), from
/// random callers, with warps aimed at eta-1 / eta / eta+7d / eta+7d+1.
/// Interleaved with user money flows whose accounting is checked per call.
contract R3Handler is Test {
    struct R {
        address token;
        address pool;
        address feed;
        bool enabled;
    }

    struct PR {
        address token;
        address pool;
        address feed;
        bool enabled;
        uint64 eta;
    }

    struct PF {
        address feed;
        uint64 eta;
    }

    MockERC20 public usdc;
    MockStock[3] public tok; // A, B, C
    FakeFeed[5] public feeds; // fA1 fA2 fB1 fB2 fC
    ChainlinkOracle public cl;
    MockYieldAdapter public y;
    R3Swap public sw;
    R3Swap public sw2; // a second "pool" address
    DcaVault public v;

    address[4] public actors;
    address[4] public users;
    address public keeper = address(0x4EE9);

    // ---- model
    address mAdmin;
    address mPending;
    address oAdmin;
    address oPending;
    uint16 mSlip = 100;
    uint16 mDev = 500;
    uint16 pbS;
    uint16 pbD;
    uint64 pbEta;
    mapping(uint32 => R) mR;
    mapping(uint32 => PR) mP;
    mapping(address => address) mFeed;
    mapping(address => PF) mPF;
    bool mSetup = true; // setup window open (F4)
    bool mPaused = true; // deposits paused, from the constructor (F4)
    bool mPausedInSetup; // a pause set during setup survives finishSetup (round 4)
    uint32[3] public ids = [uint32(1), 2, 7];

    // ---- plans
    uint256[] public planIds;
    mapping(uint256 => address) public ownerOf;
    uint256 public donated;

    // ---- counters
    uint256 public vModel;
    uint256 public vMoney;
    uint256 public vPanic;
    string public why;
    mapping(bytes32 => uint256) public calls;
    bytes32[] public callNames;
    uint256 public nOk;
    uint256 public nRevert;
    uint256 public nExecOk;
    uint256 public nExitOk;
    uint256 public nCreateOk;
    uint256 public nCreateDisabled;
    uint256 public nCreateCap;
    uint256 public nCreateOther;
    uint256 public nExecRevert;
    uint256 public nExecTries; // execute calls on an active plan, past setup
    uint256 public nCalm; // F6: executeCalm calls that reached an active plan
    uint256 public nCalmOk;
    bytes public lastExecErr;
    uint256 public nShortfall;
    uint256 public nEdgeWarps;
    uint256 public nActivations;
    uint256 public nExpiredRefusals;

    constructor() {
        vm.warp(1_780_000_000);
        usdc = new MockERC20("USDC", "USDC", 6);
        for (uint256 i; i < 3; ++i) {
            tok[i] = new MockStock("T", "T");
        }
        int256[5] memory px = [int256(100e8), 103e8, 50e8, 49e8, 200e8];
        for (uint256 i; i < 5; ++i) {
            feeds[i] = new FakeFeed();
            feeds[i].set(px[i], block.timestamp, true);
        }
        cl = new ChainlinkOracle(address(0), false);
        cl.setFeed(address(tok[0]), address(feeds[0]));
        cl.setFeed(address(tok[1]), address(feeds[2]));
        mFeed[address(tok[0])] = address(feeds[0]);
        mFeed[address(tok[1])] = address(feeds[2]);
        y = new MockYieldAdapter(usdc);
        sw = new R3Swap(usdc, cl);
        sw2 = new R3Swap(usdc, cl);
        v = new DcaVault(IERC20(address(usdc)), y, sw, cl, 50_000_000e6);
        y.bindVault(address(v));
        v.initRoute(1, DcaVault.Route(address(tok[0]), address(sw), address(feeds[0]), 0, true));
        v.initRoute(2, DcaVault.Route(address(tok[1]), address(sw), address(feeds[2]), 0, true));
        mR[1] = R(address(tok[0]), address(sw), address(feeds[0]), true);
        mR[2] = R(address(tok[1]), address(sw), address(feeds[2]), true);
        v.setKeeper(keeper, true);
        mAdmin = address(this);
        oAdmin = address(this);
        actors = [address(this), address(0xAD1), address(0xAD2), address(0xBAD)];
        users = [address(0x1001), address(0x1002), address(0x1003), address(0x1004)];
        for (uint256 i; i < 4; ++i) {
            vm.prank(users[i]);
            usdc.approve(address(v), type(uint256).max);
        }
    }

    function _count(string memory n) internal {
        bytes32 k = keccak256(bytes(n));
        if (calls[k] == 0) callNames.push(k);
        calls[k]++;
    }

    function _viol(string memory w) internal {
        vModel++;
        if (bytes(why).length == 0) why = w;
    }

    function _mviol(string memory w) internal {
        vMoney++;
        if (bytes(why).length == 0) why = w;
    }

    function _isPanic(bytes memory e) internal pure returns (bool) {
        return e.length >= 4 && bytes4(e) == bytes4(0x4e487b71);
    }

    function _note(bool ok, bytes memory e) internal {
        if (ok) nOk++;
        else nRevert++;
        if (_isPanic(e)) vPanic++;
        if (
            e.length >= 4
                && (bytes4(e) == DcaVault.QueueExpired.selector
                    || bytes4(e) == ChainlinkOracle.QueueExpired.selector)
        ) nExpiredRefusals++;
    }

    // ------------------------------------------------------------ model helpers
    function _actor(uint256 s) internal view returns (address) {
        // bias to the real admins
        uint256 k = s % 8;
        if (k < 3) return mAdmin;
        if (k < 5) return oAdmin;
        return actors[k % 4];
    }

    function _variant(uint256 s) internal view returns (R memory r) {
        r.token = address(tok[s % 3]);
        r.pool = (s >> 2) % 5 == 0 ? address(sw2) : address(sw);
        r.feed = address(feeds[(s >> 4) % 5]);
        if ((s >> 8) % 3 != 0) r.feed = mFeed[r.token] == address(0) ? r.feed : mFeed[r.token];
        r.enabled = (s >> 10) % 4 != 0;
    }

    function _routeOk(uint32 id, R memory r) internal view returns (bool) {
        R memory cur = mR[id];
        if (cur.token != address(0) && (cur.token != r.token || cur.pool != r.pool)) return false;
        if (r.feed == address(0) || mFeed[r.token] != r.feed) return false;
        return true;
    }

    function _inWindow(uint64 eta) internal view returns (bool) {
        return eta != 0 && block.timestamp >= eta && block.timestamp <= uint256(eta) + 7 days;
    }

    function _vr(uint32 id) internal view returns (R memory r) {
        (r.token, r.pool, r.feed,, r.enabled) = v.routes(id);
    }

    function _vp(uint32 id) internal view returns (PR memory p) {
        (p.token, p.pool, p.feed,, p.enabled, p.eta) = v.pendingRoutes(id);
    }

    function _compare(string memory where) internal {
        if (v.admin() != mAdmin) _viol(string.concat(where, ": admin"));
        if (v.pendingAdmin() != mPending) _viol(string.concat(where, ": pendingAdmin"));
        if (cl.admin() != oAdmin) _viol(string.concat(where, ": oracle admin"));
        if (cl.pendingAdmin() != oPending) _viol(string.concat(where, ": oracle pendingAdmin"));
        if (v.maxSlippageBps() != mSlip || v.maxDeviationBps() != mDev) {
            _viol(string.concat(where, ": bounds"));
        }
        (uint16 s, uint16 d, uint64 e) = v.pendingBounds();
        if (e != pbEta || (e != 0 && (s != pbS || d != pbD))) {
            _viol(string.concat(where, ": pendingBounds"));
        }
        for (uint256 i; i < 3; ++i) {
            uint32 id = ids[i];
            R memory a = _vr(id);
            R memory b = mR[id];
            if (
                a.token != b.token || a.pool != b.pool || a.feed != b.feed || a.enabled != b.enabled
            ) {
                _viol(string.concat(where, ": route"));
            }
            PR memory pa = _vp(id);
            PR memory pb = mP[id];
            if (
                pa.eta != pb.eta
                    || (pb.eta != 0
                        && (pa.token != pb.token
                            || pa.pool != pb.pool
                            || pa.feed != pb.feed
                            || pa.enabled != pb.enabled))
            ) {
                _viol(string.concat(where, ": pendingRoute"));
            }
        }
        for (uint256 i; i < 3; ++i) {
            address t = address(tok[i]);
            if (cl.feedOf(t) != mFeed[t]) _viol(string.concat(where, ": feedOf"));
            (address f, uint64 fe) = cl.pendingFeedOf(t);
            if (fe != mPF[t].eta || (fe != 0 && f != mPF[t].feed)) {
                _viol(string.concat(where, ": pendingFeed"));
            }
        }
        if (v.setupFinished() == mSetup) _viol(string.concat(where, ": setup flag"));
        if (v.depositsPaused() != mPaused) _viol(string.concat(where, ": paused flag"));
        if (mSetup && v.nextPlanId() != 1) {
            _viol(string.concat(where, ": a plan exists during setup"));
        }
    }

    function _expect(bool expectOk, bool ok, string memory where) internal {
        if (expectOk != ok) {
            _viol(
                string.concat(
                    where, ok ? ": succeeded, model says revert" : ": reverted, model says ok"
                )
            );
        }
    }

    // ------------------------------------------------------------ vault admin verbs
    function queueRoute(uint256 who, uint8 idS, uint256 varS) public {
        _count("queueRoute");
        address a = _actor(who);
        uint32 id = ids[idS % 3];
        R memory r = _variant(varS);
        bool exp = a == mAdmin && _routeOk(id, r);
        vm.prank(a);
        (bool ok, bytes memory e) = address(v)
            .call(
                abi.encodeCall(
                    DcaVault.queueRoute, (id, DcaVault.Route(r.token, r.pool, r.feed, 0, r.enabled))
                )
            );
        _note(ok, e);
        _expect(exp, ok, "queueRoute");
        if (ok) {
            mP[id] = PR(r.token, r.pool, r.feed, r.enabled, uint64(block.timestamp + 48 hours));
        }
        _compare("queueRoute");
    }

    function activateRoute(uint256 who, uint8 idS) public {
        _count("activateRoute");
        address a = _actor(who);
        uint32 id = ids[idS % 3];
        PR memory p = mP[id];
        bool exp =
            a == mAdmin && _inWindow(p.eta) && _routeOk(id, R(p.token, p.pool, p.feed, p.enabled));
        vm.prank(a);
        (bool ok, bytes memory e) = address(v).call(abi.encodeCall(DcaVault.activateRoute, (id)));
        _note(ok, e);
        _expect(exp, ok, "activateRoute");
        if (ok) {
            nActivations++;
            mR[id] = R(p.token, p.pool, p.feed, p.enabled);
            delete mP[id];
        }
        _compare("activateRoute");
    }

    function cancelRoute(uint256 who, uint8 idS) public {
        _count("cancelRoute");
        address a = _actor(who);
        uint32 id = ids[idS % 3];
        bool exp = a == mAdmin && mP[id].eta != 0;
        vm.prank(a);
        (bool ok, bytes memory e) = address(v).call(abi.encodeCall(DcaVault.cancelRoute, (id)));
        _note(ok, e);
        _expect(exp, ok, "cancelRoute");
        if (ok) delete mP[id];
        _compare("cancelRoute");
    }

    function disableRoute(uint256 who, uint8 idS) public {
        _count("disableRoute");
        if (idS % 4 != 0) return;
        address a = _actor(who);
        uint32 id = ids[(idS / 4) % 3];
        bool exp = a == mAdmin;
        vm.prank(a);
        (bool ok, bytes memory e) = address(v).call(abi.encodeCall(DcaVault.disableRoute, (id)));
        _note(ok, e);
        _expect(exp, ok, "disableRoute");
        if (ok) {
            mR[id].enabled = false;
            delete mP[id];
        }
        _compare("disableRoute");
    }

    /// The honest path back: re-queue the route as it is, enabled, with the
    /// oracle's current feed; wait 48h; activate. Model-checked at each step.
    function restore(uint8 idS, uint256 extra) public {
        _count("restore");
        uint32 id = ids[idS % 3];
        R memory r = mR[id];
        if (r.token == address(0)) {
            r = R(address(tok[2]), address(sw), address(0), true);
        }
        r.enabled = true;
        r.feed = mFeed[r.token];
        bool exp = _routeOk(id, r);
        vm.prank(mAdmin);
        (bool ok, bytes memory e) = address(v)
            .call(
                abi.encodeCall(
                    DcaVault.queueRoute, (id, DcaVault.Route(r.token, r.pool, r.feed, 0, true))
                )
            );
        _note(ok, e);
        _expect(exp, ok, "restore.queue");
        if (!ok) return;
        mP[id] = PR(r.token, r.pool, r.feed, true, uint64(block.timestamp + 48 hours));
        vm.warp(block.timestamp + 48 hours + extra % (8 days));
        PR memory p = mP[id];
        exp = _inWindow(p.eta) && _routeOk(id, R(p.token, p.pool, p.feed, p.enabled));
        vm.prank(mAdmin);
        (ok, e) = address(v).call(abi.encodeCall(DcaVault.activateRoute, (id)));
        _note(ok, e);
        _expect(exp, ok, "restore.activate");
        if (ok) {
            nActivations++;
            mR[id] = R(p.token, p.pool, p.feed, true);
            delete mP[id];
        }
        _compare("restore");
    }

    function initRoute(uint256 who, uint8 idS, uint256 varS) public {
        _count("initRoute");
        address a = _actor(who);
        uint32 id = ids[idS % 3];
        R memory r = _variant(varS);
        bool exp = a == mAdmin && mSetup && _routeOk(id, r);
        vm.prank(a);
        (bool ok, bytes memory e) = address(v)
            .call(
                abi.encodeCall(
                    DcaVault.initRoute, (id, DcaVault.Route(r.token, r.pool, r.feed, 0, r.enabled))
                )
            );
        _note(ok, e);
        _expect(exp, ok, "initRoute");
        if (ok) mR[id] = r;
        _compare("initRoute");
    }

    function setBounds(uint256 who, uint16 s, uint16 d) public {
        _count("setBounds");
        address a = _actor(who);
        s = uint16(uint256(s) % 230);
        d = uint16(uint256(d) % 2100);
        bool exp = a == mAdmin && s <= 200 && d <= 2000;
        vm.prank(a);
        (bool ok, bytes memory e) = address(v).call(abi.encodeCall(DcaVault.setBounds, (s, d)));
        _note(ok, e);
        _expect(exp, ok, "setBounds");
        if (ok) {
            if (mSetup || (s <= mSlip && d <= mDev)) {
                mSlip = s;
                mDev = d;
                pbEta = 0; // F2: an instant change drops a queued loosening
            } else {
                pbS = s;
                pbD = d;
                pbEta = uint64(block.timestamp + 48 hours);
            }
        }
        _compare("setBounds");
    }

    function activateBounds(uint256 who) public {
        _count("activateBounds");
        address a = _actor(who);
        bool exp = a == mAdmin && _inWindow(pbEta);
        vm.prank(a);
        (bool ok, bytes memory e) = address(v).call(abi.encodeCall(DcaVault.activateBounds, ()));
        _note(ok, e);
        _expect(exp, ok, "activateBounds");
        if (ok) {
            nActivations++;
            mSlip = pbS;
            mDev = pbD;
            pbEta = 0;
        }
        _compare("activateBounds");
    }

    function cancelBounds(uint256 who) public {
        _count("cancelBounds");
        address a = _actor(who);
        bool exp = a == mAdmin && pbEta != 0;
        vm.prank(a);
        (bool ok, bytes memory e) = address(v).call(abi.encodeCall(DcaVault.cancelBounds, ()));
        _note(ok, e);
        _expect(exp, ok, "cancelBounds");
        if (ok) pbEta = 0;
        _compare("cancelBounds");
    }

    function transferVaultAdmin(uint256 who, uint8 to) public {
        _count("transferVaultAdmin");
        address a = _actor(who);
        address t = to % 5 == 4 ? address(0) : actors[to % 4];
        bool exp = a == mAdmin;
        vm.prank(a);
        (bool ok, bytes memory e) = address(v).call(abi.encodeCall(DcaVault.transferAdmin, (t)));
        _note(ok, e);
        _expect(exp, ok, "transferAdmin");
        if (ok) mPending = t;
        _compare("transferAdmin");
    }

    function acceptVaultAdmin(uint8 who) public {
        _count("acceptVaultAdmin");
        address a = who % 3 == 0 ? mPending : actors[who % 4];
        bool exp = a == mPending && a != address(0);
        vm.prank(a);
        (bool ok, bytes memory e) = address(v).call(abi.encodeCall(DcaVault.acceptAdmin, ()));
        _note(ok, e);
        _expect(exp, ok, "acceptAdmin");
        if (ok) {
            mAdmin = a;
            mPending = address(0);
        }
        _compare("acceptAdmin");
    }

    /// F4: closes the setup window and opens deposits, once.
    function finishSetup(uint256 who) public {
        _count("finishSetup");
        address a = _actor(who);
        bool exp = a == mAdmin && mSetup;
        vm.prank(a);
        (bool ok, bytes memory e) = address(v).call(abi.encodeCall(DcaVault.finishSetup, ()));
        _note(ok, e);
        _expect(exp, ok, "finishSetup");
        if (ok) {
            mSetup = false;
            mPaused = mPausedInSetup;
        }
        _compare("finishSetup");
    }

    /// F4: pausing is always allowed; unpausing only after finishSetup.
    function pauseDeposits(uint256 who, bool p) public {
        _count("pauseDeposits");
        address a = _actor(who);
        bool exp = a == mAdmin && (p || !mSetup);
        vm.prank(a);
        (bool ok, bytes memory e) = address(v).call(abi.encodeCall(DcaVault.setDepositsPaused, (p)));
        _note(ok, e);
        _expect(exp, ok, "setDepositsPaused");
        if (ok) {
            if (mSetup) mPausedInSetup = true;
            mPaused = p;
        }
        _compare("setDepositsPaused");
    }

    function setMisc(uint256 who, uint16 fee, bool k, uint256 cap) public {
        _count("setMisc");
        address a = _actor(who);
        vm.startPrank(a);
        (bool ok1,) = address(v).call(abi.encodeCall(DcaVault.setFee, (uint16(fee % 1100))));
        (bool ok2,) = address(v).call(abi.encodeCall(DcaVault.setKeeper, (keeper, k)));
        (bool ok3,) = address(v)
            .call(
                abi.encodeCall(
                    DcaVault.setTvlCap,
                    (cap % 8 == 0 ? cap % 5_000_000e6 : bound(cap, 20_000_000e6, 60_000_000e6))
                )
            );
        vm.stopPrank();
        if (a != mAdmin && (ok1 || ok2 || ok3)) _viol("misc by non-admin");
        _compare("setMisc");
    }

    // ------------------------------------------------------------ oracle verbs
    function oSetFeed(uint256 who, uint8 t, uint8 f) public {
        _count("oSetFeed");
        address a = _actor(who);
        address tk = address(tok[t % 3]);
        address fd = address(feeds[f % 5]);
        bool exp = a == oAdmin && mFeed[tk] == address(0);
        vm.prank(a);
        (bool ok, bytes memory e) =
            address(cl).call(abi.encodeCall(ChainlinkOracle.setFeed, (tk, fd)));
        _note(ok, e);
        _expect(exp, ok, "setFeed");
        if (ok) mFeed[tk] = fd;
        _compare("setFeed");
    }

    function oQueueFeed(uint256 who, uint8 t, uint8 f) public {
        _count("oQueueFeed");
        address a = _actor(who);
        address tk = address(tok[t % 3]);
        address fd = address(feeds[f % 5]);
        bool exp = a == oAdmin && mFeed[tk] != address(0);
        vm.prank(a);
        (bool ok, bytes memory e) =
            address(cl).call(abi.encodeCall(ChainlinkOracle.queueFeed, (tk, fd)));
        _note(ok, e);
        _expect(exp, ok, "queueFeed");
        if (ok) mPF[tk] = PF(fd, uint64(block.timestamp + 48 hours));
        _compare("queueFeed");
    }

    function oActivateFeed(uint256 who, uint8 t) public {
        _count("oActivateFeed");
        address a = _actor(who);
        address tk = address(tok[t % 3]);
        bool exp = a == oAdmin && _inWindow(mPF[tk].eta);
        vm.prank(a);
        (bool ok, bytes memory e) =
            address(cl).call(abi.encodeCall(ChainlinkOracle.activateFeed, (tk)));
        _note(ok, e);
        _expect(exp, ok, "activateFeed");
        if (ok) {
            nActivations++;
            mFeed[tk] = mPF[tk].feed;
            delete mPF[tk];
        }
        _compare("activateFeed");
    }

    function oCancelFeed(uint256 who, uint8 t) public {
        _count("oCancelFeed");
        address a = _actor(who);
        address tk = address(tok[t % 3]);
        bool exp = a == oAdmin && mPF[tk].eta != 0;
        vm.prank(a);
        (bool ok, bytes memory e) =
            address(cl).call(abi.encodeCall(ChainlinkOracle.cancelFeed, (tk)));
        _note(ok, e);
        _expect(exp, ok, "cancelFeed");
        if (ok) delete mPF[tk];
        _compare("cancelFeed");
    }

    function oTransfer(uint256 who, uint8 to, bool accept) public {
        _count("oTransfer");
        if (!accept) {
            address a = _actor(who);
            address t = to % 5 == 4 ? address(0) : actors[to % 4];
            vm.prank(a);
            (bool ok, bytes memory e) =
                address(cl).call(abi.encodeCall(ChainlinkOracle.transferAdmin, (t)));
            _note(ok, e);
            _expect(a == oAdmin, ok, "oTransferAdmin");
            if (ok) oPending = t;
        } else {
            address a = to % 3 == 0 ? oPending : actors[to % 4];
            vm.prank(a);
            (bool ok, bytes memory e) =
                address(cl).call(abi.encodeCall(ChainlinkOracle.acceptAdmin, ()));
            _note(ok, e);
            _expect(a == oPending && a != address(0), ok, "oAcceptAdmin");
            if (ok) {
                oAdmin = a;
                oPending = address(0);
            }
        }
        _compare("oTransfer");
    }

    // ------------------------------------------------------------ time
    function warpEdge(uint8 which, uint8 edge) public {
        _count("warpEdge");
        uint64 eta;
        uint256 w = which % 7;
        if (w < 3) eta = mP[ids[w]].eta;
        else if (w == 3) eta = pbEta;
        else eta = mPF[address(tok[w - 4])].eta;
        if (eta == 0) return;
        uint256[4] memory t =
            [uint256(eta) - 1, eta, uint256(eta) + 7 days, uint256(eta) + 7 days + 1];
        uint256 target = t[edge % 4];
        if (target <= block.timestamp) return;
        nEdgeWarps++;
        vm.warp(target);
    }

    function warp(uint256 dt) public {
        _count("warp");
        vm.warp(block.timestamp + bound(dt, 1, 20 days));
    }

    // ------------------------------------------------------------ money
    struct Snap {
        uint256 rem;
        uint256 sh;
        uint64 ne;
        bool active;
    }

    function _plan(uint256 id) internal view returns (Snap memory s, uint256 inst, uint32 rid) {
        (, rid, inst, s.rem, s.sh, s.ne,,, s.active) = v.plans(id);
    }

    function _snapAll() internal view returns (Snap[] memory a) {
        a = new Snap[](planIds.length);
        for (uint256 i; i < planIds.length; ++i) {
            (a[i],,) = _plan(planIds[i]);
        }
    }

    function _others(Snap[] memory b, uint256 skip, string memory w) internal {
        for (uint256 i; i < planIds.length && i < b.length; ++i) {
            if (planIds[i] == skip) continue;
            (Snap memory s,,) = _plan(planIds[i]);
            if (s.rem != b[i].rem || s.sh != b[i].sh || s.ne != b[i].ne || s.active != b[i].active)
            {
                _mviol(string.concat(w, ": touched another plan"));
            }
        }
    }

    /// Most creates close the setup window first (as the real admin,
    /// model-checked) so runs spend their depth past setup; one in four tries
    /// while it is still open, which the model says must fail `Paused`.
    bool internal _expPaused;

    function _preCreate(uint256 u) internal returns (bool expectPaused) {
        if (mSetup && u % 4 != 0) {
            vm.prank(mAdmin);
            (bool okF, bytes memory eF) = address(v).call(abi.encodeCall(DcaVault.finishSetup, ()));
            _note(okF, eF);
            _expect(true, okF, "create.finishSetup");
            if (okF) (mSetup, mPaused) = (false, mPausedInSetup);
        }
        if (mPaused && u % 8 == 5) {
            vm.prank(mAdmin);
            (bool okU,) = address(v).call(abi.encodeCall(DcaVault.setDepositsPaused, (false)));
            if (okU != !mSetup) _viol("create.unpause");
            if (okU) mPaused = false;
        }
        return mPaused;
    }

    function create(uint256 u, uint8 rS, uint256 dep, uint256 n, uint256 iv) public {
        _count("create");
        _expPaused = _preCreate(u); // storage, not a local: create is at the stack limit
        address o = users[u % 4];
        uint32 rid = ids[rS % 3];
        if (!mR[rid].enabled && rS % 5 != 0) {
            for (uint256 i; i < 3; ++i) {
                if (mR[ids[i]].enabled) rid = ids[i];
            }
        }
        dep = bound(dep, 1e6, 2_000_000e6);
        n = bound(n, 1, 36);
        uint256 inst = (dep + n - 1) / n;
        if (inst < 1e6) inst = dep;
        usdc.mint(o, dep);
        uint256 tp0 = v.totalPrincipal();
        uint256 cap = v.tvlCap();
        uint256 sw0 = usdc.balanceOf(address(sw)) + usdc.balanceOf(address(sw2));
        uint16 s0 = mSlip;
        Snap[] memory b = _snapAll();
        _syncStock(o);
        vm.prank(o);
        (bool ok, bytes memory e) = address(v)
            .call(
                abi.encodeCall(
                    DcaVault.createPlan, (rid, dep, inst, uint64(bound(iv, 1 days, 40 days)))
                )
            );
        _note(ok, e);
        if (!ok) {
            if (e.length >= 4 && bytes4(e) == DcaVault.RouteDisabled.selector) nCreateDisabled++;
            else if (e.length >= 4 && bytes4(e) == DcaVault.CapExceeded.selector) nCreateCap++;
            else nCreateOther++;
        }
        if (!ok && _expPaused && (e.length < 4 || bytes4(e) != DcaVault.Paused.selector)) {
            _viol("create while paused: not Paused()");
        }
        if (ok) {
            nCreateOk++;
            if (_expPaused) _viol("create succeeded while deposits were paused");
            if (!mR[rid].enabled) _mviol("create on a route the model says is disabled");
            if (tp0 + dep > cap) _mviol("cap exceeded");
            uint256 id = abi.decode(e, (uint256));
            planIds.push(id);
            ownerOf[id] = o;
            _others(b, id, "create");
            uint256 spent = usdc.balanceOf(address(sw)) + usdc.balanceOf(address(sw2)) - sw0;
            if (spent > 0) _checkFill(rid, o, spent, s0);
        }
        _compare("create");
    }

    uint256 stock0;

    function _checkFill(uint32 rid, address o, uint256 spend, uint16 slip) internal {
        // model's live feed, model's bound
        address t = mR[rid].token;
        (, int256 ans,,,) = FakeFeed(mFeed[t]).latestRoundData();
        uint256 minOut = spend * 1e10 * (10_000 - slip) / (uint256(ans) * 10_000);
        uint256 got = MockStock(t).balanceOf(o) - _stockBefore[o][t];
        if (got < minOut) _mviol("fill below the MODEL bound");
        _stockBefore[o][t] = MockStock(t).balanceOf(o);
    }

    mapping(address => mapping(address => uint256)) _stockBefore;

    function _syncStock(address o) internal {
        for (uint256 i; i < 3; ++i) {
            _stockBefore[o][address(tok[i])] = tok[i].balanceOf(o);
        }
    }

    struct Pre {
        uint256 id;
        uint256 inst;
        uint32 rid;
        address o;
        address c;
        uint256 val;
        uint256 yb0;
        uint256 sw0;
        uint256 f0;
        uint256 tp0;
        uint16 fee;
        uint16 s0;
        uint16 d0;
        bool k;
    }

    function _pickActive(uint256 seed) internal view returns (uint256) {
        uint256 n = planIds.length;
        if (seed % 10 == 0) return planIds[seed % n];
        for (uint256 i; i < n; ++i) {
            uint256 id = planIds[(seed % n + i) % n];
            (,,,,,,,, bool act) = v.plans(id);
            if (act) return id;
        }
        return planIds[seed % n];
    }

    function execute(uint256 seed, uint8 who) public {
        _count("execute");
        if (planIds.length == 0) return;
        _executeId(_pickActive(seed), who);
    }

    /// F6. Every hostile switch here (premium, stale feed, liquidity cap,
    /// disabled route) persists until something resets it, so whole runs
    /// went by with no successful execute. This resets the world first — the
    /// plan's route re-enabled through the model-checked 48h `restore`, the
    /// venue honest, every feed fresh at its current answer, lending
    /// uncapped — then executes, due, as the owner. In that world a due
    /// execute has no business reverting, and `afterInvariant` says so.
    function executeCalm(uint256 seed) public {
        _count("executeCalm");
        uint256 n = planIds.length;
        if (n == 0) return;
        uint256 id;
        bool found;
        for (uint256 j; j < n && !found; ++j) {
            id = planIds[(seed % n + j) % n];
            (,,,,,,,, found) = v.plans(id);
        }
        if (!found) return;
        (, uint32 rid,,,,,,,) = v.plans(id);
        if (!mR[rid].enabled) {
            restore(rid == 1 ? 0 : rid == 2 ? 1 : 2, 0);
            if (!mR[rid].enabled) return;
        }
        sw.setPrem(0);
        sw2.setPrem(0);
        for (uint256 i; i < 5; ++i) {
            (, int256 a,,,) = feeds[i].latestRoundData();
            feeds[i].set(a, block.timestamp, true);
        }
        y.setLiquidityCap(type(uint256).max);
        nCalm++;
        uint256 ok0 = nExecOk;
        _executeId(id, 9); // 9: owner (9 % 3 == 0), warp to due (9 & 8), no +1s
        if (nExecOk > ok0) nCalmOk++;
    }

    function _executeId(uint256 id, uint8 who) internal {
        Pre memory x;
        x.id = id;
        Snap memory p;
        (p, x.inst, x.rid) = _plan(x.id);
        x.o = ownerOf[x.id];
        x.c = who % 3 == 0 ? x.o : who % 3 == 1 ? keeper : address(0xBAD);
        if ((who & 8) != 0 && p.active) {
            uint256 due =
                uint256(p.ne) + (x.c == address(0xBAD) ? 12 hours : 0) + (who & 16 != 0 ? 1 : 0);
            if (due > block.timestamp) vm.warp(due);
        }
        _syncStock(x.o);
        x.val = y.assetsOf(p.sh);
        x.yb0 = usdc.balanceOf(address(y));
        x.sw0 = usdc.balanceOf(address(sw)) + usdc.balanceOf(address(sw2));
        x.f0 = v.feesAccrued();
        x.tp0 = v.totalPrincipal();
        x.fee = v.feeBps();
        x.s0 = mSlip;
        x.d0 = mDev;
        x.k = v.keepers(keeper);
        Snap[] memory b = _snapAll();
        if (p.active) nExecTries++;
        vm.prank(x.c);
        (bool ok, bytes memory e) = address(v).call(abi.encodeCall(DcaVault.executeDCA, (x.id)));
        _note(ok, e);
        if (!ok) {
            nExecRevert++;
            lastExecErr = e;
            _compare("execute(revert)");
            return;
        }
        nExecOk++;
        _postExec(x, p, b);
        _compare("execute");
    }

    function _postExec(Pre memory x, Snap memory p, Snap[] memory b) internal {
        if (block.timestamp < p.ne) _mviol("executed early");
        if (x.c == address(0xBAD) && block.timestamp < uint256(p.ne) + 12 hours) {
            _mviol("stranger inside grace");
        }
        if (x.c == keeper && !x.k && block.timestamp < uint256(p.ne) + 12 hours) {
            _mviol("revoked keeper inside grace");
        }
        if (!mR[x.rid].enabled) _mviol("executed on a disabled route (model)");
        (Snap memory q,,) = _plan(x.id);
        uint256 principalOut = p.rem - q.rem;
        uint256 got = x.yb0 - usdc.balanceOf(address(y));
        uint256 spend = usdc.balanceOf(address(sw)) + usdc.balanceOf(address(sw2)) - x.sw0;
        uint256 feeTaken = v.feesAccrued() - x.f0;
        if (spend + feeTaken != got) _mviol("got != spend + fee");
        if (x.tp0 - v.totalPrincipal() != principalOut) _mviol("totalPrincipal delta");
        uint256 acc = got > principalOut ? got - principalOut : 0;
        if (feeTaken != acc * x.fee / 10_000) _mviol("fee not exactly on accrued");
        uint256 sf = principalOut > got ? principalOut - got : 0;
        uint256 lossRoom = p.rem > x.val ? p.rem - x.val : 0;
        if (sf > lossRoom + 2) _mviol("shortfall beyond the plan's own loss");
        if (sf > 0) nShortfall++;
        if (q.rem != 0 && principalOut != (x.inst < p.rem ? x.inst : p.rem)) {
            _mviol("principalOut is not a slice");
        }
        if (q.rem == 0 && q.active) _mviol("done but active");
        if (q.ne <= block.timestamp) _mviol("nextExecution not in future");
        _others(b, x.id, "execute");
        if (spend > 0) {
            _checkFill(x.rid, x.o, spend, x.s0);
            address t = mR[x.rid].token;
            (, int256 ans,,,) = FakeFeed(mFeed[t]).latestRoundData();
            uint256 pp = uint256(ans) * (10_000 + sw.premBps()) / 10_000;
            if ((pp - uint256(ans)) * 10_000 / uint256(ans) > x.d0) {
                _mviol("deviation above MODEL bound");
            }
        }
    }

    function create2(uint256 u, uint8 rS, uint256 dep, uint256 n, uint256 iv) public {
        create(u, rS, dep, n, iv);
    }

    function execute2(uint256 seed, uint8 who) public {
        execute(seed, who | 8);
    }

    function execute3(uint256 seed, uint8 who) public {
        execute(seed, who | 8);
    }

    function exit(uint256 seed) public {
        _count("exit");
        if (planIds.length == 0) return;
        uint256 id = _pickActive(seed);
        (Snap memory p,,) = _plan(id);
        address o = ownerOf[id];
        uint256 val = y.assetsOf(p.sh);
        uint256 u0 = usdc.balanceOf(o);
        uint256 f0 = v.feesAccrued();
        uint16 fee = v.feeBps();
        bool liquid = y.availableLiquidity() >= val;
        Snap[] memory b = _snapAll();
        vm.prank(o);
        (bool ok, bytes memory e) = address(v).call(abi.encodeCall(DcaVault.exitPlan, (id)));
        _note(ok, e);
        if (!ok) {
            if (p.active && liquid) _mviol("exit reverted while liquid");
            return;
        }
        nExitOk++;
        uint256 feeExp = val > p.rem ? (val - p.rem) * fee / 10_000 : 0;
        if (usdc.balanceOf(o) - u0 != val - feeExp) _mviol("exit not exact");
        if (v.feesAccrued() - f0 != feeExp) _mviol("exit fee");
        _others(b, id, "exit");
    }

    function accrue(uint256 bps) public {
        _count("accrue");
        y.accrueTo(y.sharePriceWad() * (10_000 + bound(bps, 0, 300)) / 10_000);
    }

    function loss(uint256 bps) public {
        _count("loss");
        y.setSharePrice(y.sharePriceWad() * (10_000 - bound(bps, 1, 2000)) / 10_000);
        uint256 owed = y.assetsOf(y.totalShares());
        uint256 have = usdc.balanceOf(address(y));
        if (have > owed) {
            vm.prank(address(y));
            usdc.transfer(address(0xdead), have - owed);
        }
    }

    function market(uint256 prem, uint8 staleSel, bool fresh) public {
        _count("market");
        uint256 lim = mSlip < mDev ? mSlip : mDev;
        sw.setPrem(prem % 4 == 0 ? bound(prem, 0, 260) : bound(prem, 0, lim));
        sw2.setPrem(sw.premBps());
        FakeFeed f = feeds[staleSel % 5];
        (, int256 a,,,) = f.latestRoundData();
        bool stale = !fresh && staleSel % 3 == 0;
        f.set(a, stale ? block.timestamp - 25 hours : block.timestamp, !stale);
    }

    function liquidity(uint256 c) public {
        _count("liquidity");
        y.setLiquidityCap(c % 3 == 0 ? type(uint256).max : bound(c, 0, 5_000_000e6));
    }

    function claimAndDonate(uint256 amt) public {
        _count("claimAndDonate");
        amt = bound(amt, 0, 1_000e6);
        usdc.mint(address(v), amt);
        donated += amt;
        uint256 fa = v.feesAccrued();
        address r = v.feeRecipient();
        uint256 r0 = usdc.balanceOf(r);
        v.claimFees();
        if (usdc.balanceOf(r) - r0 != fa || v.feesAccrued() != 0) _mviol("claimFees");
        donated += 0;
    }

    // ------------------------------------------------------------ views for invariants
    function planCount() external view returns (uint256) {
        return planIds.length;
    }

    function nNames() external view returns (uint256) {
        return callNames.length;
    }
}

contract R3InvariantsTest is Test {
    R3Handler h;

    function setUp() public {
        h = new R3Handler();
        targetContract(address(h));
        bytes4[] memory s = new bytes4[](34);
        s[30] = R3Handler.finishSetup.selector;
        s[31] = R3Handler.pauseDeposits.selector;
        s[32] = R3Handler.executeCalm.selector; // F6
        s[33] = R3Handler.executeCalm.selector;
        s[27] = R3Handler.create2.selector;
        s[28] = R3Handler.execute2.selector;
        s[29] = R3Handler.execute3.selector;
        s[26] = R3Handler.restore.selector;
        s[0] = R3Handler.queueRoute.selector;
        s[1] = R3Handler.activateRoute.selector;
        s[2] = R3Handler.cancelRoute.selector;
        s[3] = R3Handler.disableRoute.selector;
        s[4] = R3Handler.initRoute.selector;
        s[5] = R3Handler.setBounds.selector;
        s[6] = R3Handler.activateBounds.selector;
        s[7] = R3Handler.cancelBounds.selector;
        s[8] = R3Handler.transferVaultAdmin.selector;
        s[9] = R3Handler.acceptVaultAdmin.selector;
        s[10] = R3Handler.setMisc.selector;
        s[11] = R3Handler.oSetFeed.selector;
        s[12] = R3Handler.oQueueFeed.selector;
        s[13] = R3Handler.oActivateFeed.selector;
        s[14] = R3Handler.oCancelFeed.selector;
        s[15] = R3Handler.oTransfer.selector;
        s[16] = R3Handler.warpEdge.selector;
        s[17] = R3Handler.warp.selector;
        s[18] = R3Handler.create.selector;
        s[19] = R3Handler.execute.selector;
        s[20] = R3Handler.exit.selector;
        s[21] = R3Handler.accrue.selector;
        s[22] = R3Handler.loss.selector;
        s[23] = R3Handler.market.selector;
        s[24] = R3Handler.liquidity.selector;
        s[25] = R3Handler.claimAndDonate.selector;
        targetSelector(FuzzSelector({addr: address(h), selectors: s}));
    }

    function invariant_modelExact() public view {
        assertEq(h.vModel(), 0, h.why());
    }

    function invariant_money() public view {
        assertEq(h.vMoney(), 0, h.why());
        assertEq(h.vPanic(), 0, "panic");
    }

    function invariant_ledger() public view {
        DcaVault v = h.v();
        MockYieldAdapter y = h.y();
        uint256 sh;
        uint256 rem;
        uint256 val;
        for (uint256 i; i < h.planCount(); ++i) {
            (,,, uint256 r, uint256 s,,,,) = v.plans(h.planIds(i));
            sh += s;
            rem += r;
            val += y.assetsOf(s);
        }
        assertEq(sh, v.totalManagedShares(), "shares sum");
        assertEq(y.totalShares(), v.totalManagedShares(), "adapter shares");
        assertEq(rem, v.totalPrincipal(), "principal sum");
        assertLe(val, h.usdc().balanceOf(address(y)), "adapter insolvent vs plans");
        assertEq(
            h.usdc().balanceOf(address(v)),
            v.feesAccrued() + h.donated(),
            "vault USDC != fees + donations"
        );
    }

    function afterInvariant() public {
        string memory l1 = string.concat(
            vm.toString(h.nOk()),
            " ",
            vm.toString(h.nRevert()),
            " c ",
            vm.toString(h.nCreateOk()),
            " ",
            vm.toString(h.nCreateDisabled()),
            " ",
            vm.toString(h.nCreateCap()),
            " ",
            vm.toString(h.nCreateOther())
        );
        string memory l2 = string.concat(
            " x ",
            vm.toString(h.nExecOk()),
            " ",
            vm.toString(h.nExecRevert()),
            " e ",
            vm.toString(h.nExitOk()),
            " a ",
            vm.toString(h.nActivations()),
            " q ",
            vm.toString(h.nExpiredRefusals())
        );
        string memory l3 =
            string.concat(" w ", vm.toString(h.nEdgeWarps()), " s ", vm.toString(h.nShortfall()));
        InvStats.record(
            "R3Invariants",
            string.concat(
                vm.toString(h.nExecOk()),
                " ",
                vm.toString(h.nCalm()),
                " ",
                vm.toString(h.nCalmOk()),
                " ",
                l1,
                l2,
                l3
            )
        );
        console.log("ok/revert", h.nOk(), h.nRevert());
        console.log("create/exec/exit ok", h.nCreateOk(), h.nExecOk(), h.nExitOk());
        console.log(
            "activations / expired refusals / edge warps",
            h.nActivations(),
            h.nExpiredRefusals(),
            h.nEdgeWarps()
        );
        console.log("shortfalls", h.nShortfall());
        // F6: every calm execute lands, so a run executes at least as many
        // plans as it made calm attempts on.
        assertEq(
            h.nCalmOk(),
            h.nCalm(),
            string.concat("F6: a calm execute reverted: ", vm.toString(h.lastExecErr()))
        );
        assertGe(h.nExecOk(), h.nCalm(), "F6: fewer successful executes than calm attempts");
    }
}

contract R3HandlerSmoke is Test {
    function test_smoke() public {
        R3Handler h = new R3Handler();
        h.finishSetup(0);
        h.create(0, 0, 1000e6, 4, 7 days);
        console.log("plans", h.planCount(), h.vMoney(), h.vModel());
        console.log(h.why());
        h.warp(8 days);
        h.execute(0, 0);
        console.log("exec", h.nExecOk(), h.vMoney());
        console.log(h.why());
        assertEq(h.planCount(), 1);
        assertEq(h.nExecOk(), 1);
        assertEq(h.vMoney() + h.vModel() + h.vPanic(), 0, h.why());
    }
}
