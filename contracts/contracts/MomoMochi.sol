// SPDX-License-Identifier: MIT
// Momo Mochi — BSC BEP-721, a puzzle-piece NFT. Collect 9 pieces, burn
// the set, claim 1 of only 9 special NFTs.
// Spec (user-confirmed 2026-11-13, main chat):
//   Supply 2,222 pieces + 9 special = 2,231 total token ids.
//   RANDOM token ids (swap-and-pop single deck, NOT VRF).
//   9 piece types by token id (metadata — 9 artworks + 1 special):
//   Cheerful 1-259 / Wink 260-518 / Hug 519-777 / Sleepy 778-1036 /
//   Star 1037-1295 / Carrot 1296-1554 / Game 1555-1813 /
//   Heart 1814-2072 / Dream 2073-2222 (150, rarest key piece).
//   Special "Completed Puzzle" 2223-2231 (9), mintable ONLY via
//   assemble() — never via normal mint.
//   PRICE LADDER (equal tiers of 9 paid each, user 2026-11-13):
//   #1 FREE, #2-10 @ 0.0003, #11-19 @ 0.0006, #20-28 @ 0.0009 BNB.
//   Max 28/wallet (1 free + 27 paid), max cost 0.0162 BNB.
//   Per-transaction mint cap 28 (full wallet in one tx).
//   GATE (user 2026-11-13): BOTH free AND paid mints need an Agent ID
//   (msg.sender == tx.origin + SPACE ID Agent ID registry balance > 0).
//   Public wallets CAN connect to the page to browse — they just cannot
//   mint without an Agent ID.
//   $MCHI BONUS (user 2026-11-13): per PAID mint by piece drawn —
//   regular piece 3,000 / Dream piece 12,000. Free mints accrue 0.
//   Burn a complete 9-piece set for a special: 27,000 $MCHI.
//   Max 120,000 $MCHI per wallet (covers realistic max 26x3,000 +
//   12,000 Dream + 27,000 special = 117,000).
//   ASSEMBLE: burn 9 pieces (one of each type, caller passes the 9
//   token ids) -> mint 1 special (next id 2223-2231, cap 9 total).
//   Random draw does NOT guarantee a complete set — duplicates happen,
//   trade them on the marketplace. That challenge is intentional.
//   Mint money: forwarded to the owner (project wallet) in the same tx;
//   the contract does not hold mint revenue.
//   Royalty 2% (ERC-2981, user 2026-11-13 — NOT the usual 5%).
//   Owner can ONLY: open/close mint, set base URI, withdraw stuck funds.
//   Prices, supply and limits are immutable after deploy.
//   baseURI: https://puzzlehave.fun/metadata/
//   Language: Chinese primary + Japanese + English (page only).
//   Official X: TBD.
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/common/ERC2981.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IAgentID {
    function balanceOf(address) external view returns (uint256);
}

interface IMchiToken {
    function accrue(address wallet, uint256 amount) external;
}

/// @title Momo Mochi
contract MomoMochi is ERC721, ERC2981, Ownable, ReentrancyGuard {
    IAgentID public immutable AGENT_ID;
    IMchiToken public immutable TOKEN;

    uint256 public constant MAX_SUPPLY = 2231; // 2,222 pieces + 9 special
    uint256 public constant MAX_PER_WALLET = 28;
    uint256 public constant FREE_PER_WALLET = 1;
    uint256 public constant MAX_PAID_PER_WALLET = 27;
    uint256 public constant MAX_PER_TX = 28;
    uint256 public constant DECK_SIZE = 2222;
    uint256 public constant SPECIAL_CAP = 9;
    uint256 public constant SPECIAL_BASE = 2223; // special ids 2223-2231

    // $MCHI bonus per paid mint, by piece drawn.
    uint256 public constant BONUS_REGULAR = 3_000 ether;
    uint256 public constant BONUS_DREAM = 12_000 ether;
    uint256 public constant BONUS_SPECIAL = 27_000 ether;

    uint256 public totalMinted;
    uint256 public paidMinted;
    uint256 public freeMinted;
    uint256 public specialMinted;
    bool public mintOpen;
    string private _base;

    uint256 private _deckRemaining = DECK_SIZE;
    mapping(uint256 => uint256) private _deckAtIndex; // 0 = identity (id = index + 1)

    mapping(address => uint256) public mintedOf;
    mapping(address => uint256) public freeMintedOf;
    mapping(address => uint256) public paidMintedOf;

    event Minted(address indexed minter, uint256 indexed id, bool paid, uint256 priceWei);
    event Assembled(address indexed owner, uint256 indexed specialId, uint256[9] burnedIds);

    error NotAgent();
    error MintClosed();
    error SoldOut();
    error OverLimit();
    error Underpaid(uint256 required);
    error FreeClaimed();
    error NotOwner();
    error BadSet();

    constructor(
        string memory baseURI_,
        address owner_,
        address agentId_,
        address token_
    ) ERC721("Momo Mochi", "MOMO") Ownable(owner_) {
        _base = baseURI_;
        AGENT_ID = IAgentID(agentId_);
        TOKEN = IMchiToken(token_);
        mintOpen = false; // mint starts CLOSED until owner opens it
        _setDefaultRoyalty(owner_, 200); // 2%
    }

    modifier onlyAgent() {
        if (msg.sender != tx.origin || AGENT_ID.balanceOf(msg.sender) == 0) revert NotAgent();
        if (!mintOpen) revert MintClosed();
        _;
    }

    /// @notice BNB cost of mint number `n` (1 = free, 2-28 = paid ladder).
    function priceFor(uint256 n) public pure returns (uint256) {
        if (n <= 1) return 0;
        if (n <= 10) return 0.0003 ether;
        if (n <= 19) return 0.0006 ether;
        return 0.0009 ether;
    }

    /// @notice BNB cost of paid-mint number `n` (1-27). Paid #1-9 @
    /// 0.0003, #10-18 @ 0.0006, #19-27 @ 0.0009. Priced by PAID count
    /// (not total mints) so a wallet pays the right ladder step whether
    /// it claims the free mint first or mints paid first.
    function priceForPaid(uint256 n) public pure returns (uint256) {
        if (n <= 9) return 0.0003 ether;
        if (n <= 18) return 0.0006 ether;
        return 0.0009 ether;
    }

    /// @notice BNB cost for `qty` further PAID mints by `wallet`.
    function quotePaidFor(address wallet, uint256 qty) public view returns (uint256) {
        if (qty == 0 || qty > MAX_PER_TX) revert OverLimit();
        if (paidMintedOf[wallet] + qty > MAX_PAID_PER_WALLET) revert OverLimit();
        if (mintedOf[wallet] + qty > MAX_PER_WALLET) revert OverLimit();
        if (_deckRemaining < qty) revert SoldOut();
        uint256 start = paidMintedOf[wallet] + 1; // next PAID mint number
        uint256 total;
        for (uint256 i; i < qty; i++) total += priceForPaid(start + i);
        return total;
    }

    /// @notice $MCHI bonus for a piece token id (Dream pays 4x regular).
    function bonusForId(uint256 id) public pure returns (uint256) {
        if (id >= 2073 && id <= 2222) return BONUS_DREAM; // Dream
        return BONUS_REGULAR;
    }

    /// @notice Piece name for a token id (for the page/metadata).
    function pieceOf(uint256 id) public pure returns (string memory) {
        if (id <= 259) return "Cheerful";
        if (id <= 518) return "Wink";
        if (id <= 777) return "Hug";
        if (id <= 1036) return "Sleepy";
        if (id <= 1295) return "Star";
        if (id <= 1554) return "Carrot";
        if (id <= 1813) return "Game";
        if (id <= 2072) return "Heart";
        if (id <= 2222) return "Dream";
        return "Completed Puzzle"; // 2223-2231 special
    }

    /// @notice Rarity for a token id.
    function rarityOf(uint256 id) public pure returns (string memory) {
        if (id <= 2072) return "Common";
        if (id <= 2222) return "Rare"; // Dream
        return "Legendary"; // special
    }

    /// @notice Piece type index 0-8 for a piece id (Cheerful=0 ... Dream=8).
    function pieceIndex(uint256 id) public pure returns (uint256) {
        if (id <= 259) return 0;
        if (id <= 518) return 1;
        if (id <= 777) return 2;
        if (id <= 1036) return 3;
        if (id <= 1295) return 4;
        if (id <= 1554) return 5;
        if (id <= 1813) return 6;
        if (id <= 2072) return 7;
        if (id <= 2222) return 8;
        revert BadSet(); // special ids have no piece type
    }

    function totalSupply() external view returns (uint256) {
        return totalMinted;
    }

    function exists(uint256 id) external view returns (bool) {
        return _ownerOf(id) != address(0);
    }

    function deckRemaining() external view returns (uint256) {
        return _deckRemaining;
    }

    /// @notice Draw one token id from the deck (swap-and-pop).
    function _draw(uint256 seed) internal returns (uint256) {
        uint256 index = seed % _deckRemaining;
        uint256 tokenId = _deckAtIndex[index] == 0 ? index + 1 : _deckAtIndex[index];
        uint256 lastIndex = _deckRemaining - 1;
        uint256 lastTokenId = _deckAtIndex[lastIndex] == 0 ? lastIndex + 1 : _deckAtIndex[lastIndex];
        _deckAtIndex[index] = lastTokenId;
        _deckRemaining -= 1;
        return tokenId;
    }

    /// @notice FREE lane: the wallet's one free piece. Agent ID ONLY.
    /// No payment, accrues 0 $MCHI. Draws from the same deck as paid.
    function mintFree() external nonReentrant onlyAgent {
        if (freeMintedOf[msg.sender] >= FREE_PER_WALLET) revert FreeClaimed();
        if (totalMinted + 1 > MAX_SUPPLY) revert SoldOut();
        if (_deckRemaining == 0) revert SoldOut();
        uint256 seed = uint256(
            keccak256(abi.encodePacked(blockhash(block.number - 1), block.timestamp, msg.sender, totalMinted, uint256(0)))
        );
        uint256 id = _draw(seed);
        totalMinted++;
        freeMinted++;
        freeMintedOf[msg.sender]++;
        mintedOf[msg.sender]++;
        _safeMint(msg.sender, id);
        emit Minted(msg.sender, id, false, 0);
    }

    /// @notice PAID lane: mint `qty` pieces. Agent ID ONLY (public wallets
    /// can connect to the page to browse, but cannot mint without an
    /// Agent ID). Price follows the ladder by mint number:
    /// #2-10 @ 0.0003, #11-19 @ 0.0006, #20-28 @ 0.0009 BNB.
    /// Each paid mint accrues $MCHI by the piece actually drawn
    /// (regular 3,000 / Dream 12,000).
    function mintPaid(uint256 qty) external payable nonReentrant onlyAgent {
        if (qty == 0 || qty > MAX_PER_TX) revert OverLimit();
        if (paidMintedOf[msg.sender] + qty > MAX_PAID_PER_WALLET) revert OverLimit();
        if (mintedOf[msg.sender] + qty > MAX_PER_WALLET) revert OverLimit();
        if (totalMinted + qty > MAX_SUPPLY) revert SoldOut();
        if (_deckRemaining < qty) revert SoldOut();
        uint256 cost = quotePaidFor(msg.sender, qty);
        if (msg.value < cost) revert Underpaid(cost);

        uint256 totalBonus;
        uint256 start = paidMintedOf[msg.sender] + 1; // next PAID mint number
        for (uint256 i; i < qty; i++) {
            uint256 seed = uint256(
                keccak256(abi.encodePacked(blockhash(block.number - 1), block.timestamp, msg.sender, totalMinted, i))
            );
            uint256 id = _draw(seed);
            totalMinted++;
            paidMinted++;
            totalBonus += bonusForId(id);
            _safeMint(msg.sender, id);
            emit Minted(msg.sender, id, true, priceForPaid(start + i));
        }
        paidMintedOf[msg.sender] += qty;
        mintedOf[msg.sender] += qty;

        TOKEN.accrue(msg.sender, totalBonus);

        // Mint money goes straight to the project wallet.
        if (cost > 0) {
            (bool ok, ) = owner().call{value: cost}("");
            require(ok, "forward");
        }
        if (msg.value > cost) {
            (bool ok, ) = msg.sender.call{value: msg.value - cost}("");
            require(ok, "refund");
        }
    }

    /// @notice ASSEMBLE: burn a complete 9-piece set (one of each type)
    /// to mint 1 special NFT (next id 2223-2231, cap 9 total).
    /// Caller passes the 9 token ids (one per piece type, any order).
    /// Accrues 27,000 $MCHI. No BNB cost — the 9 burned pieces are the price.
    function assemble(uint256[9] calldata ids) external nonReentrant whenOpen {
        if (specialMinted >= SPECIAL_CAP) revert SoldOut();
        if (totalMinted + 1 > MAX_SUPPLY) revert SoldOut();
        // Verify: caller owns all 9, and they cover all 9 piece types exactly once.
        bool[9] memory seen;
        for (uint256 i; i < 9; i++) {
            uint256 id = ids[i];
            if (id < 1 || id > 2222) revert BadSet();
            if (ownerOf(id) != msg.sender) revert NotOwner();
            uint256 idx = pieceIndex(id);
            if (seen[idx]) revert BadSet();
            seen[idx] = true;
        }
        for (uint256 i; i < 9; i++) _burn(ids[i]);
        uint256 specialId = SPECIAL_BASE + specialMinted;
        specialMinted++;
        totalMinted++;
        mintedOf[msg.sender]++; // the special counts toward the wallet total
        _safeMint(msg.sender, specialId);
        TOKEN.accrue(msg.sender, BONUS_SPECIAL);
        emit Assembled(msg.sender, specialId, ids);
    }

    modifier whenOpen() {
        if (!mintOpen) revert MintClosed();
        _;
    }

    /// @notice tokenURI returns the metadata file immediately, from mint time.
    function tokenURI(uint256 id) public view override returns (string memory) {
        _requireOwned(id);
        return string.concat(_base, Strings.toString(id));
    }

    // ── owner: only these switches exist ──
    function setMintOpen(bool v) external onlyOwner {
        mintOpen = v;
    }

    function setBaseURI(string calldata b) external onlyOwner {
        _base = b;
    }

    function withdraw() external onlyOwner nonReentrant {
        (bool ok, ) = owner().call{value: address(this).balance}("");
        require(ok, "withdraw");
    }

    function supportsInterface(bytes4 i) public view override(ERC721, ERC2981) returns (bool) {
        return super.supportsInterface(i);
    }
}
