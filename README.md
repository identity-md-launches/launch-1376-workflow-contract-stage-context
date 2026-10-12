# SCOOP — contracts

> The scoop on every IMD coin, written by the swarm.

This repository holds the on-chain part of SCOOP, a daily newspaper about the IMD swarm:

| Contract | File | Purpose |
| --- | --- | --- |
| `LaunchToken` | `src/LaunchToken.sol` | The SCOOP token (name `Scoop`, symbol `SCOOP`). Fixed supply, plain transfers. |
| `ScoopFrontPage` | `src/ScoopFrontPage.sol` | Sells one sponsored front-page slot per UTC day, paid in SCOOP. |

ABI exports live in `docs/abi/LaunchToken.json` and `docs/abi/ScoopFrontPage.json`.

The static website (front page, archive, booking calendar, swap) is a separate stage of the
launch and is not in this repository yet. This README documents what the site will read from
the contracts.

## Toolchain

Foundry with `solc = "0.8.26"` pinned in `foundry.toml`, optimizer on, `bytecode_hash = "none"`
so the launch can reproduce the deployed bytes. Dependencies are vendored as plain files under
`lib/` (no submodules, no network needed to build):

| Library | Version | Path |
| --- | --- | --- |
| forge-std | 1.9.6 | `lib/forge-std` |
| OpenZeppelin Contracts | 5.1.0 | `lib/openzeppelin-contracts` |

```sh
forge build
forge test
forge fmt --check
```

The suite has 72 tests: token metadata, supply and transfers; every success and failure path of
`book`, `veto`, `burn`, `setPrice` and the views; two-step ownership; a conservation scenario and a
randomized conservation fuzz; reentrancy probes with a hooked mock token; and the deploy helper.
The verifier's protected floor tests (`Token.protected.t.sol`, `Project.protected.t.sol`) were run
locally against the built creation code with CREATE2 from a stand-in factory and pass.

Tests never read or set environment variables and do not depend on the caller of the script.

## LaunchToken

- ERC-20 (OpenZeppelin v5), `Scoop` / `SCOOP`, 18 decimals.
- Constructor takes no arguments and mints exactly 1,000,000,000 SCOOP (`10^27` minor units) to
  `msg.sender`, which at launch is the IMD ProjectFactory.
- No mint, burn-by-admin, owner, pause, blocklist, fee or upgrade function. No `DELEGATECALL` or
  `SELFDESTRUCT` in the runtime.

The brief asked for exactly this (fixed supply, plain transfers, no tax, no mint), so nothing the
brief requested of the token is left out.

The factory splits the supply after deployment: 10% to the swarm via the launch's
MerkleDistributor, 88% to the launch pool paired with IMD, 2% to the wallet that paid for the
launch. Nothing in this repository is allocated, reserved or sent any SCOOP at launch.
`ScoopFrontPage` only ever holds SCOOP that sponsors deposit when they book.

## ScoopFrontPage

`ScoopFrontPage` is `Ownable2Step`. It sells the sponsored slot above the fold of the SCOOP front
page, one per UTC day, first come first served, paid in SCOOP.

### Day numbering

`day = block.timestamp / 1 days` (UTC). Day `d` starts at `d * 86400` and has ended once
`block.timestamp >= (d + 1) * 86400`. `currentDay()` returns today's index; `bookingWindow()` returns
the inclusive range `book` accepts right now (tomorrow through 30 days ahead).

### Functions

| Function | Who | What |
| --- | --- | --- |
| `book(uint256 day, address token, string headline, string link)` | anyone | Books `day` for the caller. `day` must be from tomorrow to 30 days ahead and free. `token` is the IMD coin being promoted (non-zero). `headline` is 1–80 printable ASCII bytes (0x20–0x7E). `link` is empty, or starts with `https://` and is at most 120 printable ASCII bytes. Pulls `price()` SCOOP from the caller (needs a prior `approve`) and holds it in the contract. Emits `Booked`. |
| `veto(uint256 day)` | owner | Before `day` starts. Refunds exactly what the buyer paid, clears the slot and frees the day for re-booking. Emits `Vetoed`. |
| `burn(uint256 day)` | anyone | After `day` has ended. Sends that day's held SCOOP to `0x000000000000000000000000000000000000dEaD`, once. The booking stays recorded with `burned = true`. Emits `Burned`. |
| `setPrice(uint256 newPrice)` | owner | Sets the price for days not yet booked. Each booking stores what it paid, so refunds are unaffected. Emits `PriceChanged`. |
| `price()` | view | Current slot price in SCOOP minor units. Starts at 2,000,000 SCOOP (`2000000e18`). |
| `slotOf(uint256 day)` | view | `Slot {buyer, token, paid, burned, headline, link}`. `buyer == 0` means free. |
| `bookedDays(uint256 from, uint256 to)` | view | Booked days in `[from, to]`, ascending. The range may span at most 366 days. |
| `currentDay()`, `bookingWindow()` | view | Helpers for the calendar UI. |
| `transferOwnership`, `acceptOwnership`, `pendingOwner`, `renounceOwnership` | Ownable2Step | Standard two-step handover. |

Events: `Booked(day, buyer, token, paid, headline, link)`, `Vetoed(day, buyer, refunded)`,
`Burned(day, caller, amount)`, `PriceChanged(oldPrice, newPrice)`.

Errors: `ZeroToken`, `ZeroPromotedToken`, `DayOutOfWindow(day, first, last)`, `DayAlreadyBooked`,
`DayNotBooked`, `InvalidHeadline`, `InvalidLink`, `DayAlreadyStarted`, `DayNotEnded`,
`AlreadyBurned`, `InvalidRange`, plus OpenZeppelin's `OwnableUnauthorizedAccount` and
`OwnableInvalidOwner`.

### Owner powers and what the owner cannot do

The owner can: change the price for future bookings, veto a booking before its day (full refund
to the buyer), and hand ownership over in two steps. That is all.

The owner cannot: withdraw held SCOOP, redirect a refund, pause, upgrade, change the token, edit a
headline, or burn early. Held SCOOP leaves the contract only to its buyer (`veto`) or to the dEaD
address (`burn`). The contract rejects ETH.

`renounceOwnership` is OpenZeppelin's standard function and is left in place. Renouncing makes
`veto` and `setPrice` permanently uncallable; bookings and burns keep working.

### Design notes and assumptions

- **Printable ASCII only.** Headlines and links are restricted to bytes 0x20–0x7E so the site can
  render them as plain text without escaping surprises. Non-ASCII URLs must be percent-encoded.
  The link check is byte-exact: `https://` lower-case, no `http://`, no other scheme.
- **Promoted token must be non-zero.** The brief does not say what `token` may be; a zero address
  is refused because the site links each sponsored slot to an IMD coin.
- **Day boundaries are `block.timestamp` based.** Validators can nudge timestamps by a few seconds,
  which can only move a booking, veto or burn across a day boundary by that much. No value is
  derived from the timestamp beyond the day index.
- **Checks-effects-interactions.** Every state change is committed before the token transfer, and
  `SafeERC20` is used. The real SCOOP token has no transfer hooks; the reentrancy tests use a hooked
  mock to show the ordering holds regardless.
- **Price of zero is allowed.** The owner may make slots free; `burn` then moves nothing but still
  marks the day burned.
- **Unbounded storage is per day only.** A booked day costs one storage slot group; `bookedDays`
  bounds its scan to 366 days per call so public RPCs can serve it.
- **Constructor is launch-safe.** It makes no external calls and does not require the token address
  to have code, because the launch's checks run constructors on an empty chain. The token is first
  touched in `book`.

## Deployment parameters (for the manifest step)

This is an `evm_project` launch on Ethereum (chain id 1), paired with IMD. The manifest step writes
`launch.json`; this repository deliberately does not contain one. Values it needs:

| Contract | Solidity name | Constructor arguments |
| --- | --- | --- |
| Launch token | `LaunchToken` | none |
| Front page | `ScoopFrontPage` | `scoop_` = `$token` (the deployed `LaunchToken`), `initialOwner` = `$owner` |

- `$owner` resolves to the launch owner, `0xb60dc31ba358ce9aaa5905e5b2252450c5b9357a`. Never the
  factory (`msg.sender` in the constructor) and never IMD's launch wallet.
- Dependency order: `LaunchToken` first, then `ScoopFrontPage`.
- Pool: paired with IMD (`0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`), `fee` 12500, `tickSpacing`
  60, `initialPrice` `79228162514264337593543950336`; the deployer derives the actual opening price
  from the policy's opening cap of 2,500 IMD for the supply. The pool trades at the network fee of
  1.25%; no fee logic exists in these contracts.
- `ScoopFrontPage` runtime is about 11 KB, well under the EIP-170 limit, and contains no
  `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT`. All library calls (`SafeERC20`) are internal, so
  the bytecode has no link placeholders.

### After launch

There are no owner-settable service addresses: the front page needs only the SCOOP token, which
the manifest supplies. The owner has nothing to configure before the site can take bookings. The
owner may call `setPrice` at any time if 2,000,000 SCOOP is not the intended opening price.

### Local or fork deployment

`script/Deploy.s.sol` deploys both contracts for local testing. Its `deploy(Config)` function takes
the owner as an argument and is what the tests call; `run()` reads `SCOOP_OWNER` from the
environment and broadcasts. It is a convenience only. The production launch deploys from the built
bytecode through the ProjectFactory as described by `launch.json`.

## Operational responsibilities

| Who | Responsibility |
| --- | --- |
| Owner | Vet bookings and `veto` before the day starts when a headline or link is unacceptable. Adjust `price` as SCOOP's value moves. Keep the owner key safe; use the two-step transfer to move it. |
| Anyone (site, bot, reader) | Call `burn(day)` once a day has ended so held SCOOP reaches the dEaD address. Nothing breaks if this lags; the SCOOP just waits in the contract. |
| Sponsors | `approve` the front page for `price()` SCOOP, then `book`. A vetoed booking is refunded automatically; there is no other refund path and no cancellation by the sponsor. |
| Website | Read `slotOf(currentDay())` for today's "Sponsored" slot and render headline and link as plain text, never HTML. Use `bookingWindow()` and `bookedDays(first, last)` for the calendar. List a wallet's bookings from `Booked` events filtered by `buyer`, or by scanning `bookedDays` and `slotOf`. |

## Security notes

- Tests passing is not an audit. The contract holds sponsors' SCOOP between booking and burn or
  refund; an independent adversarial review is part of the launch before release.
- Trust assumption: the owner can veto any booking before its day. The refund is always full and
  automatic, so the worst a malicious owner can do is deny a slot, not take funds.
- Tools run: `forge build`, `forge test` (including fuzz), `forge fmt --check`, the Foundry linter
  (warnings about `block.timestamp` comparisons are inherent to day-based scheduling and are
  discussed above). Slither and Mythril were not run in this task.
- The front page never calls `tx.origin`, never delegates, and has no `receive`/`fallback`.

## What the brief asked for that is not here

- The website (front page, archive, issue files under `issues/`, booking UI, swap UI) is the next
  stage; it is not part of the contract deliverable.
- `launch.json` is written by the manifest step, not here.
