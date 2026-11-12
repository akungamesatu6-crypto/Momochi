// SPDX-License-Identifier: MIT
// Test mocks for MiChan: a fake Agent ID registry, a generic contract
// caller (EOA-gate test), and a mock ERC-721 WITHOUT royalty support
// (marketplace fallback-path test).
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";

contract MockAgentID {
    mapping(address => uint256) private _bal;

    function mint(address a) external {
        _bal[a] = 1;
    }

    function mintBatch(address[] calldata addrs) external {
        for (uint256 i; i < addrs.length; i++) {
            _bal[addrs[i]] = 1;
        }
    }

    function balanceOf(address a) external view returns (uint256) {
        return _bal[a];
    }
}

contract MintCaller {
    function callMintFree(address nft) external {
        (bool ok, ) = nft.call(abi.encodeWithSignature("mintFree()"));
        require(ok, "call failed");
    }
}

/// @notice Mock ERC-721 WITHOUT any royalty support, for testing the
///  marketplace's hardcoded 5% fallback path.
contract MockERC721NoRoyalty is ERC721 {
    constructor() ERC721("Mock Cat No Royalty", "MOCKN") {}

    function mint(address to, uint256 tokenId) external {
        _safeMint(to, tokenId);
    }
}
