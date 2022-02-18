// SPDX-License-Identifier: MIT LICENSE

pragma solidity ^0.8.0;

interface IGameOfRisk {
    // struct to store each token's traits
    struct KnightWW {
        bool isKnight;
        uint8 background;
        uint8 body;
        uint8 head;
        uint8 leftHand;
        uint8 rightHand;
        uint8 alphaIndex;
    }

    function getPaidTokens() external view returns (uint256);

    function getTokenTraits(uint256 tokenId)
        external
        view
        returns (KnightWW memory);
}
