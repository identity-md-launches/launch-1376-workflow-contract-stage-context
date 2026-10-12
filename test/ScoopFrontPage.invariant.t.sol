// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {ScoopFrontPage} from "../src/ScoopFrontPage.sol";

/// @dev Drives ScoopFrontPage with random, bounded calls from several actors, the owner and strangers,
///      across time. Every call is wrapped in try/catch: the handler works out beforehand whether the
///      call must succeed or revert (and with which error), and asserts that outcome. So the suite
///      runs with fail-on-revert and still exercises every failure path inside random sequences.
///
///      Ghost state records what the contract should hold and owe. The invariants below compare the
///      contract's balances and views against it after every call.
contract FrontPageHandler is Test {
    uint256 internal constant DAY = 1 days;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    ScoopFrontPage public immutable page;
    LaunchToken public immutable scoop;

    address public ghostOwner;
    address public ghostPendingOwner;
    uint256 public ghostPrice;

    address[] public actors;
    uint256 public immutable initialActorBalance;

    // ── Ghost accounting ────────────────────────────────────────────────────────
    /// @dev Sum of `paid` over slots that are booked and not burned: what the contract must hold.
    uint256 public ghostHeld;
    /// @dev Everything ever sent to the dEaD address by `burn`.
    uint256 public ghostBurned;
    /// @dev Everything ever refunded by `veto`.
    uint256 public ghostRefunded;
    mapping(address actor => uint256) public depositedBy;
    mapping(address actor => uint256) public refundedTo;

    /// @dev Every day that was ever booked (deduplicated), and what the contract should say about it.
    uint256[] public touchedDays;
    mapping(uint256 day => bool) private _touched;
    mapping(uint256 day => address) public ghostBuyerOf;
    mapping(uint256 day => uint256) public ghostPaidOf;
    mapping(uint256 day => bool) public ghostBurnedOf;
    /// @dev `currentDay()` at the moment the live booking for `day` was made.
    mapping(uint256 day => uint256) public ghostBookedOnDay;
    uint256 public minTouchedDay = type(uint256).max;
    uint256 public maxTouchedDay;

    // ── Call statistics (for `afterInvariant` logging) ──────────────────────────
    uint256 public bookOk;
    uint256 public bookReverted;
    uint256 public vetoOk;
    uint256 public vetoReverted;
    uint256 public burnOk;
    uint256 public burnReverted;
    uint256 public setPriceOk;
    uint256 public setPriceReverted;
    uint256 public handovers;
    uint256 public warps;

    constructor(ScoopFrontPage page_, LaunchToken scoop_, address owner_, address[] memory actors_, uint256 perActor) {
        page = page_;
        scoop = scoop_;
        ghostOwner = owner_;
        ghostPrice = page_.price();
        actors = actors_;
        initialActorBalance = perActor;
        for (uint256 i = 0; i < actors_.length; i++) {
            vm.prank(actors_[i]);
            scoop_.approve(address(page_), type(uint256).max);
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function touchedDayCount() external view returns (uint256) {
        return touchedDays.length;
    }

    // ── Actions ─────────────────────────────────────────────────────────────────

    /// @param dayOffset bounded to 0..33 so today (0) and 31..33 land outside the window.
    /// @param kind selects valid or deliberately invalid headline/link/token shapes.
    struct BookAttempt {
        address actor;
        uint256 today;
        uint256 day;
        address token;
        string headline;
        string link;
        bool headlineOk;
        bool linkOk;
        bool zeroToken;
        bool inWindow;
        bool free;
        bool funded;
        bool expectOk;
        uint256 priceNow;
        uint256 pageBefore;
        uint256 actorBefore;
    }

    function book(uint256 actorSeed, uint256 dayOffset, uint256 kind, uint256 textSeed) external {
        BookAttempt memory a;
        a.actor = actors[bound(actorSeed, 0, actors.length - 1)];
        a.today = block.timestamp / DAY;
        // Half the attempts target the next three days so vetoes and burns are reached within a run;
        // the rest spread over 0..33 so today and 31..33 (outside the window) are tried too.
        uint256 off = bound(dayOffset, 0, 99);
        a.day = off < 50 ? a.today + 1 + off % 3 : a.today + (off - 50) % 34;
        kind = bound(kind, 0, 11);

        (a.headline, a.headlineOk) = _headline(kind, textSeed);
        (a.link, a.linkOk) = _link(kind, textSeed);
        a.zeroToken = kind == 11;
        a.token = a.zeroToken ? address(0) : address(uint160(uint256(keccak256(abi.encode("imd coin", a.day)))));

        a.priceNow = page.price();
        a.inWindow = a.day >= a.today + 1 && a.day <= a.today + 30;
        a.free = page.slotOf(a.day).buyer == address(0);
        a.funded = scoop.balanceOf(a.actor) >= a.priceNow;
        a.expectOk = a.inWindow && a.free && !a.zeroToken && a.headlineOk && a.linkOk && a.funded;

        a.pageBefore = scoop.balanceOf(address(page));
        a.actorBefore = scoop.balanceOf(a.actor);

        vm.prank(a.actor);
        try page.book(a.day, a.token, a.headline, a.link) {
            _bookSucceeded(a);
        } catch (bytes memory reason) {
            _bookReverted(a, reason);
        }
    }

    function _bookSucceeded(BookAttempt memory a) private {
        assertTrue(a.expectOk, "book succeeded but a precondition should have failed it");
        bookOk++;

        assertEq(scoop.balanceOf(address(page)), a.pageBefore + a.priceNow, "book pulled a different amount");
        assertEq(scoop.balanceOf(a.actor), a.actorBefore - a.priceNow, "buyer paid a different amount");

        ghostHeld += a.priceNow;
        depositedBy[a.actor] += a.priceNow;
        ghostBuyerOf[a.day] = a.actor;
        ghostPaidOf[a.day] = a.priceNow;
        ghostBurnedOf[a.day] = false;
        ghostBookedOnDay[a.day] = a.today;
        _touch(a.day);
    }

    function _bookReverted(BookAttempt memory a, bytes memory reason) private {
        assertFalse(a.expectOk, "book reverted although every precondition held");
        bookReverted++;
        bytes4 sel = _selector(reason);
        if (!a.inWindow) assertEq(sel, ScoopFrontPage.DayOutOfWindow.selector, "wrong error: window");
        else if (!a.free) assertEq(sel, ScoopFrontPage.DayAlreadyBooked.selector, "wrong error: booked");
        else if (a.zeroToken) assertEq(sel, ScoopFrontPage.ZeroPromotedToken.selector, "wrong error: token");
        else if (!a.headlineOk) assertEq(sel, ScoopFrontPage.InvalidHeadline.selector, "wrong error: headline");
        else if (!a.linkOk) assertEq(sel, ScoopFrontPage.InvalidLink.selector, "wrong error: link");
        else assertEq(sel, IERC20Errors.ERC20InsufficientBalance.selector, "wrong error: balance");
        assertEq(scoop.balanceOf(address(page)), a.pageBefore, "a reverted book moved SCOOP");
    }

    function veto(uint256 daySeed, uint256 callerSeed) external {
        uint256 day = _pickDay(daySeed);
        (address caller, bool isOwner) = _pickCaller(callerSeed);

        ScoopFrontPage.Slot memory before = page.slotOf(day);
        bool booked = before.buyer != address(0);
        bool started = block.timestamp >= day * DAY;
        bool expectOk = isOwner && booked && !started;

        uint256 pageBefore = scoop.balanceOf(address(page));
        uint256 buyerBefore = booked ? scoop.balanceOf(before.buyer) : 0;

        vm.prank(caller);
        try page.veto(day) {
            assertTrue(expectOk, "veto succeeded but should have reverted");
            vetoOk++;

            assertEq(scoop.balanceOf(before.buyer), buyerBefore + before.paid, "refund is not what was paid");
            assertEq(scoop.balanceOf(address(page)), pageBefore - before.paid, "page released a different amount");
            assertEq(before.paid, ghostPaidOf[day], "contract refunded something other than the ghost record");

            ghostHeld -= before.paid;
            ghostRefunded += before.paid;
            refundedTo[before.buyer] += before.paid;
            delete ghostBuyerOf[day];
            delete ghostPaidOf[day];
            delete ghostBookedOnDay[day];
        } catch (bytes memory reason) {
            assertFalse(expectOk, "veto reverted although it should have succeeded");
            vetoReverted++;
            bytes4 sel = _selector(reason);
            if (!isOwner) assertEq(sel, Ownable.OwnableUnauthorizedAccount.selector, "wrong error: not owner");
            else if (!booked) assertEq(sel, ScoopFrontPage.DayNotBooked.selector, "wrong error: not booked");
            else assertEq(sel, ScoopFrontPage.DayAlreadyStarted.selector, "wrong error: started");
            assertEq(scoop.balanceOf(address(page)), pageBefore, "a reverted veto moved SCOOP");
        }
    }

    function burn(uint256 daySeed, uint256 callerSeed) external {
        uint256 day = _pickDay(daySeed);
        (address caller,) = _pickCaller(callerSeed);

        ScoopFrontPage.Slot memory before = page.slotOf(day);
        bool booked = before.buyer != address(0);
        bool ended = block.timestamp >= (day + 1) * DAY;
        bool expectOk = booked && ended && !before.burned;

        uint256 pageBefore = scoop.balanceOf(address(page));
        uint256 deadBefore = scoop.balanceOf(DEAD);

        vm.prank(caller);
        try page.burn(day) {
            assertTrue(expectOk, "burn succeeded but should have reverted");
            burnOk++;

            assertEq(scoop.balanceOf(DEAD), deadBefore + before.paid, "dEaD received something other than paid");
            assertEq(scoop.balanceOf(address(page)), pageBefore - before.paid, "page released a different amount");
            assertEq(before.paid, ghostPaidOf[day], "contract burned something other than the ghost record");

            ghostHeld -= before.paid;
            ghostBurned += before.paid;
            ghostBurnedOf[day] = true;
        } catch (bytes memory reason) {
            assertFalse(expectOk, "burn reverted although it should have succeeded");
            burnReverted++;
            bytes4 sel = _selector(reason);
            if (!booked) assertEq(sel, ScoopFrontPage.DayNotBooked.selector, "wrong error: not booked");
            else if (!ended) assertEq(sel, ScoopFrontPage.DayNotEnded.selector, "wrong error: not ended");
            else assertEq(sel, ScoopFrontPage.AlreadyBurned.selector, "wrong error: already burned");
            assertEq(scoop.balanceOf(address(page)), pageBefore, "a reverted burn moved SCOOP");
        }
    }

    function setPrice(uint256 newPrice, uint256 callerSeed) external {
        // Up to 3x the opening price so actors can run dry (an exercised failure path) but not
        // immediately. The last bucket is the full uint256 range, which no actor can pay.
        newPrice = bound(newPrice, 0, 3 * page.INITIAL_PRICE() + 1);
        if (newPrice == 3 * page.INITIAL_PRICE() + 1) newPrice = type(uint256).max;
        (address caller, bool isOwner) = _pickCaller(callerSeed);

        vm.prank(caller);
        try page.setPrice(newPrice) {
            assertTrue(isOwner, "a non-owner changed the price");
            setPriceOk++;
            ghostPrice = newPrice;
        } catch (bytes memory reason) {
            assertFalse(isOwner, "owner could not set the price");
            setPriceReverted++;
            assertEq(_selector(reason), Ownable.OwnableUnauthorizedAccount.selector, "wrong error: setPrice");
        }
    }

    /// @dev Two-step handover to an actor. A stranger's accept must fail; the nominee's must succeed.
    function handover(uint256 nomineeSeed, uint256 strangerSeed) external {
        address nominee = actors[bound(nomineeSeed, 0, actors.length - 1)];
        address stranger = actors[bound(strangerSeed, 0, actors.length - 1)];

        vm.prank(ghostOwner);
        page.transferOwnership(nominee);
        ghostPendingOwner = nominee;
        assertEq(page.owner(), ghostOwner, "ownership moved before acceptance");

        if (stranger != nominee) {
            vm.prank(stranger);
            try page.acceptOwnership() {
                assertTrue(false, "a stranger accepted ownership");
            } catch (bytes memory reason) {
                assertEq(_selector(reason), Ownable.OwnableUnauthorizedAccount.selector, "wrong error: accept");
            }
        }

        vm.prank(nominee);
        page.acceptOwnership();
        ghostOwner = nominee;
        ghostPendingOwner = address(0);
        handovers++;
    }

    /// @dev Advance time by up to three days so bookings cross "started" and "ended" boundaries.
    function warp(uint256 secs) external {
        secs = bound(secs, 0, 3 * DAY);
        vm.warp(block.timestamp + secs);
        warps++;
    }

    // ── Helpers ─────────────────────────────────────────────────────────────────

    function _touch(uint256 day) private {
        if (!_touched[day]) {
            _touched[day] = true;
            touchedDays.push(day);
        }
        if (day < minTouchedDay) minTouchedDay = day;
        if (day > maxTouchedDay) maxTouchedDay = day;
    }

    /// @dev Mostly a day that was booked at some point; sometimes a random day near today.
    function _pickDay(uint256 seed) private view returns (uint256) {
        if (touchedDays.length == 0 || seed % 4 == 0) {
            return block.timestamp / DAY + (seed >> 8) % 34;
        }
        return touchedDays[(seed >> 8) % touchedDays.length];
    }

    /// @dev The owner three times out of four; otherwise an actor (who may coincidentally be the owner
    ///      after a handover, which `isOwner` accounts for).
    function _pickCaller(uint256 seed) private view returns (address caller, bool isOwner) {
        if (seed % 4 != 0) return (ghostOwner, true);
        caller = actors[(seed >> 8) % actors.length];
        isOwner = caller == ghostOwner;
    }

    function _headline(uint256 kind, uint256 seed) private pure returns (string memory, bool) {
        if (kind == 6) return ("", false);
        if (kind == 7) return (_printable(seed, 81), false);
        if (kind == 8) {
            bytes memory b = bytes(_printable(seed, 40));
            b[seed % 40] = bytes1(uint8(seed % 2 == 0 ? 0x0A : 0x7F));
            return (string(b), false);
        }
        uint256 len = 1 + (seed % 80);
        return (_printable(seed, len), true);
    }

    function _link(uint256 kind, uint256 seed) private pure returns (string memory, bool) {
        if (kind == 9) return (string.concat("http://", _printable(seed, 20)), false);
        if (kind == 10) return (string.concat("https://", _printable(seed, 113)), false);
        if (kind % 3 == 0) return ("", true);
        uint256 tail = (seed >> 16) % 113; // 0..112 -> total 8..120 bytes
        return (string.concat("https://", _printable(seed >> 32, tail)), true);
    }

    /// @dev `len` bytes, each in 0x21..0x7E (so a slice never starts with a space the prefix check
    ///      could be confused by; spaces are covered by the stateless tests).
    function _printable(uint256 seed, uint256 len) private pure returns (string memory) {
        bytes memory b = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            b[i] = bytes1(uint8(0x21 + uint256(keccak256(abi.encode(seed, i))) % 94));
        }
        return string(b);
    }

    function _selector(bytes memory reason) private pure returns (bytes4 sel) {
        if (reason.length < 4) return bytes4(0);
        assembly ("memory-safe") {
            sel := mload(add(reason, 32))
        }
    }
}

/// forge-config: default.invariant.runs = 192
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract ScoopFrontPageInvariantTest is Test {
    uint256 internal constant DAY = 1 days;
    uint256 internal constant SUPPLY = 1_000_000_000e18;
    uint256 internal constant PRICE = 2_000_000e18;
    uint256 internal constant PER_ACTOR = 40 * PRICE;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    /// @dev Noon of a UTC day in October 2026.
    uint256 internal constant START = 20_740 * DAY + 12 hours;

    LaunchToken internal scoop;
    ScoopFrontPage internal page;
    FrontPageHandler internal handler;
    address internal initialOwner = makeAddr("owner");
    address[] internal actors;

    function setUp() public {
        vm.warp(START);
        scoop = new LaunchToken();
        page = new ScoopFrontPage(address(scoop), initialOwner);

        actors.push(makeAddr("sponsorA"));
        actors.push(makeAddr("sponsorB"));
        actors.push(makeAddr("sponsorC"));
        actors.push(makeAddr("sponsorD"));
        for (uint256 i = 0; i < actors.length; i++) {
            scoop.transfer(actors[i], PER_ACTOR);
        }

        handler = new FrontPageHandler(page, scoop, initialOwner, actors, PER_ACTOR);

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = FrontPageHandler.book.selector;
        selectors[1] = FrontPageHandler.veto.selector;
        selectors[2] = FrontPageHandler.burn.selector;
        selectors[3] = FrontPageHandler.setPrice.selector;
        selectors[4] = FrontPageHandler.handover.selector;
        selectors[5] = FrontPageHandler.warp.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    // ── Custody ─────────────────────────────────────────────────────────────────

    /// @dev What the contract holds equals the sum it owes to live, unburned bookings (ghost view).
    function invariant_heldEqualsLiveBookings() public view {
        assertEq(scoop.balanceOf(address(page)), handler.ghostHeld(), "held != sum of live bookings");
    }

    /// @dev Same property computed from the contract's own `slotOf`, independent of ghost counters:
    ///      the contract can always pay every refund or burn it still owes, and holds nothing more.
    function invariant_heldEqualsSumOfSlotsItReports() public view {
        uint256 owed;
        uint256 n = handler.touchedDayCount();
        for (uint256 i = 0; i < n; i++) {
            ScoopFrontPage.Slot memory s = page.slotOf(handler.touchedDays(i));
            if (s.buyer != address(0) && !s.burned) owed += s.paid;
        }
        assertEq(scoop.balanceOf(address(page)), owed, "held != what slotOf says is still owed");
    }

    /// @dev SCOOP only ever leaves the contract to the dEaD address (burn) or back to a buyer (veto).
    function invariant_deadHoldsExactlyWhatWasBurned() public view {
        assertEq(scoop.balanceOf(DEAD), handler.ghostBurned(), "dEaD balance != burned total");
    }

    /// @dev No sponsor ever ends up with more than they started with, and refunds never exceed deposits.
    function invariant_sponsorsNeverProfit() public view {
        for (uint256 i = 0; i < actors.length; i++) {
            address a = actors[i];
            uint256 dep = handler.depositedBy(a);
            uint256 ref = handler.refundedTo(a);
            assertLe(ref, dep, "refunded more than deposited");
            assertEq(scoop.balanceOf(a), PER_ACTOR - dep + ref, "sponsor balance drifted");
            assertLe(scoop.balanceOf(a), PER_ACTOR, "sponsor gained SCOOP");
        }
    }

    /// @dev Every token is somewhere we can name: sponsors, the contract, dEaD, or the untouched remainder.
    function invariant_supplyConserved() public view {
        uint256 sum = scoop.balanceOf(address(this)) + scoop.balanceOf(address(page)) + scoop.balanceOf(DEAD);
        for (uint256 i = 0; i < actors.length; i++) {
            sum += scoop.balanceOf(actors[i]);
        }
        assertEq(sum, SUPPLY, "SCOOP leaked to an unknown address");
        assertEq(scoop.totalSupply(), SUPPLY, "supply changed");
        assertEq(scoop.balanceOf(initialOwner), 0, "the owner received SCOOP");
        assertEq(handler.ghostHeld() + handler.ghostBurned() + handler.ghostRefunded(), _totalDeposited());
    }

    function invariant_holdsNoEth() public view {
        assertEq(address(page).balance, 0);
    }

    // ── Slot state machine ──────────────────────────────────────────────────────

    /// @dev Booked slots match the ghost record; vetoed days are empty; burned slots stay burned and
    ///      keep their record (a finished state never reopens).
    function invariant_slotsMatchGhost() public view {
        uint256 n = handler.touchedDayCount();
        for (uint256 i = 0; i < n; i++) {
            uint256 day = handler.touchedDays(i);
            ScoopFrontPage.Slot memory s = page.slotOf(day);
            assertEq(s.buyer, handler.ghostBuyerOf(day), "buyer differs from ghost");
            assertEq(s.paid, handler.ghostPaidOf(day), "paid differs from ghost");
            assertEq(s.burned, handler.ghostBurnedOf(day), "burned flag differs from ghost");
            if (s.buyer == address(0)) {
                assertEq(s.paid, 0, "freed slot kept a paid amount");
                assertFalse(s.burned, "freed slot is marked burned");
                assertEq(bytes(s.headline).length, 0, "freed slot kept a headline");
            } else {
                uint256 len = bytes(s.headline).length;
                assertTrue(len >= 1 && len <= 80, "stored headline out of bounds");
                assertLe(bytes(s.link).length, 120, "stored link too long");
                assertTrue(s.token != address(0), "stored zero promoted token");
            }
            if (s.burned) {
                assertTrue(block.timestamp >= (day + 1) * DAY, "burned before the day ended");
            }
        }
    }

    /// @dev Every live booking was made from tomorrow up to 30 days ahead of the booking time.
    function invariant_liveBookingsWereMadeInsideTheWindow() public view {
        uint256 n = handler.touchedDayCount();
        for (uint256 i = 0; i < n; i++) {
            uint256 day = handler.touchedDays(i);
            if (page.slotOf(day).buyer == address(0)) continue;
            uint256 bookedOn = handler.ghostBookedOnDay(day);
            assertTrue(day >= bookedOn + 1 && day <= bookedOn + 30, "booking outside the window");
        }
    }

    /// @dev The booked-day listing agrees with the slots, ascending, over the whole touched span.
    function invariant_bookedDaysListsExactlyTheBookedSlots() public view {
        if (handler.touchedDayCount() == 0) return;
        uint256 from = handler.minTouchedDay();
        uint256 to = handler.maxTouchedDay();
        if (to - from >= page.MAX_QUERY_RANGE()) to = from + page.MAX_QUERY_RANGE() - 1;

        uint256[] memory listed = page.bookedDays(from, to);
        uint256 expected;
        for (uint256 d = from; d <= to; d++) {
            if (page.slotOf(d).buyer != address(0)) expected++;
        }
        assertEq(listed.length, expected, "bookedDays count differs from slots");
        for (uint256 i = 0; i < listed.length; i++) {
            assertTrue(page.slotOf(listed[i]).buyer != address(0), "bookedDays listed a free day");
            assertTrue(listed[i] >= from && listed[i] <= to, "bookedDays listed a day outside the range");
            if (i > 0) assertGt(listed[i], listed[i - 1], "bookedDays not strictly ascending");
        }
    }

    // ── Owner surface ───────────────────────────────────────────────────────────

    function invariant_priceOnlyMovesByOwner() public view {
        assertEq(page.price(), handler.ghostPrice(), "price differs from what the owner set");
    }

    function invariant_ownershipOnlyMovesByTwoSteps() public view {
        assertEq(page.owner(), handler.ghostOwner(), "owner differs from ghost");
        assertEq(page.pendingOwner(), handler.ghostPendingOwner(), "pending owner differs from ghost");
        assertEq(address(page.scoop()), address(scoop), "token address changed");
    }

    function afterInvariant() public {
        // Surfaced with -vv so a run that never reached a path is visible rather than silently green.
        emit log_named_uint("book ok", handler.bookOk());
        emit log_named_uint("book reverted", handler.bookReverted());
        emit log_named_uint("veto ok", handler.vetoOk());
        emit log_named_uint("veto reverted", handler.vetoReverted());
        emit log_named_uint("burn ok", handler.burnOk());
        emit log_named_uint("burn reverted", handler.burnReverted());
        emit log_named_uint("setPrice ok", handler.setPriceOk());
        emit log_named_uint("setPrice reverted", handler.setPriceReverted());
        emit log_named_uint("handovers", handler.handovers());
        emit log_named_uint("warps", handler.warps());
    }

    function _totalDeposited() private view returns (uint256 sum) {
        for (uint256 i = 0; i < actors.length; i++) {
            sum += handler.depositedBy(actors[i]);
        }
    }
}
