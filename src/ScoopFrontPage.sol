// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title ScoopFrontPage
/// @notice Sells one sponsored front-page slot of the SCOOP daily per UTC day, paid in SCOOP.
/// @dev Day numbering: `day = block.timestamp / 1 days`. Day `d` starts at `d * 1 days` and has
///      ended once `block.timestamp >= (d + 1) * 1 days`.
///
///      Lifecycle of a slot:
///        1. `book`  : anyone, for a day from tomorrow up to 30 days ahead, first come first served.
///                     The current price in SCOOP is pulled from the buyer and held here.
///        2. `veto`  : owner only, before the day starts. Refunds the held SCOOP in full to the buyer
///                     and frees the day so it can be booked again.
///        3. `burn`  : anyone, after the day has ended. Sends the held SCOOP to the dEaD address,
///                     once per day. The booking stays recorded for the archive.
///
///      Owner powers are exactly: change the price (future bookings only), veto a booking before its
///      day, and the Ownable2Step ownership handover. There is no pause, no upgrade, and no way to
///      withdraw held SCOOP. Held SCOOP only ever goes back to its buyer (veto) or to dEaD (burn).
contract ScoopFrontPage is Ownable2Step {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────────────────────────
    // Types
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice One day's sponsored slot. `buyer == address(0)` means the day is free.
    struct Slot {
        /// @dev Wallet that paid for the slot and receives the refund on veto.
        address buyer;
        /// @dev The IMD coin the sponsor is promoting.
        address token;
        /// @dev SCOOP minor units held for this slot (the price at booking time).
        uint256 paid;
        /// @dev True once `burn` has sent `paid` to the dEaD address.
        bool burned;
        /// @dev 1-80 printable ASCII characters, rendered as plain text by the site.
        string headline;
        /// @dev Empty, or an `https://` URL of at most 120 printable ASCII characters.
        string link;
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Where burned SCOOP goes.
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @notice Price of a slot at deployment: 2,000,000 SCOOP.
    uint256 public constant INITIAL_PRICE = 2_000_000e18;

    /// @notice Furthest day ahead that can be booked, counted from the current UTC day.
    uint256 public constant MAX_DAYS_AHEAD = 30;

    /// @notice Headline length bounds, in bytes (printable ASCII, so bytes == characters).
    uint256 public constant MIN_HEADLINE_LENGTH = 1;
    uint256 public constant MAX_HEADLINE_LENGTH = 80;

    /// @notice Link length bound, in bytes.
    uint256 public constant MAX_LINK_LENGTH = 120;

    /// @notice Largest inclusive range `bookedDays` will scan in one call.
    uint256 public constant MAX_QUERY_RANGE = 366;

    /// @dev Required link prefix.
    bytes8 private constant LINK_PREFIX = "https://";
    uint256 private constant LINK_PREFIX_LENGTH = 8;

    // ─────────────────────────────────────────────────────────────────────────────
    // Storage
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice The SCOOP token slots are paid in.
    IERC20 public immutable scoop;

    /// @dev Current slot price in SCOOP minor units.
    uint256 private _price;

    /// @dev day => slot.
    mapping(uint256 day => Slot) private _slots;

    // ─────────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice A day was booked.
    event Booked(
        uint256 indexed day, address indexed buyer, address indexed token, uint256 paid, string headline, string link
    );

    /// @notice The owner vetoed a booking and the buyer was refunded in full.
    event Vetoed(uint256 indexed day, address indexed buyer, uint256 refunded);

    /// @notice A past day's held SCOOP was sent to the dEaD address.
    event Burned(uint256 indexed day, address indexed caller, uint256 amount);

    /// @notice The slot price changed. Applies to days not yet booked.
    event PriceChanged(uint256 oldPrice, uint256 newPrice);

    // ─────────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────────

    /// @dev The SCOOP token address was zero.
    error ZeroToken();
    /// @dev The promoted token address was zero.
    error ZeroPromotedToken();
    /// @dev `day` is today, in the past, or more than `MAX_DAYS_AHEAD` days ahead.
    error DayOutOfWindow(uint256 day, uint256 firstBookable, uint256 lastBookable);
    /// @dev `day` already has a booking.
    error DayAlreadyBooked(uint256 day);
    /// @dev `day` has no booking.
    error DayNotBooked(uint256 day);
    /// @dev Headline is empty, longer than 80 bytes, or contains a non-printable-ASCII byte.
    error InvalidHeadline();
    /// @dev Link is non-empty and does not start with `https://`, is longer than 120 bytes, or
    ///      contains a non-printable-ASCII byte.
    error InvalidLink();
    /// @dev Veto was attempted at or after the start of the day.
    error DayAlreadyStarted(uint256 day);
    /// @dev Burn was attempted before the day ended.
    error DayNotEnded(uint256 day);
    /// @dev The day's SCOOP was already burned.
    error AlreadyBurned(uint256 day);
    /// @dev `bookedDays` range is reversed or wider than `MAX_QUERY_RANGE`.
    error InvalidRange(uint256 from, uint256 to);

    // ─────────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────────

    /// @param scoop_ The SCOOP launch token. Filled with `$token` by the launch manifest.
    /// @param initialOwner The owner. Filled with `$owner` by the launch manifest. Never the factory.
    /// @dev Makes no external calls and does not require `scoop_` to have code yet: the launch
    ///      checks run constructors on an empty chain. The token is first used in `book`.
    constructor(address scoop_, address initialOwner) Ownable(initialOwner) {
        if (scoop_ == address(0)) revert ZeroToken();
        scoop = IERC20(scoop_);
        _price = INITIAL_PRICE;
        emit PriceChanged(0, INITIAL_PRICE);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Booking
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Book the sponsored front-page slot for `day`.
    /// @param day UTC day index (`timestamp / 1 days`), from tomorrow up to 30 days ahead.
    /// @param token The IMD coin being promoted. Must be non-zero.
    /// @param headline 1-80 printable ASCII characters.
    /// @param link Empty, or an `https://` URL of at most 120 printable ASCII characters.
    /// @dev Pulls `price()` SCOOP from the caller, who must have approved this contract. The amount
    ///      paid is stored with the slot, so a later price change never affects a refund.
    function book(uint256 day, address token, string calldata headline, string calldata link) external {
        (uint256 first, uint256 last) = bookingWindow();
        if (day < first || day > last) revert DayOutOfWindow(day, first, last);
        if (_slots[day].buyer != address(0)) revert DayAlreadyBooked(day);
        if (token == address(0)) revert ZeroPromotedToken();
        _validateHeadline(headline);
        _validateLink(link);

        uint256 paid = _price;
        _slots[day] = Slot({buyer: msg.sender, token: token, paid: paid, burned: false, headline: headline, link: link});

        emit Booked(day, msg.sender, token, paid, headline, link);

        scoop.safeTransferFrom(msg.sender, address(this), paid);
    }

    /// @notice Owner only. Cancel the booking for `day` before that day starts, refunding the
    ///         buyer in full and freeing the day.
    function veto(uint256 day) external onlyOwner {
        Slot memory slot = _slots[day];
        if (slot.buyer == address(0)) revert DayNotBooked(day);
        if (block.timestamp >= day * 1 days) revert DayAlreadyStarted(day);

        delete _slots[day];

        emit Vetoed(day, slot.buyer, slot.paid);

        scoop.safeTransfer(slot.buyer, slot.paid);
    }

    /// @notice Anyone. After `day` has ended, send its held SCOOP to the dEaD address. Once per day.
    function burn(uint256 day) external {
        Slot storage slot = _slots[day];
        if (slot.buyer == address(0)) revert DayNotBooked(day);
        if (block.timestamp < (day + 1) * 1 days) revert DayNotEnded(day);
        if (slot.burned) revert AlreadyBurned(day);

        slot.burned = true;
        uint256 amount = slot.paid;

        emit Burned(day, msg.sender, amount);

        scoop.safeTransfer(BURN_ADDRESS, amount);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Owner
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Owner only. Set the price for days not yet booked. Existing bookings keep what they paid.
    function setPrice(uint256 newPrice) external onlyOwner {
        uint256 old = _price;
        _price = newPrice;
        emit PriceChanged(old, newPrice);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Views
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Current price of a slot in SCOOP minor units.
    function price() external view returns (uint256) {
        return _price;
    }

    /// @notice The slot booked for `day`. `buyer == address(0)` means the day is free.
    function slotOf(uint256 day) external view returns (Slot memory) {
        return _slots[day];
    }

    /// @notice The current UTC day index.
    function currentDay() public view returns (uint256) {
        return block.timestamp / 1 days;
    }

    /// @notice The inclusive range of days that `book` accepts right now: tomorrow to 30 days ahead.
    function bookingWindow() public view returns (uint256 firstBookable, uint256 lastBookable) {
        uint256 today = currentDay();
        return (today + 1, today + MAX_DAYS_AHEAD);
    }

    /// @notice Every booked day in `[from, to]`, ascending. The range may span at most 366 days.
    function bookedDays(uint256 from, uint256 to) external view returns (uint256[] memory days_) {
        if (to < from || to - from >= MAX_QUERY_RANGE) revert InvalidRange(from, to);

        uint256 count = 0;
        for (uint256 d = from; d <= to; ++d) {
            if (_slots[d].buyer != address(0)) ++count;
        }

        days_ = new uint256[](count);
        uint256 i = 0;
        for (uint256 d = from; d <= to; ++d) {
            if (_slots[d].buyer != address(0)) days_[i++] = d;
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Internal validation
    // ─────────────────────────────────────────────────────────────────────────────

    function _validateHeadline(string calldata headline) private pure {
        bytes calldata b = bytes(headline);
        if (b.length < MIN_HEADLINE_LENGTH || b.length > MAX_HEADLINE_LENGTH || !_isPrintableAscii(b)) {
            revert InvalidHeadline();
        }
    }

    function _validateLink(string calldata link) private pure {
        bytes calldata b = bytes(link);
        if (b.length == 0) return;
        if (b.length < LINK_PREFIX_LENGTH || b.length > MAX_LINK_LENGTH || !_isPrintableAscii(b)) {
            revert InvalidLink();
        }
        if (bytes8(b[:LINK_PREFIX_LENGTH]) != LINK_PREFIX) revert InvalidLink();
    }

    /// @dev True when every byte is in 0x20..0x7E (space through tilde).
    function _isPrintableAscii(bytes calldata b) private pure returns (bool) {
        for (uint256 i = 0; i < b.length; ++i) {
            uint8 c = uint8(b[i]);
            if (c < 0x20 || c > 0x7E) return false;
        }
        return true;
    }
}
