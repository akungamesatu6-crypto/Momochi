// SPDX-License-Identifier: MIT
// MCHI — BEP-20 bonus token for Momo Mochi paid mints.
// Economics (user-confirmed 2026-11-13 — "Biasa 3000 $MCHI Dream
// 12.000 special 27.000"):
//   Total supply 1,000,000,000 MCHI (18 decimals), fixed at deploy —
//   NO further minting ever. Bonus pool 540,000,000 MCHI is held by this
//   token contract itself; the remaining 460,000,000 MCHI is minted to the
//   owner at deploy (treasury — owner-controlled, not part of the bonus
//   pool). Every PAID Momo Mochi mint accrues MCHI for the minter's
//   wallet BY THE PIECE ACTUALLY DRAWN, recorded by the NFT contract
//   via accrue() (only the NFT contract — set by the owner with
//   setMinter() after the NFT deploys — can accrue):
//   Regular piece 3,000 / Dream piece 12,000. Free mints accrue 0.
//   Burning a complete 9-piece set for a special accrues 27,000.
//   Max 120,000 MCHI per wallet (covers realistic max 26x3,000 +
//   12,000 Dream + 27,000 special = 117,000);
//   accrue() enforces both the per-wallet cap and the pool cap
//   (total accrued can never exceed 540,000,000).
//   Worst case the whole paid deck (2,222 mints) pays out at most
//   2,072x3,000 + 150x12,000 = 8,016,000 MCHI, plus 9 specials x
//   27,000 = 243,000 — total 8,259,000 MCHI < 540,000,000 pool.
//   Claims are retroactive: claim() pays the caller's claimable balance;
//   claimFor(address) pays a beneficiary's claimable balance and can be
//   called by any wallet (e.g. an agent claiming for its user).
//   claimable(address) shows what is waiting. No staking, no tax, no
//   pausing, no blacklist — plain ERC-20 + accrual ledger.
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title MCHI
contract MochiToken is ERC20, Ownable {
    uint256 public constant BONUS_POOL = 540_000_000 ether; // held by this contract
    uint256 public constant MAX_BONUS_PER_WALLET = 120_000 ether; // realistic max 117,000

    address public minter; // the Momo Mochi NFT contract; set by owner after NFT deploy
    uint256 public totalAccrued; // sum of all accrue() amounts; never exceeds BONUS_POOL

    mapping(address => uint256) public accrued; // lifetime bonus earned
    mapping(address => uint256) public claimed; // lifetime bonus claimed

    event Accrued(address indexed wallet, uint256 amount, uint256 totalAccruedForWallet);
    event Claimed(address indexed wallet, uint256 amount);
    event MinterSet(address indexed minter);

    error NotMinter();
    error NothingToClaim();
    error OverPoolCap();
    error OverWalletCap();

    constructor(address owner_) ERC20("MCHI", "MCHI") Ownable(owner_) {
        // Pool stays in this contract for claims; remainder goes to the owner.
        _mint(address(this), BONUS_POOL);
        _mint(owner_, 460_000_000 ether);
    }

    /// @notice Claimable MCHI for a wallet (accrued minus already claimed).
    function claimable(address wallet) public view returns (uint256) {
        return accrued[wallet] - claimed[wallet];
    }

    /// @notice Record a bonus for a wallet. Only the NFT contract can call this.
    function accrue(address wallet, uint256 amount) external {
        if (msg.sender != minter) revert NotMinter();
        if (totalAccrued + amount > BONUS_POOL) revert OverPoolCap();
        if (accrued[wallet] + amount > MAX_BONUS_PER_WALLET) revert OverWalletCap();
        accrued[wallet] += amount;
        totalAccrued += amount;
        emit Accrued(wallet, amount, accrued[wallet]);
    }

    /// @notice Claim your own waiting MCHI.
    function claim() external {
        _claim(msg.sender);
    }

    /// @notice Claim a beneficiary's waiting MCHI to that beneficiary. Callable by anyone.
    function claimFor(address beneficiary) external {
        _claim(beneficiary);
    }

    function _claim(address wallet) internal {
        uint256 amount = claimable(wallet);
        if (amount == 0) revert NothingToClaim();
        claimed[wallet] += amount;
        _transfer(address(this), wallet, amount);
        emit Claimed(wallet, amount);
    }

    /// @notice Point accrual at the Momo Mochi NFT contract (called once, by owner, after NFT deploy).
    function setMinter(address minter_) external onlyOwner {
        minter = minter_;
        emit MinterSet(minter_);
    }
}
