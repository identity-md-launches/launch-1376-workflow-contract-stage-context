// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {ScoopFrontPage} from "../src/ScoopFrontPage.sol";

/// @dev Stateless property tests and pinned edge cases for ScoopFrontPage: the window at every offset
///      and second, every byte the validators must reject, exact-amount token pulls, refund-equals-paid
///      under price changes, timing boundaries of veto and burn, and what happens when the token
///      misbehaves. The invariant suite covers random sequences; this one covers the input space.
/// forge-config: default.fuzz.runs = 1000
contract ScoopFrontPageFuzzTest is Test {
    uint256 internal constant DAY = 1 days;
    uint256 internal constant PRICE = 2_000_000e18;
    uint256 internal constant SUPPLY = 1_000_000_000e18;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    /// @dev Noon of a UTC day in October 2026.
    uint256 internal constant START_DAY = 20_740;
    uint256 internal constant START = START_DAY * DAY + 12 hours;

    LaunchToken internal scoop;
    ScoopFrontPage internal page;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal promoted = makeAddr("promotedToken");

    function setUp() public {
        vm.warp(START);
        scoop = new LaunchToken();
        page = new ScoopFrontPage(address(scoop), owner);

        scoop.transfer(alice, 100 * PRICE);
        scoop.transfer(bob, 100 * PRICE);
        vm.prank(alice);
        scoop.approve(address(page), type(uint256).max);
        vm.prank(bob);
        scoop.approve(address(page), type(uint256).max);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────────────

    function _tomorrow() internal view returns (uint256) {
        return block.timestamp / DAY + 1;
    }

    function _book(address buyer, uint256 day) internal {
        vm.prank(buyer);
        page.book(day, promoted, "Headline", "https://example.com");
    }

    /// @dev `len` bytes in 0x20..0x7E derived from `seed`.
    function _printable(uint256 seed, uint256 len) internal pure returns (bytes memory b) {
        b = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            b[i] = bytes1(uint8(0x20 + uint256(keccak256(abi.encode(seed, i))) % 95));
        }
    }

    /// @dev A byte outside 0x20..0x7E: 0x00..0x1F or 0x7F..0xFF.
    function _nonPrintable(uint8 seed) internal pure returns (bytes1) {
        uint256 v = uint256(seed) % (0x20 + 0x81); // 0..0xA0
        return v < 0x20 ? bytes1(uint8(v)) : bytes1(uint8(0x7F + (v - 0x20)));
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Booking window: every offset, every second of the day
    // ─────────────────────────────────────────────────────────────────────────────

    /// @dev `book(today + offset)` succeeds exactly when 1 <= offset <= 30, whatever the time of day.
    function testFuzz_window_exactAtEveryOffsetAndSecond(uint256 offset, uint256 secondOfDay, uint256 dayIndex) public {
        offset = bound(offset, 0, 60);
        secondOfDay = bound(secondOfDay, 0, DAY - 1);
        dayIndex = bound(dayIndex, 1, 1e9); // from 1970 to far past year 2,000,000
        vm.warp(dayIndex * DAY + secondOfDay);

        uint256 today = page.currentDay();
        assertEq(today, dayIndex);
        (uint256 first, uint256 last) = page.bookingWindow();
        assertEq(first, today + 1);
        assertEq(last, today + 30);

        uint256 day = today + offset;
        bool inWindow = offset >= 1 && offset <= 30;

        vm.prank(alice);
        if (!inWindow) {
            vm.expectRevert(abi.encodeWithSelector(ScoopFrontPage.DayOutOfWindow.selector, day, first, last));
        }
        page.book(day, promoted, "H", "");

        if (inWindow) {
            assertEq(page.slotOf(day).buyer, alice);
            assertEq(scoop.balanceOf(address(page)), PRICE);
        } else {
            assertEq(page.slotOf(day).buyer, address(0));
            assertEq(scoop.balanceOf(address(page)), 0);
        }
    }

    /// @dev Booking in the past, even one day back, is always refused regardless of how far time went.
    function testFuzz_window_pastDaysAlwaysRefused(uint256 back, uint256 dayIndex) public {
        dayIndex = bound(dayIndex, 1, 1e9);
        back = bound(back, 0, dayIndex);
        vm.warp(dayIndex * DAY);
        uint256 day = dayIndex - back;
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ScoopFrontPage.DayOutOfWindow.selector, day, dayIndex + 1, dayIndex + 30)
        );
        page.book(day, promoted, "H", "");
    }

    /// @dev The whole lifecycle works at any point in time, including far-future timestamps.
    function testFuzz_lifecycle_atAnyTimestamp(uint256 ts, uint256 offset) public {
        ts = bound(ts, 1, 1e12); // up to year ~33,000
        offset = bound(offset, 1, 30);
        vm.warp(ts);
        uint256 day = page.currentDay() + offset;

        _book(alice, day);
        assertEq(page.slotOf(day).buyer, alice);

        // Owner can veto until the day starts.
        vm.warp(day * DAY - 1);
        vm.prank(owner);
        page.veto(day);
        assertEq(scoop.balanceOf(alice), 100 * PRICE);

        // Re-book is possible until the last second of the day before; then the day runs and ends.
        _book(bob, day);
        vm.warp((day + 1) * DAY);
        page.burn(day);
        assertEq(scoop.balanceOf(DEAD), PRICE);
        assertEq(scoop.balanceOf(address(page)), 0);
        assertTrue(page.slotOf(day).burned);
        assertEq(page.slotOf(day).buyer, bob);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Headline validation over the whole byte space
    // ─────────────────────────────────────────────────────────────────────────────

    function testFuzz_headline_anyPrintableOfValidLengthRoundTrips(uint256 seed, uint256 len) public {
        len = bound(len, 1, 80);
        bytes memory h = _printable(seed, len);
        uint256 day = _tomorrow();
        vm.prank(alice);
        page.book(day, promoted, string(h), "");
        assertEq(page.slotOf(day).headline, string(h));
        assertEq(bytes(page.slotOf(day).headline).length, len);
    }

    function testFuzz_headline_oneNonPrintableByteAnywhereIsRejected(uint256 seed, uint256 len, uint256 pos, uint8 bad)
        public
    {
        len = bound(len, 1, 80);
        pos = bound(pos, 0, len - 1);
        bytes memory h = _printable(seed, len);
        h[pos] = _nonPrintable(bad);

        vm.prank(alice);
        vm.expectRevert(ScoopFrontPage.InvalidHeadline.selector);
        page.book(_tomorrow(), promoted, string(h), "");
        assertEq(page.slotOf(_tomorrow()).buyer, address(0));
    }

    function testFuzz_headline_longerThan80IsRejected(uint256 seed, uint256 len) public {
        len = bound(len, 81, 2000);
        bytes memory h = _printable(seed, len);
        vm.prank(alice);
        vm.expectRevert(ScoopFrontPage.InvalidHeadline.selector);
        page.book(_tomorrow(), promoted, string(h), "");
    }

    /// @dev Spaces are printable ASCII (0x20), so a headline of only spaces passes the stated rule.
    function test_headline_onlySpacesIsAccepted() public {
        uint256 day = _tomorrow();
        vm.prank(alice);
        page.book(day, promoted, "   ", "");
        assertEq(page.slotOf(day).headline, "   ");
    }

    /// @dev Every rejected byte value, pinned one by one: 0x00-0x1F and 0x7F-0xFF.
    function test_headline_everyNonPrintableByteRejected() public {
        for (uint256 c = 0; c < 256; c++) {
            if (c >= 0x20 && c <= 0x7E) continue;
            bytes memory h = abi.encodePacked("ok", bytes1(uint8(c)), "ok");
            vm.prank(alice);
            vm.expectRevert(ScoopFrontPage.InvalidHeadline.selector);
            page.book(_tomorrow(), promoted, string(h), "");
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Link validation over the whole byte space
    // ─────────────────────────────────────────────────────────────────────────────

    function testFuzz_link_anyHttpsPrintableOfValidLengthRoundTrips(uint256 seed, uint256 tail) public {
        tail = bound(tail, 0, 112); // total 8..120
        bytes memory link = abi.encodePacked("https://", _printable(seed, tail));
        uint256 day = _tomorrow();
        vm.prank(alice);
        page.book(day, promoted, "H", string(link));
        assertEq(page.slotOf(day).link, string(link));
    }

    function testFuzz_link_anyChangeToThePrefixIsRejected(uint256 seed, uint256 pos, uint8 replacement) public {
        pos = bound(pos, 0, 7);
        bytes memory link = abi.encodePacked("https://", _printable(seed, 20));
        bytes1 original = link[pos];
        bytes1 repl = bytes1(uint8(0x20 + uint256(replacement) % 95));
        if (repl == original) repl = bytes1(uint8(original) == 0x7E ? 0x20 : uint8(original) + 1);
        link[pos] = repl;

        vm.prank(alice);
        vm.expectRevert(ScoopFrontPage.InvalidLink.selector);
        page.book(_tomorrow(), promoted, "H", string(link));
    }

    function testFuzz_link_oneNonPrintableByteAnywhereIsRejected(uint256 seed, uint256 tail, uint256 pos, uint8 bad)
        public
    {
        tail = bound(tail, 1, 112);
        bytes memory link = abi.encodePacked("https://", _printable(seed, tail));
        pos = bound(pos, 0, link.length - 1);
        link[pos] = _nonPrintable(bad);

        vm.prank(alice);
        vm.expectRevert(ScoopFrontPage.InvalidLink.selector);
        page.book(_tomorrow(), promoted, "H", string(link));
    }

    function testFuzz_link_longerThan120IsRejected(uint256 seed, uint256 tail) public {
        tail = bound(tail, 113, 2000);
        bytes memory link = abi.encodePacked("https://", _printable(seed, tail));
        vm.prank(alice);
        vm.expectRevert(ScoopFrontPage.InvalidLink.selector);
        page.book(_tomorrow(), promoted, "H", string(link));
    }

    /// @dev A non-empty link shorter than the prefix can never carry it, whatever its bytes.
    function testFuzz_link_shorterThanPrefixIsRejected(uint256 seed, uint256 len) public {
        len = bound(len, 1, 7);
        bytes memory link = _printable(seed, len);
        vm.prank(alice);
        vm.expectRevert(ScoopFrontPage.InvalidLink.selector);
        page.book(_tomorrow(), promoted, "H", string(link));
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Price and token pulls: exact amounts, exact allowances
    // ─────────────────────────────────────────────────────────────────────────────

    /// @dev For any price the owner sets, `book` pulls exactly that much, or reverts without any
    ///      state change when the buyer cannot pay it.
    function testFuzz_book_pullsExactlyThePriceOrNothing(uint256 newPrice) public {
        vm.prank(owner);
        page.setPrice(newPrice);
        assertEq(page.price(), newPrice);

        uint256 balance = scoop.balanceOf(alice);
        uint256 day = _tomorrow();

        vm.prank(alice);
        if (newPrice > balance) {
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, balance, newPrice)
            );
        }
        page.book(day, promoted, "H", "");

        if (newPrice > balance) {
            assertEq(page.slotOf(day).buyer, address(0), "slot stored despite failed payment");
            assertEq(scoop.balanceOf(alice), balance);
            assertEq(scoop.balanceOf(address(page)), 0);
        } else {
            assertEq(page.slotOf(day).paid, newPrice);
            assertEq(scoop.balanceOf(alice), balance - newPrice);
            assertEq(scoop.balanceOf(address(page)), newPrice);
        }
    }

    /// @dev Allowance of exactly the price is enough and is consumed to zero; one wei less is not.
    function testFuzz_book_allowanceMustCoverThePrice(uint256 allowance) public {
        address carol = makeAddr("carol");
        scoop.transfer(carol, PRICE);
        allowance = bound(allowance, 0, PRICE);
        vm.prank(carol);
        scoop.approve(address(page), allowance);

        uint256 day = _tomorrow();
        vm.prank(carol);
        if (allowance < PRICE) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IERC20Errors.ERC20InsufficientAllowance.selector, address(page), allowance, PRICE
                )
            );
        }
        page.book(day, promoted, "H", "");

        if (allowance < PRICE) {
            assertEq(page.slotOf(day).buyer, address(0));
            assertEq(scoop.balanceOf(carol), PRICE);
        } else {
            assertEq(page.slotOf(day).buyer, carol);
            assertEq(scoop.allowance(carol, address(page)), 0);
            assertEq(scoop.balanceOf(carol), 0);
        }
    }

    /// @dev A refund is always what was paid, never the price at veto time, in both directions.
    function testFuzz_veto_refundsWhatWasPaidNotCurrentPrice(uint256 priceAtBooking, uint256 priceAtVeto) public {
        priceAtBooking = bound(priceAtBooking, 0, 100 * PRICE);
        uint256 day = _tomorrow();

        vm.prank(owner);
        page.setPrice(priceAtBooking);
        _book(alice, day);
        assertEq(page.slotOf(day).paid, priceAtBooking);

        vm.prank(owner);
        page.setPrice(priceAtVeto);

        vm.prank(owner);
        page.veto(day);
        assertEq(scoop.balanceOf(alice), 100 * PRICE, "refund differs from what was paid");
        assertEq(scoop.balanceOf(address(page)), 0);
    }

    /// @dev A burn moves what was paid, never the price at burn time.
    function testFuzz_burn_movesWhatWasPaidNotCurrentPrice(uint256 priceAtBooking, uint256 priceAtBurn) public {
        priceAtBooking = bound(priceAtBooking, 0, 100 * PRICE);
        uint256 day = _tomorrow();

        vm.prank(owner);
        page.setPrice(priceAtBooking);
        _book(alice, day);

        vm.prank(owner);
        page.setPrice(priceAtBurn);

        vm.warp((day + 1) * DAY);
        page.burn(day);
        assertEq(scoop.balanceOf(DEAD), priceAtBooking);
        assertEq(scoop.balanceOf(address(page)), 0);
        assertEq(scoop.balanceOf(alice), 100 * PRICE - priceAtBooking);
    }

    /// @dev Only the owner can set any price; everyone else gets the same refusal for every value.
    function testFuzz_setPrice_rejectsEveryNonOwner(address caller, uint256 newPrice) public {
        vm.assume(caller != owner);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        page.setPrice(newPrice);
        assertEq(page.price(), PRICE);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Timing boundaries of veto and burn at every second
    // ─────────────────────────────────────────────────────────────────────────────

    /// @dev veto succeeds at any second strictly before the day starts and at no second after.
    function testFuzz_veto_timingBoundaryIsDayStart(uint256 offset, uint256 secondsAfterBooking) public {
        offset = bound(offset, 1, 30);
        uint256 day = page.currentDay() + offset;
        _book(alice, day);

        secondsAfterBooking = bound(secondsAfterBooking, 0, 40 * DAY);
        vm.warp(START + secondsAfterBooking);
        bool beforeStart = block.timestamp < day * DAY;

        vm.prank(owner);
        if (!beforeStart) vm.expectRevert(abi.encodeWithSelector(ScoopFrontPage.DayAlreadyStarted.selector, day));
        page.veto(day);

        if (beforeStart) {
            assertEq(page.slotOf(day).buyer, address(0));
            assertEq(scoop.balanceOf(alice), 100 * PRICE);
        } else {
            assertEq(page.slotOf(day).buyer, alice);
            assertEq(scoop.balanceOf(address(page)), PRICE);
        }
    }

    /// @dev burn succeeds at any second at or after the day ends and at no second before.
    function testFuzz_burn_timingBoundaryIsDayEnd(uint256 offset, uint256 secondsAfterBooking, address caller) public {
        offset = bound(offset, 1, 30);
        uint256 day = page.currentDay() + offset;
        _book(alice, day);

        secondsAfterBooking = bound(secondsAfterBooking, 0, 40 * DAY);
        vm.warp(START + secondsAfterBooking);
        bool ended = block.timestamp >= (day + 1) * DAY;

        vm.prank(caller);
        if (!ended) vm.expectRevert(abi.encodeWithSelector(ScoopFrontPage.DayNotEnded.selector, day));
        page.burn(day);

        assertEq(page.slotOf(day).burned, ended);
        assertEq(scoop.balanceOf(DEAD), ended ? PRICE : 0);
        assertEq(scoop.balanceOf(address(page)), ended ? 0 : PRICE);
    }

    /// @dev At no second can a booking be both vetoable and burnable: the day itself separates them.
    function testFuzz_vetoAndBurnWindowsNeverOverlap(uint256 secondsAfterBooking) public {
        uint256 day = _tomorrow();
        _book(alice, day);
        secondsAfterBooking = bound(secondsAfterBooking, 0, 5 * DAY);
        vm.warp(START + secondsAfterBooking);

        uint256 snap = vm.snapshotState();
        vm.prank(owner);
        (bool vetoOk,) = address(page).call(abi.encodeWithSelector(ScoopFrontPage.veto.selector, day));
        vm.revertToState(snap);
        (bool burnOk,) = address(page).call(abi.encodeWithSelector(ScoopFrontPage.burn.selector, day));

        assertFalse(vetoOk && burnOk, "veto and burn both possible at the same time");
        if (block.timestamp < day * DAY) assertTrue(vetoOk && !burnOk);
        else if (block.timestamp < (day + 1) * DAY) assertTrue(!vetoOk && !burnOk);
        else assertTrue(!vetoOk && burnOk);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // bookedDays over the whole range space
    // ─────────────────────────────────────────────────────────────────────────────

    function testFuzz_bookedDays_rangeIsValidatedExactly(uint256 from, uint256 to) public {
        from = bound(from, 0, 1e30);
        to = bound(to, 0, 1e30);
        bool reversed = to < from;
        bool tooWide = !reversed && to - from >= 366;
        if (reversed || tooWide) {
            vm.expectRevert(abi.encodeWithSelector(ScoopFrontPage.InvalidRange.selector, from, to));
            page.bookedDays(from, to);
        } else {
            uint256[] memory r = page.bookedDays(from, to);
            assertEq(r.length, 0);
        }
    }

    /// @dev Any subset of the 30 bookable days, listed back exactly and in order.
    function testFuzz_bookedDays_listsExactlyWhatIsBooked(uint32 mask) public {
        uint256 first = _tomorrow();
        uint256 expected;
        for (uint256 i = 0; i < 30; i++) {
            if (mask & (uint32(1) << uint32(i)) != 0) {
                _book(i % 2 == 0 ? alice : bob, first + i);
                expected++;
            }
        }
        uint256[] memory listed = page.bookedDays(first, first + 29);
        assertEq(listed.length, expected);
        uint256 j;
        for (uint256 i = 0; i < 30; i++) {
            if (mask & (uint32(1) << uint32(i)) != 0) {
                assertEq(listed[j++], first + i);
            }
        }
        // Days just outside the span are not reported.
        assertEq(page.bookedDays(first - 1, first - 1).length, 0);
        assertEq(page.bookedDays(first + 30, first + 30).length, 0);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Per-day and per-buyer edge cases
    // ─────────────────────────────────────────────────────────────────────────────

    /// @dev One buyer may take every day of the window; the contract holds exactly 30 prices.
    function test_oneBuyerCanBookTheWholeWindow() public {
        uint256 first = _tomorrow();
        for (uint256 i = 0; i < 30; i++) {
            _book(alice, first + i);
        }
        assertEq(page.bookedDays(first, first + 29).length, 30);
        assertEq(scoop.balanceOf(address(page)), 30 * PRICE);
        assertEq(scoop.balanceOf(alice), 70 * PRICE);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ScoopFrontPage.DayOutOfWindow.selector, first + 30, first, first + 29));
        page.book(first + 30, promoted, "H", "");
    }

    /// @dev Veto, rebook by someone else, then burn: the refund goes to the first buyer, the burn
    ///      takes the second buyer's payment, and the archive records the second buyer.
    function test_vetoRebookBurnSequence() public {
        uint256 day = _tomorrow();
        vm.prank(owner);
        page.setPrice(3 * PRICE);
        _book(alice, day);

        vm.prank(owner);
        page.setPrice(PRICE);
        vm.prank(owner);
        page.veto(day);
        assertEq(scoop.balanceOf(alice), 100 * PRICE);

        _book(bob, day);
        assertEq(page.slotOf(day).paid, PRICE);

        vm.warp((day + 1) * DAY);
        page.burn(day);
        assertEq(scoop.balanceOf(DEAD), PRICE);
        assertEq(scoop.balanceOf(bob), 99 * PRICE);
        assertEq(scoop.balanceOf(address(page)), 0);
        assertEq(page.slotOf(day).buyer, bob);
    }

    /// @dev A vetoed day can be vetoed again only after it is rebooked, and each veto refunds its own buyer.
    function test_repeatedVetoRefundsEachBuyer() public {
        uint256 day = _tomorrow();
        _book(alice, day);
        vm.prank(owner);
        page.veto(day);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ScoopFrontPage.DayNotBooked.selector, day));
        page.veto(day);

        _book(bob, day);
        vm.prank(owner);
        page.veto(day);
        assertEq(scoop.balanceOf(alice), 100 * PRICE);
        assertEq(scoop.balanceOf(bob), 100 * PRICE);
        assertEq(scoop.balanceOf(address(page)), 0);
    }

    /// @dev The buyer has no cancel path: neither veto nor burn before the day, nor any refund call.
    function test_buyerCannotCancelOrRefundThemselves() public {
        uint256 day = _tomorrow();
        _book(alice, day);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        page.veto(day);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ScoopFrontPage.DayNotEnded.selector, day));
        page.burn(day);

        string[4] memory signatures = ["cancel(uint256)", "refund(uint256)", "unbook(uint256)", "claim(uint256)"];
        for (uint256 i = 0; i < signatures.length; i++) {
            vm.prank(alice);
            (bool ok,) = address(page).call(abi.encodeWithSignature(signatures[i], day));
            assertFalse(ok, signatures[i]);
        }
        assertEq(scoop.balanceOf(address(page)), PRICE);
        assertEq(scoop.balanceOf(alice), 99 * PRICE);
    }

    /// @dev Burning one day never touches another day's held SCOOP, in any order.
    function testFuzz_burn_orderIndependent(uint256 seed) public {
        uint256 first = _tomorrow();
        uint256[] memory days_ = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) {
            days_[i] = first + i;
            _book(i % 2 == 0 ? alice : bob, days_[i]);
        }
        vm.warp((first + 5) * DAY);

        // Fisher-Yates shuffle driven by the seed, then burn in that order.
        for (uint256 i = 4; i > 0; i--) {
            uint256 j = uint256(keccak256(abi.encode(seed, i))) % (i + 1);
            (days_[i], days_[j]) = (days_[j], days_[i]);
        }
        for (uint256 i = 0; i < 5; i++) {
            page.burn(days_[i]);
            assertEq(scoop.balanceOf(address(page)), (4 - i) * PRICE);
            assertEq(scoop.balanceOf(DEAD), (i + 1) * PRICE);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Ownership edge cases
    // ─────────────────────────────────────────────────────────────────────────────

    function test_transferOwnership_toZeroClearsPending() public {
        address nominee = makeAddr("nominee");
        vm.prank(owner);
        page.transferOwnership(nominee);
        assertEq(page.pendingOwner(), nominee);

        vm.prank(owner);
        page.transferOwnership(address(0));
        assertEq(page.pendingOwner(), address(0));

        vm.prank(nominee);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nominee));
        page.acceptOwnership();
        assertEq(page.owner(), owner);
    }

    function testFuzz_transferOwnership_rejectsEveryNonOwner(address caller, address nominee) public {
        vm.assume(caller != owner);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        page.transferOwnership(nominee);
        assertEq(page.pendingOwner(), address(0));
    }

    /// @dev Ownership never changes the custody rules: a new owner still cannot withdraw.
    function test_newOwnerStillCannotWithdraw() public {
        uint256 day = _tomorrow();
        _book(alice, day);

        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        page.transferOwnership(newOwner);
        vm.prank(newOwner);
        page.acceptOwnership();

        string[3] memory signatures = ["withdraw(uint256)", "withdraw(address,uint256)", "sweep(address)"];
        for (uint256 i = 0; i < signatures.length; i++) {
            vm.prank(newOwner);
            (bool ok,) = address(page).call(abi.encodeWithSignature(signatures[i], newOwner, PRICE));
            assertFalse(ok, signatures[i]);
        }
        assertEq(scoop.balanceOf(address(page)), PRICE);
        assertEq(scoop.balanceOf(newOwner), 0);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Misbehaving or missing token
    // ─────────────────────────────────────────────────────────────────────────────

    /// @dev The constructor accepts a codeless token (the launch runs it on an empty chain), but a
    ///      booking against one must fail cleanly and store nothing.
    function test_book_againstCodelessTokenRevertsAndStoresNothing() public {
        address codeless = makeAddr("codelessToken");
        ScoopFrontPage p = new ScoopFrontPage(codeless, owner);
        uint256 day = _tomorrow();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, codeless));
        p.book(day, promoted, "H", "");
        assertEq(p.slotOf(day).buyer, address(0));
    }

    /// @dev A token that returns false instead of reverting must not leave a booking behind.
    function test_book_againstFalseReturningTokenRevertsAndStoresNothing() public {
        FalseToken bad = new FalseToken();
        ScoopFrontPage p = new ScoopFrontPage(address(bad), owner);
        uint256 day = _tomorrow();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(bad)));
        p.book(day, promoted, "H", "");
        assertEq(p.slotOf(day).buyer, address(0));
        assertEq(p.bookedDays(day, day).length, 0);
    }

    /// @dev If the token later refuses a transfer out, veto and burn revert and the slot is untouched,
    ///      so the held amount is never lost to bookkeeping.
    function test_vetoAndBurn_revertWhollyWhenTokenTransferFails() public {
        TogglingToken tok = new TogglingToken();
        ScoopFrontPage p = new ScoopFrontPage(address(tok), owner);
        tok.mint(alice, PRICE);
        vm.prank(alice);
        tok.approve(address(p), PRICE);
        uint256 day = _tomorrow();
        vm.prank(alice);
        p.book(day, promoted, "H", "");

        tok.setFailTransfers(true);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(tok)));
        p.veto(day);
        assertEq(p.slotOf(day).buyer, alice, "veto cleared the slot without refunding");

        vm.warp((day + 1) * DAY);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(tok)));
        p.burn(day);
        assertFalse(p.slotOf(day).burned, "burn marked the slot without moving tokens");

        tok.setFailTransfers(false);
        p.burn(day);
        assertTrue(p.slotOf(day).burned);
        assertEq(tok.balanceOf(DEAD), PRICE);
    }
}

/// @dev ERC-20 whose transfers return false without reverting.
contract FalseToken is IERC20 {
    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;
    uint256 public override totalSupply;

    function approve(address spender, uint256 amount) external override returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address, uint256) external pure override returns (bool) {
        return false;
    }

    function transferFrom(address, address, uint256) external pure override returns (bool) {
        return false;
    }
}

/// @dev ERC-20 whose outgoing transfers can be switched to return false after a booking was taken.
contract TogglingToken is IERC20 {
    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;
    uint256 public override totalSupply;
    bool public failTransfers;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function setFailTransfers(bool v) external {
        failTransfers = v;
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        if (failTransfers) return false;
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "allowance");
        allowance[from][msg.sender] = a - amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) private {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}
