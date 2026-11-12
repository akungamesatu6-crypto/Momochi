// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title MomoMochiMarketplace — fixed-price escrow marketplace for Momo Mochi only
/// @notice 0% platform fee, forever. No fee setter, no owner backdoor.
/// @dev Royalty handling (same verified pattern as the HATCHIEggy, MiChan
///   and PanduAGENT marketplaces, deployed 2026-11-08):
///   - The Momo Mochi NFT implements royaltyInfo(tokenId, salePrice) via
///     ERC-2981: it returns 2% to the owner wallet
///     0x36F3D56eAD5D1D6C2434F94DeFcEF732C5C3CbD2.
///   - The marketplace must NEVER gate on supportsInterface (some of the
///     user's NFT contracts revert on ERC-165). It calls royaltyInfo
///     directly via a low-level staticcall and falls back to a hardcoded
///     2% to the owner wallet if that call fails or returns address(0).
interface IERC2981 {
    function royaltyInfo(uint256 tokenId, uint256 salePrice) external view returns (address receiver, uint256 royaltyAmount);
}

contract MomoMochiMarketplace is ReentrancyGuard, IERC721Receiver {
    IERC721 public immutable nft;

    // Royalty fallback: Momo Mochi pays 2% to the owner wallet.
    address public constant ROYALTY_FALLBACK_RECEIVER = 0x36F3D56eAD5D1D6C2434F94DeFcEF732C5C3CbD2;
    uint256 public constant ROYALTY_FALLBACK_BPS = 200; // 2%

    struct Listing {
        address seller;
        uint256 price;
        bool active;
    }

    mapping(uint256 => Listing) public listings;
    uint256[] private _listedIds;
    // tokenId => index in _listedIds, +1 (0 means not listed)
    mapping(uint256 => uint256) private _listedIndex;

    event Listed(uint256 indexed tokenId, address indexed seller, uint256 price);
    event Sale(uint256 indexed tokenId, address indexed seller, address indexed buyer, uint256 price, uint256 royaltyPaid);
    event Cancelled(uint256 indexed tokenId, address indexed seller);
    event PriceUpdated(uint256 indexed tokenId, uint256 newPrice);

    constructor(address nft_) {
        require(nft_ != address(0), "zero nft");
        nft = IERC721(nft_);
    }

    /// @notice List a token: seller must have approved the marketplace first
    ///  (setApprovalForAll). The NFT is pulled into escrow.
    function list(uint256 tokenId, uint256 price) external nonReentrant {
        require(price > 0, "price 0");
        require(!listings[tokenId].active, "already listed");
        require(nft.ownerOf(tokenId) == msg.sender, "not owner");
        listings[tokenId] = Listing({seller: msg.sender, price: price, active: true});
        _listedIndex[tokenId] = _listedIds.length + 1;
        _listedIds.push(tokenId);
        nft.safeTransferFrom(msg.sender, address(this), tokenId);
        emit Listed(tokenId, msg.sender, price);
    }

    /// @notice Buy a listed token. Exact payment required — overpayment reverts.
    function buy(uint256 tokenId) external payable nonReentrant {
        Listing memory l = listings[tokenId];
        require(l.active, "not listed");
        require(msg.sender != l.seller, "seller cannot buy");
        require(msg.value == l.price, "exact price required");

        (address royaltyReceiver, uint256 royaltyAmount) = _royalty(tokenId, l.price);
        _removeListing(tokenId);

        if (royaltyAmount > 0) {
            (bool okR, ) = payable(royaltyReceiver).call{value: royaltyAmount}("");
            require(okR, "royalty pay failed");
        }
        uint256 sellerAmount = l.price - royaltyAmount;
        (bool okS, ) = payable(l.seller).call{value: sellerAmount}("");
        require(okS, "seller pay failed");

        nft.safeTransferFrom(address(this), msg.sender, tokenId);
        emit Sale(tokenId, l.seller, msg.sender, l.price, royaltyAmount);
    }

    /// @notice Cancel a listing: NFT returns to the seller.
    function cancel(uint256 tokenId) external nonReentrant {
        Listing memory l = listings[tokenId];
        require(l.active, "not listed");
        require(l.seller == msg.sender, "not seller");
        _removeListing(tokenId);
        nft.safeTransferFrom(address(this), msg.sender, tokenId);
        emit Cancelled(tokenId, msg.sender);
    }

    /// @notice Change the price of your own listing.
    function updatePrice(uint256 tokenId, uint256 newPrice) external {
        require(newPrice > 0, "price 0");
        Listing storage l = listings[tokenId];
        require(l.active, "not listed");
        require(l.seller == msg.sender, "not seller");
        l.price = newPrice;
        emit PriceUpdated(tokenId, newPrice);
    }

    /// @notice All active listing IDs (one call for the frontend).
    function getListedIds() external view returns (uint256[] memory) {
        return _listedIds;
    }

    function getListing(uint256 tokenId) external view returns (address seller, uint256 price, bool active) {
        Listing memory l = listings[tokenId];
        return (l.seller, l.price, l.active);
    }

    /// @notice Accept escrowed NFTs.
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    /// @dev Read royalty via ERC-2981 when available; fall back to hardcoded
    ///  2% to the owner wallet when the call fails, returns address(0), or
    ///  returns more than the price. Never uses supportsInterface.
    function _royalty(uint256 tokenId, uint256 price) internal view returns (address receiver, uint256 amount) {
        (bool ok, bytes memory ret) = address(nft).staticcall(
            abi.encodeWithSelector(IERC2981.royaltyInfo.selector, tokenId, price)
        );
        if (ok && ret.length == 64) {
            (address r, uint256 a) = abi.decode(ret, (address, uint256));
            if (r != address(0) && a <= price) {
                return (r, a);
            }
        }
        return (ROYALTY_FALLBACK_RECEIVER, (price * ROYALTY_FALLBACK_BPS) / 10000);
    }

    function _removeListing(uint256 tokenId) internal {
        uint256 idxPlusOne = _listedIndex[tokenId];
        require(idxPlusOne != 0, "not indexed");
        uint256 idx = idxPlusOne - 1;
        uint256 lastIdx = _listedIds.length - 1;
        if (idx != lastIdx) {
            uint256 lastId = _listedIds[lastIdx];
            _listedIds[idx] = lastId;
            _listedIndex[lastId] = idx + 1;
        }
        _listedIds.pop();
        delete _listedIndex[tokenId];
        delete listings[tokenId];
    }
}
