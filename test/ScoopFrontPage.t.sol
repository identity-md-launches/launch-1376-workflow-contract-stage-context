// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {ScoopFrontPage} from "../src/ScoopFrontPage.sol";

contract ScoopFrontPageTest is Test {
    uint256 internal constant DAY = 1 days;
    uint256 internal constant PRICE = 2_000_000e18;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    /// @dev Day 20,740 is a UTC day in October 2026; START is noon of that day.
    uint256 internal constant START_DAY = 20_740;
    uint256 internal constant START = START_DAY * DAY + 12 hours;

    LaunchToken internal scoop;
    ScoopFrontPage internal page;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal promoted = makeAddr("promotedToken");

    event Booked(
        uint256 indexed day, address indexed buyer, address indexed token, uint256 paid, string headline, string link
    );
    event Vetoed(uint256 indexed day, address indexed buyer, uint256 refunded);
    event Burned(uint256 indexed day, address indexed caller, uint256 amount);
    event PriceChanged(uint256 oldPrice, uint256 newPrice, uint256 effectiveFromDay);

    function setUp() public {
        vm.warp(START);
        scoop = new LaunchToken();
        page = new ScoopFrontPage(address(scoop), owner);

        scoop.transfer(alice, 10 * PRICE);
        scoop.transfer(bob, 10 * PRICE);
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

    function _repeat(bytes1 c, uint256 n) internal pure returns (string memory) {
        bytes memory b = new bytes(n);
        for (uint256 i = 0; i < n; i++) {
            b[i] = c;
        }
        return string(b);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────────

    function test_constructor_setsTokenOwnerAndPrice() public view {
        assertEq(address(page.scoop()), address(scoop));
        assertEq(page.owner(), owner);
        assertEq(page.price(), PRICE);
        assertEq(page.INITIAL_PRICE(), 2_000_000e18);
        assertEq(page.BURN_ADDRESS(), DEAD);
        assertEq(page.MAX_DAYS_AHEAD(), 30);
    }

    function test_constructor_emitsInitialPrice() public {
        vm.expectEmit(true, true, true, true);
        emit PriceChanged(0, PRICE, START_DAY);
        ScoopFrontPage p = new ScoopFrontPage(address(scoop), owner);
        (uint256 next, uint256 fromDay) = p.nextPrice();
        assertEq(next, PRICE);
        assertEq(fromDay, 0, "initial price is in force from the first block");
    }

    function test_constructor_doesNotRequireTokenCode() public {
        // The launch checks run constructors on an empty chain: the token address may have no code.
        address codeless = makeAddr("codelessToken");
        assertEq(codeless.code.length, 0);
        ScoopFrontPage p = new ScoopFrontPage(codeless, owner);
        assertEq(address(p.scoop()), codeless);
        assertEq(p.owner(), owner);
    }

    function test_constructor_ownerIsNotDeployer() public view {
        assertTrue(page.owner() != address(this));
    }

    function test_revert_constructor_zeroToken() public {
        vm.expectRevert(ScoopFrontPage.ZeroToken.selector);
        new ScoopFrontPage(address(0), owner);
    }

    function test_revert_constructor_zeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new ScoopFrontPage(address(scoop), address(0));
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // book: success
    // ─────────────────────────────────────────────────────────────────────────────

    function test_book_storesSlotPullsPriceAndEmits() public {
        uint256 day = _tomorrow();
        uint256 aliceBefore = scoop.balanceOf(alice);

        vm.expectEmit(true, true, true, true);
        emit Booked(day, alice, promoted, PRICE, "Scoop goes to print", "https://scoop.example");
        vm.prank(alice);
        page.book(day, promoted, "Scoop goes to print", "https://scoop.example");

        ScoopFrontPage.Slot memory s = page.slotOf(day);
        assertEq(s.buyer, alice);
        assertEq(s.token, promoted);
        assertEq(s.paid, PRICE);
        assertFalse(s.burned);
        assertEq(s.headline, "Scoop goes to print");
        assertEq(s.link, "https://scoop.example");

        assertEq(scoop.balanceOf(alice), aliceBefore - PRICE);
        assertEq(scoop.balanceOf(address(page)), PRICE);
    }

    function test_book_windowBoundaries() public {
        uint256 today = block.timestamp / DAY;
        (uint256 first, uint256 last) = page.bookingWindow();
        assertEq(first, today + 1);
        assertEq(last, today + 30);
        assertEq(page.currentDay(), today);

        _book(alice, today + 1);
        _book(alice, today + 30);
        assertEq(page.slotOf(today + 1).buyer, alice);
        assertEq(page.slotOf(today + 30).buyer, alice);
    }

    function test_book_windowMovesWithTime() public {
        uint256 day = _tomorrow() + 30; // one past the window right now
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ScoopFrontPage.DayOutOfWindow.selector, day, day - 30, day - 1));
        page.book(day, promoted, "H", "");

        vm.warp(block.timestamp + DAY);
        _book(alice, day);
        assertEq(page.slotOf(day).buyer, alice);
    }

    function test_book_lastSecondOfTodayStillAllowsTomorrow() public {
        uint256 today = block.timestamp / DAY;
        vm.warp((today + 1) * DAY - 1);
        _book(alice, today + 1);
        assertEq(page.slotOf(today + 1).buyer, alice);
    }

    function test_book_emptyLinkAllowed() public {
        uint256 day = _tomorrow();
        vm.prank(alice);
        page.book(day, promoted, "No link", "");
        assertEq(page.slotOf(day).link, "");
    }

    function test_book_bareHttpsPrefixAllowed() public {
        uint256 day = _tomorrow();
        vm.prank(alice);
        page.book(day, promoted, "H", "https://");
        assertEq(page.slotOf(day).link, "https://");
    }

    function test_book_headlineLengthBounds() public {
        uint256 day = _tomorrow();
        vm.prank(alice);
        page.book(day, promoted, "X", "");
        assertEq(bytes(page.slotOf(day).headline).length, 1);

        string memory eighty = _repeat("A", 80);
        vm.prank(alice);
        page.book(day + 1, promoted, eighty, "");
        assertEq(bytes(page.slotOf(day + 1).headline).length, 80);
    }

    function test_book_linkMaxLength() public {
        uint256 day = _tomorrow();
        string memory link = string.concat("https://", _repeat("a", 112)); // 120 bytes
        assertEq(bytes(link).length, 120);
        vm.prank(alice);
        page.book(day, promoted, "H", link);
        assertEq(bytes(page.slotOf(day).link).length, 120);
    }

    function test_book_everyPrintableAsciiByteAccepted() public {
        bytes memory b = new bytes(0x7E - 0x20 + 1); // 95 bytes, split across two headlines
        for (uint256 i = 0; i < b.length; i++) {
            b[i] = bytes1(uint8(0x20 + i));
        }
        bytes memory firstHalf = new bytes(48);
        bytes memory secondHalf = new bytes(47);
        for (uint256 i = 0; i < 48; i++) {
            firstHalf[i] = b[i];
        }
        for (uint256 i = 0; i < 47; i++) {
            secondHalf[i] = b[48 + i];
        }
        uint256 day = _tomorrow();
        vm.prank(alice);
        page.book(day, promoted, string(firstHalf), "");
        vm.prank(alice);
        page.book(day + 1, promoted, string(secondHalf), "");
        assertEq(page.slotOf(day).headline, string(firstHalf));
        assertEq(page.slotOf(day + 1).headline, string(secondHalf));
    }

    function test_book_differentBuyersDifferentDays() public {
        uint256 day = _tomorrow();
        _book(alice, day);
        _book(bob, day + 1);
        assertEq(page.slotOf(day).buyer, alice);
        assertEq(page.slotOf(day + 1).buyer, bob);
        assertEq(scoop.balanceOf(address(page)), 2 * PRICE);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // book: failures
    // ─────────────────────────────────────────────────────────────────────────────

    function test_revert_book_today() public {
        uint256 today = block.timestamp / DAY;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ScoopFrontPage.DayOutOfWindow.selector, today, today + 1, today + 30));
        page.book(today, promoted, "H", "");
    }

    function test_revert_book_yesterday() public {
        uint256 today = block.timestamp / DAY;
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ScoopFrontPage.DayOutOfWindow.selector, today - 1, today + 1, today + 30)
        );
        page.book(today - 1, promoted, "H", "");
    }

    function test_revert_book_thirtyOneDaysAhead() public {
        uint256 today = block.timestamp / DAY;
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ScoopFrontPage.DayOutOfWindow.selector, today + 31, today + 1, today + 30)
        );
        page.book(today + 31, promoted, "H", "");
    }

    function test_revert_book_dayZero() public {
        uint256 today = block.timestamp / DAY;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ScoopFrontPage.DayOutOfWindow.selector, 0, today + 1, today + 30));
        page.book(0, promoted, "H", "");
    }

    function test_revert_book_alreadyBooked_firstComeFirstServed() public {
        uint256 day = _tomorrow();
        _book(alice, day);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ScoopFrontPage.DayAlreadyBooked.selector, day));
        page.book(day, promoted, "Second", "");

        // Same buyer cannot double-book either.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ScoopFrontPage.DayAlreadyBooked.selector, day));
        page.book(day, promoted, "Again", "");

        assertEq(page.slotOf(day).buyer, alice);
        assertEq(scoop.balanceOf(address(page)), PRICE);
    }

    function test_revert_book_zeroPromotedToken() public {
        vm.prank(alice);
        vm.expectRevert(ScoopFrontPage.ZeroPromotedToken.selector);
        page.book(_tomorrow(), address(0), "H", "");
    }

    function test_revert_book_emptyHeadline() public {
        vm.prank(alice);
        vm.expectRevert(ScoopFrontPage.InvalidHeadline.selector);
        page.book(_tomorrow(), promoted, "", "");
    }

    function test_revert_book_headlineTooLong() public {
        string memory eightyOne = _repeat("A", 81);
        vm.prank(alice);
        vm.expectRevert(ScoopFrontPage.InvalidHeadline.selector);
        page.book(_tomorrow(), promoted, eightyOne, "");
    }

    function test_revert_book_headlineNonPrintable() public {
        string[5] memory bad = [
            "line\nbreak",
            "tab\tbed",
            string(abi.encodePacked("del", bytes1(0x7F))),
            string(abi.encodePacked(bytes1(0x00), "nul")),
            unicode"café"
        ];
        for (uint256 i = 0; i < bad.length; i++) {
            vm.prank(alice);
            vm.expectRevert(ScoopFrontPage.InvalidHeadline.selector);
            page.book(_tomorrow(), promoted, bad[i], "");
        }
    }

    function test_revert_book_linkWrongScheme() public {
        string[4] memory bad = ["http://example.com", "ftp://x", "HTTPS://example.com", "javascript:alert(1)"];
        for (uint256 i = 0; i < bad.length; i++) {
            vm.prank(alice);
            vm.expectRevert(ScoopFrontPage.InvalidLink.selector);
            page.book(_tomorrow(), promoted, "H", bad[i]);
        }
    }

    function test_revert_book_linkShorterThanPrefix() public {
        vm.prank(alice);
        vm.expectRevert(ScoopFrontPage.InvalidLink.selector);
        page.book(_tomorrow(), promoted, "H", "https:/");
    }

    function test_revert_book_linkTooLong() public {
        string memory link = string.concat("https://", _repeat("a", 113)); // 121 bytes
        vm.prank(alice);
        vm.expectRevert(ScoopFrontPage.InvalidLink.selector);
        page.book(_tomorrow(), promoted, "H", link);
    }

    function test_revert_book_linkNonPrintable() public {
        vm.prank(alice);
        vm.expectRevert(ScoopFrontPage.InvalidLink.selector);
        page.book(_tomorrow(), promoted, "H", "https://example.com/\n");
    }

    function test_revert_book_withoutAllowance() public {
        address carol = makeAddr("carol");
        scoop.transfer(carol, PRICE);
        vm.prank(carol);
        vm.expectRevert();
        page.book(_tomorrow(), promoted, "H", "");
        assertEq(page.slotOf(_tomorrow()).buyer, address(0));
    }

    function test_revert_book_withoutBalance() public {
        address poor = makeAddr("poor");
        vm.prank(poor);
        scoop.approve(address(page), type(uint256).max);
        vm.prank(poor);
        vm.expectRevert();
        page.book(_tomorrow(), promoted, "H", "");
        assertEq(page.slotOf(_tomorrow()).buyer, address(0));
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Price
    // ─────────────────────────────────────────────────────────────────────────────

    function test_setPrice_schedulesForNextDayAndEmits() public {
        vm.expectEmit(true, true, true, true);
        emit PriceChanged(PRICE, 5e18, START_DAY + 1);
        vm.prank(owner);
        page.setPrice(5e18);

        // Today's price is unchanged; the new one is visible as scheduled.
        assertEq(page.price(), PRICE);
        (uint256 next, uint256 fromDay) = page.nextPrice();
        assertEq(next, 5e18);
        assertEq(fromDay, START_DAY + 1);

        // Last second of today: still the old price.
        vm.warp((START_DAY + 1) * DAY - 1);
        assertEq(page.price(), PRICE);

        // From midnight UTC: the new price.
        vm.warp((START_DAY + 1) * DAY);
        assertEq(page.price(), 5e18);
        vm.warp((START_DAY + 40) * DAY);
        assertEq(page.price(), 5e18);
    }

    /// @dev The reviewer's race: the owner's setPrice lands before a sponsor's already-signed book.
    ///      The sponsor must never pay more than the price() they read.
    function test_setPrice_cannotRepriceABookingInFlight() public {
        uint256 day = _tomorrow();
        uint256 quoted = page.price();
        uint256 before = scoop.balanceOf(alice);

        vm.prank(owner);
        page.setPrice(10 * PRICE);

        _book(alice, day);
        assertEq(before - scoop.balanceOf(alice), quoted, "sponsor paid the quoted price");
        assertEq(page.slotOf(day).paid, quoted);

        // Lowering the price does not give an in-flight booking a discount either: the day's price
        // is what it is until midnight.
        vm.prank(owner);
        page.setPrice(PRICE / 4);
        uint256 bobBefore = scoop.balanceOf(bob);
        _book(bob, day + 1);
        assertEq(bobBefore - scoop.balanceOf(bob), quoted);
    }

    function test_setPrice_appliesOnlyToDaysNotYetBooked() public {
        uint256 day = _tomorrow();
        _book(alice, day);

        vm.prank(owner);
        page.setPrice(3 * PRICE);

        // Existing booking keeps its paid amount.
        assertEq(page.slotOf(day).paid, PRICE);

        // Next UTC day: a new booking pays the new price.
        vm.warp(block.timestamp + DAY);
        assertEq(page.price(), 3 * PRICE);
        uint256 bobBefore = scoop.balanceOf(bob);
        _book(bob, day + 1);
        assertEq(page.slotOf(day + 1).paid, 3 * PRICE);
        assertEq(scoop.balanceOf(bob), bobBefore - 3 * PRICE);

        // Veto of the old booking refunds what was paid, not the new price.
        vm.prank(owner);
        page.veto(day + 1);
        assertEq(scoop.balanceOf(bob), bobBefore);
        assertEq(page.slotOf(day).paid, PRICE);
    }

    function test_setPrice_secondCallSameDayReplacesScheduledPrice() public {
        vm.startPrank(owner);
        page.setPrice(5e18);
        vm.expectEmit(true, true, true, true);
        emit PriceChanged(PRICE, 7e18, START_DAY + 1);
        page.setPrice(7e18);
        vm.stopPrank();

        assertEq(page.price(), PRICE, "today's price untouched");
        (uint256 next, uint256 fromDay) = page.nextPrice();
        assertEq(next, 7e18);
        assertEq(fromDay, START_DAY + 1);

        vm.warp((START_DAY + 1) * DAY);
        assertEq(page.price(), 7e18, "the 5e18 schedule was replaced, never in force");
    }

    function test_setPrice_chainedChangesOverDays() public {
        vm.prank(owner);
        page.setPrice(5e18); // in force from START_DAY + 1

        vm.warp((START_DAY + 1) * DAY + 1 hours);
        assertEq(page.price(), 5e18);
        vm.expectEmit(true, true, true, true);
        emit PriceChanged(5e18, 9e18, START_DAY + 2);
        vm.prank(owner);
        page.setPrice(9e18); // in force from START_DAY + 2; 5e18 stays today

        assertEq(page.price(), 5e18);
        uint256 before = scoop.balanceOf(alice);
        _book(alice, START_DAY + 2);
        assertEq(before - scoop.balanceOf(alice), 5e18);

        vm.warp((START_DAY + 2) * DAY);
        assertEq(page.price(), 9e18);
        before = scoop.balanceOf(alice);
        _book(alice, START_DAY + 3);
        assertEq(before - scoop.balanceOf(alice), 9e18);

        // Many days later with no further change the scheduled price is still the live one.
        vm.warp((START_DAY + 300) * DAY);
        assertEq(page.price(), 9e18);
    }

    function test_setPrice_zeroMakesSlotsFree() public {
        vm.prank(owner);
        page.setPrice(0);
        vm.warp(block.timestamp + DAY);
        uint256 day = _tomorrow();
        uint256 before = scoop.balanceOf(alice);
        _book(alice, day);
        assertEq(scoop.balanceOf(alice), before);
        assertEq(page.slotOf(day).paid, 0);

        vm.warp((day + 1) * DAY);
        page.burn(day);
        assertTrue(page.slotOf(day).burned);
    }

    function test_revert_setPrice_notOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        page.setPrice(1);
        assertEq(page.price(), PRICE);
        (uint256 next,) = page.nextPrice();
        assertEq(next, PRICE);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // veto
    // ─────────────────────────────────────────────────────────────────────────────

    function test_veto_refundsAndFreesDay() public {
        uint256 day = _tomorrow();
        _book(alice, day);
        uint256 aliceBefore = scoop.balanceOf(alice);

        vm.expectEmit(true, true, true, true);
        emit Vetoed(day, alice, PRICE);
        vm.prank(owner);
        page.veto(day);

        assertEq(scoop.balanceOf(alice), aliceBefore + PRICE);
        assertEq(scoop.balanceOf(address(page)), 0);

        ScoopFrontPage.Slot memory s = page.slotOf(day);
        assertEq(s.buyer, address(0));
        assertEq(s.paid, 0);
        assertEq(s.headline, "");
        assertEq(s.link, "");
        assertEq(page.bookedDays(day, day).length, 0);
    }

    function test_veto_freedDayCanBeRebooked() public {
        uint256 day = _tomorrow();
        _book(alice, day);
        vm.prank(owner);
        page.veto(day);

        _book(bob, day);
        assertEq(page.slotOf(day).buyer, bob);
        assertEq(scoop.balanceOf(address(page)), PRICE);
    }

    function test_veto_oneSecondBeforeDayStarts() public {
        uint256 day = _tomorrow();
        _book(alice, day);
        vm.warp(day * DAY - 1);
        vm.prank(owner);
        page.veto(day);
        assertEq(page.slotOf(day).buyer, address(0));
    }

    function test_revert_veto_atDayStart() public {
        uint256 day = _tomorrow();
        _book(alice, day);
        vm.warp(day * DAY);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ScoopFrontPage.DayAlreadyStarted.selector, day));
        page.veto(day);
        assertEq(page.slotOf(day).buyer, alice);
    }

    function test_revert_veto_afterDayEnded() public {
        uint256 day = _tomorrow();
        _book(alice, day);
        vm.warp((day + 1) * DAY + 5);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ScoopFrontPage.DayAlreadyStarted.selector, day));
        page.veto(day);
    }

    function test_revert_veto_notBooked() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ScoopFrontPage.DayNotBooked.selector, _tomorrow()));
        page.veto(_tomorrow());
    }

    function test_revert_veto_notOwner() public {
        uint256 day = _tomorrow();
        _book(alice, day);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        page.veto(day);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        page.veto(day);
        assertEq(page.slotOf(day).buyer, alice);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // burn
    // ─────────────────────────────────────────────────────────────────────────────

    function test_burn_sendsHeldScoopToDeadAndKeepsRecord() public {
        uint256 day = _tomorrow();
        _book(alice, day);
        vm.warp((day + 1) * DAY);

        address anyone = makeAddr("anyone");
        vm.expectEmit(true, true, true, true);
        emit Burned(day, anyone, PRICE);
        vm.prank(anyone);
        page.burn(day);

        assertEq(scoop.balanceOf(DEAD), PRICE);
        assertEq(scoop.balanceOf(address(page)), 0);
        assertEq(scoop.totalSupply(), 1_000_000_000e18);

        ScoopFrontPage.Slot memory s = page.slotOf(day);
        assertEq(s.buyer, alice);
        assertEq(s.paid, PRICE);
        assertTrue(s.burned);
        assertEq(s.headline, "Headline");
    }

    function test_burn_onlyAffectsThatDay() public {
        uint256 day = _tomorrow();
        _book(alice, day);
        _book(bob, day + 1);
        vm.warp((day + 1) * DAY);
        page.burn(day);
        assertEq(scoop.balanceOf(address(page)), PRICE);
        assertFalse(page.slotOf(day + 1).burned);
    }

    function test_revert_burn_oneSecondBeforeDayEnds() public {
        uint256 day = _tomorrow();
        _book(alice, day);
        vm.warp((day + 1) * DAY - 1);
        vm.expectRevert(abi.encodeWithSelector(ScoopFrontPage.DayNotEnded.selector, day));
        page.burn(day);
    }

    function test_revert_burn_duringDay() public {
        uint256 day = _tomorrow();
        _book(alice, day);
        vm.warp(day * DAY + 1 hours);
        vm.expectRevert(abi.encodeWithSelector(ScoopFrontPage.DayNotEnded.selector, day));
        page.burn(day);
    }

    function test_revert_burn_twice() public {
        uint256 day = _tomorrow();
        _book(alice, day);
        vm.warp((day + 1) * DAY);
        page.burn(day);
        vm.expectRevert(abi.encodeWithSelector(ScoopFrontPage.AlreadyBurned.selector, day));
        page.burn(day);
        assertEq(scoop.balanceOf(DEAD), PRICE);
    }

    function test_revert_burn_notBooked() public {
        uint256 day = _tomorrow();
        vm.warp((day + 1) * DAY);
        vm.expectRevert(abi.encodeWithSelector(ScoopFrontPage.DayNotBooked.selector, day));
        page.burn(day);
    }

    function test_revert_burn_vetoedDay() public {
        uint256 day = _tomorrow();
        _book(alice, day);
        vm.prank(owner);
        page.veto(day);
        vm.warp((day + 1) * DAY);
        vm.expectRevert(abi.encodeWithSelector(ScoopFrontPage.DayNotBooked.selector, day));
        page.burn(day);
    }

    function test_revert_vetoAfterBurn() public {
        uint256 day = _tomorrow();
        _book(alice, day);
        vm.warp((day + 1) * DAY);
        page.burn(day);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ScoopFrontPage.DayAlreadyStarted.selector, day));
        page.veto(day);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Views
    // ─────────────────────────────────────────────────────────────────────────────

    function test_bookedDays_listsAscendingInclusive() public {
        uint256 day = _tomorrow();
        _book(alice, day + 4);
        _book(bob, day);
        _book(alice, day + 29);

        uint256[] memory all = page.bookedDays(day, day + 29);
        assertEq(all.length, 3);
        assertEq(all[0], day);
        assertEq(all[1], day + 4);
        assertEq(all[2], day + 29);

        uint256[] memory subset = page.bookedDays(day + 1, day + 28);
        assertEq(subset.length, 1);
        assertEq(subset[0], day + 4);

        assertEq(page.bookedDays(day + 5, day + 28).length, 0);
        assertEq(page.bookedDays(day, day).length, 1);
    }

    function test_bookedDays_maxRange() public view {
        uint256[] memory r = page.bookedDays(100, 100 + 365);
        assertEq(r.length, 0);
    }

    function test_bookedDays_topOfDomainDoesNotOverflow() public view {
        uint256 max = type(uint256).max;
        assertEq(page.bookedDays(max, max).length, 0);
        assertEq(page.bookedDays(max - 10, max).length, 0);
        assertEq(page.bookedDays(max - 365, max).length, 0);
        assertEq(page.bookedDays(0, 0).length, 0);
    }

    function test_revert_bookedDays_tooWide() public {
        vm.expectRevert(abi.encodeWithSelector(ScoopFrontPage.InvalidRange.selector, 100, 100 + 366));
        page.bookedDays(100, 100 + 366);
    }

    function test_revert_bookedDays_reversed() public {
        vm.expectRevert(abi.encodeWithSelector(ScoopFrontPage.InvalidRange.selector, 10, 9));
        page.bookedDays(10, 9);
    }

    function test_slotOf_unbookedIsEmpty() public view {
        ScoopFrontPage.Slot memory s = page.slotOf(_tomorrow());
        assertEq(s.buyer, address(0));
        assertEq(s.token, address(0));
        assertEq(s.paid, 0);
        assertFalse(s.burned);
        assertEq(s.headline, "");
        assertEq(s.link, "");
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Ownership (Ownable2Step)
    // ─────────────────────────────────────────────────────────────────────────────

    function test_ownership_twoStepHandover() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        page.transferOwnership(newOwner);
        assertEq(page.owner(), owner, "handover not complete until accepted");
        assertEq(page.pendingOwner(), newOwner);

        uint256 day = _tomorrow();
        _book(alice, day);

        // Pending owner has no power yet.
        vm.prank(newOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, newOwner));
        page.veto(day);

        vm.prank(newOwner);
        page.acceptOwnership();
        assertEq(page.owner(), newOwner);

        // Old owner lost its powers.
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        page.setPrice(1);

        vm.prank(newOwner);
        page.veto(day);
        assertEq(page.slotOf(day).buyer, address(0));
    }

    function test_revert_acceptOwnership_notPending() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        page.acceptOwnership();
    }

    function test_revert_renounceOwnership_disabled() public {
        uint256 day = _tomorrow();
        _book(alice, day);

        vm.prank(owner);
        vm.expectRevert(ScoopFrontPage.RenounceDisabled.selector);
        page.renounceOwnership();
        vm.prank(alice);
        vm.expectRevert(ScoopFrontPage.RenounceDisabled.selector);
        page.renounceOwnership();

        // Ownership and its powers are intact.
        assertEq(page.owner(), owner);
        vm.prank(owner);
        page.veto(day);
        assertEq(page.slotOf(day).buyer, address(0));
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Custody: no withdraw path, conservation of held SCOOP
    // ─────────────────────────────────────────────────────────────────────────────

    function test_noWithdrawOrAdminEscapeHatch() public {
        uint256 day = _tomorrow();
        _book(alice, day);

        string[8] memory signatures = [
            "withdraw(uint256)",
            "withdraw(address,uint256)",
            "withdrawToken(address,uint256)",
            "rescue(address,uint256)",
            "sweep(address)",
            "pause()",
            "upgradeTo(address)",
            "setScoop(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            vm.prank(owner);
            (bool ok,) = address(page).call(abi.encodeWithSignature(signatures[i], owner, PRICE));
            assertFalse(ok, signatures[i]);
        }
        assertEq(scoop.balanceOf(address(page)), PRICE);
    }

    function test_rejectsEth() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(page).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(address(page).balance, 0);
    }

    function test_conservation_scenario() public {
        uint256 day = _tomorrow();
        _book(alice, day); // will be burned
        _book(bob, day + 1); // will be vetoed
        _book(alice, day + 2); // stays held

        vm.prank(owner);
        page.setPrice(PRICE / 2);
        vm.warp(block.timestamp + DAY); // the half price applies from the next UTC day
        _book(bob, day + 3); // half price, will be burned

        assertEq(scoop.balanceOf(address(page)), 3 * PRICE + PRICE / 2);

        vm.prank(owner);
        page.veto(day + 1); // day + 1 has not started yet
        assertEq(scoop.balanceOf(address(page)), 2 * PRICE + PRICE / 2);

        vm.warp((day + 4) * DAY);
        page.burn(day);
        page.burn(day + 3);
        assertEq(scoop.balanceOf(address(page)), PRICE, "only day+2 remains held");
        assertEq(scoop.balanceOf(DEAD), PRICE + PRICE / 2);

        page.burn(day + 2);
        assertEq(scoop.balanceOf(address(page)), 0);
        assertEq(scoop.balanceOf(DEAD), 2 * PRICE + PRICE / 2);
        assertEq(scoop.balanceOf(alice) + scoop.balanceOf(bob) + scoop.balanceOf(DEAD), 20 * PRICE);
    }

    /// @dev Random bookings, vetoes and burns over a window; the contract balance always equals the
    ///      sum of paid amounts of live (booked, not burned) slots.
    function testFuzz_conservation(uint256 seed) public {
        uint256 base = _tomorrow();
        uint256[] memory paid = new uint256[](40);
        bool[] memory live = new bool[](40);
        uint256 held;

        for (uint256 step = 0; step < 40; step++) {
            uint256 r = uint256(keccak256(abi.encode(seed, step)));
            uint256 action = r % 4;
            uint256 idx = (r >> 8) % 40;
            uint256 day = base + idx;
            (uint256 first, uint256 last) = page.bookingWindow();

            if (action == 0 || action == 1) {
                address buyer = (r >> 16) % 2 == 0 ? alice : bob;
                bool inWindow = day >= first && day <= last;
                bool free = page.slotOf(day).buyer == address(0);
                if (inWindow && free && scoop.balanceOf(buyer) >= page.price()) {
                    _book(buyer, day);
                    paid[idx] = page.price();
                    live[idx] = true;
                    held += paid[idx];
                } else {
                    vm.prank(buyer);
                    vm.expectRevert();
                    page.book(day, promoted, "H", "");
                }
            } else if (action == 2) {
                if (live[idx] && !page.slotOf(day).burned && block.timestamp < day * DAY) {
                    vm.prank(owner);
                    page.veto(day);
                    held -= paid[idx];
                    live[idx] = false;
                    paid[idx] = 0;
                } else {
                    vm.prank(owner);
                    vm.expectRevert();
                    page.veto(day);
                }
            } else {
                if (live[idx] && block.timestamp >= (day + 1) * DAY) {
                    page.burn(day);
                    held -= paid[idx];
                    live[idx] = false;
                } else {
                    vm.expectRevert();
                    page.burn(day);
                }
            }

            if ((r >> 24) % 3 == 0) {
                uint256 quoted = page.price();
                vm.prank(owner);
                page.setPrice(((r >> 32) % 5) * 1e18);
                assertEq(page.price(), quoted, "price moved within the day");
            }
            if ((r >> 40) % 2 == 0) {
                vm.warp(block.timestamp + 1 days + ((r >> 48) % DAY));
            }

            assertEq(scoop.balanceOf(address(page)), held, "held balance drifted");
        }
    }

    /// @dev Whatever the owner does, price() read at any moment is what book pulls for the rest of
    ///      that UTC day.
    function testFuzz_priceStableWithinDay(uint256 newPrice, uint256 secondsIntoDay, uint256 secondsLater) public {
        newPrice = bound(newPrice, 0, 10 * PRICE);
        secondsIntoDay = bound(secondsIntoDay, 0, DAY - 2);
        secondsLater = bound(secondsLater, 0, DAY - 2 - secondsIntoDay);

        vm.warp(START_DAY * DAY + secondsIntoDay);
        uint256 quoted = page.price();
        vm.prank(owner);
        page.setPrice(newPrice);

        vm.warp(block.timestamp + secondsLater);
        assertEq(page.price(), quoted);
        uint256 before = scoop.balanceOf(alice);
        _book(alice, START_DAY + 1);
        assertEq(before - scoop.balanceOf(alice), quoted);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Reentrancy: effects are committed before any token transfer
    // ─────────────────────────────────────────────────────────────────────────────

    function test_reentrancy_burnCannotDoubleBurn() public {
        ReentrantToken evil = new ReentrantToken();
        ScoopFrontPage p = new ScoopFrontPage(address(evil), owner);
        evil.mint(alice, 10 * PRICE);
        vm.prank(alice);
        evil.approve(address(p), type(uint256).max);

        uint256 day = _tomorrow();
        vm.prank(alice);
        p.book(day, promoted, "H", "");

        vm.warp((day + 1) * DAY);
        evil.arm(address(p), abi.encodeWithSelector(ScoopFrontPage.burn.selector, day));
        p.burn(day);

        assertEq(evil.reentryAttempts(), 1);
        assertFalse(evil.reentrySucceeded(), "reentrant burn must revert");
        assertEq(evil.balanceOf(DEAD), PRICE);
        assertEq(evil.balanceOf(address(p)), 0);
    }

    function test_reentrancy_vetoCannotDoubleRefund() public {
        ReentrantToken evil = new ReentrantToken();
        ScoopFrontPage p = new ScoopFrontPage(address(evil), owner);
        evil.mint(alice, 10 * PRICE);
        vm.prank(alice);
        evil.approve(address(p), type(uint256).max);

        uint256 day = _tomorrow();
        vm.prank(alice);
        p.book(day, promoted, "H", "");

        // The hook re-enters as the token contract itself, which is not the owner, and in any case
        // the slot is already cleared before the transfer.
        evil.arm(address(p), abi.encodeWithSelector(ScoopFrontPage.veto.selector, day));
        vm.prank(owner);
        p.veto(day);

        assertEq(evil.reentryAttempts(), 1);
        assertFalse(evil.reentrySucceeded(), "reentrant veto must revert");
        assertEq(evil.balanceOf(alice), 10 * PRICE);
        assertEq(evil.balanceOf(address(p)), 0);
    }

    function test_reentrancy_bookCannotDoubleBook() public {
        ReentrantToken evil = new ReentrantToken();
        ScoopFrontPage p = new ScoopFrontPage(address(evil), owner);
        evil.mint(alice, 10 * PRICE);
        evil.mint(address(evil), 10 * PRICE);
        vm.prank(alice);
        evil.approve(address(p), type(uint256).max);
        vm.prank(address(evil));
        evil.approve(address(p), type(uint256).max);

        uint256 day = _tomorrow();
        evil.arm(address(p), abi.encodeWithSelector(ScoopFrontPage.book.selector, day, promoted, "X", ""));
        vm.prank(alice);
        p.book(day, promoted, "H", "");

        assertEq(evil.reentryAttempts(), 1);
        assertFalse(evil.reentrySucceeded(), "reentrant book of the same day must revert");
        assertEq(p.slotOf(day).buyer, alice);
        assertEq(evil.balanceOf(address(p)), PRICE);
    }
}

/// @dev A minimal ERC-20 that calls back into a target during transfers, to show that the front
///      page commits its effects before any token call. The real SCOOP token has no hooks.
contract ReentrantToken is IERC20 {
    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;
    uint256 public override totalSupply;

    address public target;
    bytes public payload;
    uint256 public reentryAttempts;
    bool public reentrySucceeded;
    bool private _inHook;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function arm(address target_, bytes calldata payload_) external {
        target = target_;
        payload = payload_;
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        _move(msg.sender, to, amount);
        _hook();
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "allowance");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        _move(from, to, amount);
        _hook();
        return true;
    }

    function _move(address from, address to, uint256 amount) private {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }

    function _hook() private {
        if (target == address(0) || _inHook) return;
        _inHook = true;
        reentryAttempts++;
        (bool ok,) = target.call(payload);
        reentrySucceeded = ok;
        _inHook = false;
    }
}
