// SPDX-License-Identifier: MIT LICENSE

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "./interfaces/IGameOfRisk.sol";
import "./interfaces/IBattle.sol";
import "./interfaces/ITraits.sol";
import "./interfaces/ITHRONE.sol";
import "./interfaces/ISeed.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

contract GameOfRisk is IGameOfRisk, ERC721Enumerable, Ownable, Pausable {
    // mint price
    uint256 public MINT_PRICE = 1.45 ether;
    uint256 public MAX_MINT = 15;
    uint256 public MAX_WL_MINT = 15;
    uint256 public MAX_GIVEAWAY = 50;
    uint256 public GIVEAWAY_COUNT;
    // max number of tokens that can be minted - 50000 in production
    uint256 public immutable MAX_TOKENS;
    // number of tokens that can be claimed for free - 20% of MAX_TOKENS
    uint256 public PAID_TOKENS;
    // number of tokens have been minted so far
    uint16 public minted;
    uint256 public wwStolen;
    uint256 public knightStolen;
    uint256 public knightCount;
    uint256 public wwCount;

    address public multisigWallet = 0xB13f2d052acE8554b9593813C4243469a6C7325d;

    bytes32 public merkleRoot;

    bool public isWhiteListActive = false;

    mapping(address => uint256) public whitelistedGen0;

    mapping(address => bool) public whitelistedGen1;
    // mapping from tokenId to a struct containing the token's traits
    mapping(uint256 => KnightWW) public tokenTraits;
    // mapping from hashed(tokenTrait) to the tokenId it's associated with
    // used to ensure there are no duplicates
    mapping(uint256 => uint256) public existingCombinations;
    // reference to the Battle for choosing random WW knight
    IBattle public battle;
    // reference to $THRONE for burning on mint
    ITHRONE public throne;
    // reference to Traits
    ITraits public traits;

    ISeed public randomSource;

    bool private _reentrant = false;
    bool private stakingActive = true;

    modifier nonReentrant() {
        require(!_reentrant, "No reentrancy");
        _reentrant = true;
        _;
        _reentrant = false;
    }

    /**
     * instantiates contract and rarity tables
     */
    constructor(
        ITHRONE _throne,
        ITraits _traits,
        uint256 _maxTokens
    ) ERC721("Game of risk", "GOR") {
        throne = _throne;
        traits = _traits;

        MAX_TOKENS = _maxTokens;
        PAID_TOKENS = _maxTokens / 5;
    }

    function setRandomSource(ISeed _seed) external onlyOwner {
        randomSource = _seed;
    }

    /***EXTERNAL */

    /**
     * mint a token - 90% Knight, 10% WW
     * The first 20% are free to claim, the remaining cost $THRONE
     */
    function mint(uint256 amount, bool stake)
        external
        payable
        nonReentrant
        whenNotPaused
    {
        require(!stake || stakingActive, "Staking not activated");

        require(tx.origin == _msgSender(), "Only EOA");
        require(minted + amount <= MAX_TOKENS, "All tokens minted");
        require(amount > 0 && amount <= MAX_MINT, "Invalid mint amount");

        if (minted < PAID_TOKENS) {
            require(
                minted + amount <= PAID_TOKENS,
                "All tokens on-sale already sold"
            );
            require(amount * MINT_PRICE == msg.value, "Invalid payment amount");
        } else {
            require(msg.value == 0);
        }

        uint256 totalThroneCost = 0;
        uint16[] memory tokenIds = new uint16[](amount);
        address[] memory owners = new address[](amount);
        uint256 seed;
        uint256 firstMinted = minted;

        for (uint256 i = 0; i < amount; i++) {
            minted++;
            seed = random(minted);
            randomSource.update(minted ^ seed);
            generate(minted, seed);
            address recipient = selectRecipient(seed);
            totalThroneCost += mintCost(minted);
            if (!stake || recipient != _msgSender()) {
                owners[i] = recipient;
                if (recipient != _msgSender()) {
                    tokenTraits[minted].isKnight ? knightStolen++ : wwStolen++;
                }
            } else {
                tokenIds[i] = minted;
                owners[i] = address(battle);
            }
        }

        if (totalThroneCost > 0) throne.burn(_msgSender(), totalThroneCost);

        for (uint256 i = 0; i < owners.length; i++) {
            uint256 id = firstMinted + i + 1;
            if (!stake || owners[i] != _msgSender()) {
                _safeMint(owners[i], id);
            }
        }
        if (stake) battle.addManyToBattleAndPack(_msgSender(), tokenIds);
    }

    //*****WhiteList Access *****//

    function whiteListMint(uint256 amount, bytes32[] calldata _merkleProof)
        external
        payable
        nonReentrant
    {
        require(tx.origin == _msgSender(), "Only EOA");
        require(isWhiteListActive == true, "WhiteList Access not active !");

        bytes32 leaf = keccak256(abi.encodePacked(msg.sender));

        require(
            MerkleProof.verify(_merkleProof, merkleRoot, leaf),
            "You are not registered on WhiteList"
        );

        if (minted < PAID_TOKENS) {
            require(
                whitelistedGen0[_msgSender()] + amount <= MAX_WL_MINT,
                "Maximum whitelist amount reached"
            );
            require(
                minted + amount <= PAID_TOKENS,
                "All tokens on-sale already sold"
            );
            require(amount * MINT_PRICE == msg.value, "Invalid payment amount");

            uint16[] memory tokenIds = new uint16[](amount);
            uint256 seed;
            uint256 firstMinted = minted;

            for (uint256 i = 0; i < amount; i++) {
                whitelistedGen0[_msgSender()]++;
                minted++;
                seed = random(minted);
                randomSource.update(minted ^ seed);
                generate(minted, seed);
            }

            for (uint256 i = 0; i < amount; i++) {
                uint256 id = firstMinted + i + 1;
                _safeMint(_msgSender(), id);
            }
        } else {
            require(msg.value == 0);
            require(
                whitelistedGen1[_msgSender()] = false,
                "Only one FreeMint acces bro"
            );

            whitelistedGen1[_msgSender()] = true;

            uint256 _amount;

            _amount = randomSource.generateAmount();

            uint16[] memory tokenIds = new uint16[](_amount);

            uint256 seed;
            uint256 firstMinted = minted;

            for (uint256 i = 0; i < _amount; i++) {
                minted++;
                seed = random(minted);
                randomSource.update(minted ^ seed);
                generate(minted, seed);
            }

            for (uint256 i = 0; i < _amount; i++) {
                uint256 id = firstMinted + i + 1;
                _safeMint(_msgSender(), id);
            }
        }
    }

    function Giveaway(address account, uint256 amount) external {
        require(_msgSender() == address(owner()), "Wut ?");
        require(GIVEAWAY_COUNT + amount <= MAX_GIVEAWAY, "giveAway limit !");

        uint16[] memory tokenIds = new uint16[](amount);
        uint256 seed;
        uint256 firstMinted = minted;

        for (uint256 i = 0; i < amount; i++) {
            GIVEAWAY_COUNT++;
            minted++;
            seed = random(minted);
            randomSource.update(minted ^ seed);
            generate(minted, seed);
        }

        for (uint256 i = 0; i < amount; i++) {
            uint256 id = firstMinted + i + 1;
            _safeMint(account, id);
        }
    }

    /**
     * the first 20% are paid in AVAX
     * the next 20% are 20000 $THRONE
     * the next 40% are 40000 $THRONE
     * the final 20% are 80000 $THRONE
     * @param tokenId the ID to check the cost of to mint
     * @return the cost of the given token ID
     */
    function mintCost(uint256 tokenId) public view returns (uint256) {
        if (tokenId <= PAID_TOKENS) return 0;
        if (tokenId <= (MAX_TOKENS * 2) / 5) return 20000 ether;
        if (tokenId <= (MAX_TOKENS * 4) / 5) return 40000 ether;
        return 60000 ether;
    }

    function transferFrom(
        address from,
        address to,
        uint256 tokenId
    ) public virtual override nonReentrant {
        // Hardcode the Battle's approval so that users don't have to waste gas approving
        if (_msgSender() != address(battle))
            require(
                _isApprovedOrOwner(_msgSender(), tokenId),
                "ERC721: transfer caller is not owner nor approved"
            );
        _transfer(from, to, tokenId);
    }

    /***INTERNAL */

    /**
     * generates traits for a specific token, checking to make sure it's unique
     * @param tokenId the id of the token to generate traits for
     * @param seed a pseudorandom 256 bit number to derive traits from
     * @return t - a struct of traits for the given token ID
     */
    function generate(uint256 tokenId, uint256 seed)
        internal
        returns (KnightWW memory t)
    {
        t = selectTraits(seed);
        if (existingCombinations[structToHash(t)] == 0) {
            tokenTraits[tokenId] = t;
            existingCombinations[structToHash(t)] = tokenId;
            t.isKnight == true ? knightCount++ : wwCount++;
            return t;
        }
        return generate(tokenId, random(seed));
    }

    /**
     * uses A.J. Walker's Alias algorithm for O(1) rarity table lookup
     * ensuring O(1) instead of O(n) reduces mint cost by more than 50%
     * probability & alias tables are generated off-chain beforehand
     * @param seed portion of the 256 bit seed to remove trait correlation
     * @param traitType the trait type to select a trait for
     * @return the ID of the randomly selected trait
     */
    function selectTrait(uint16 seed, uint8 traitType)
        internal
        view
        returns (uint8)
    {
        return traits.selectTrait(seed, traitType);
    }

    /**
     * the first 20% (ETH purchases) go to the minter
     * the remaining 80% have a 10% chance to be given to a random staked whiteWalkers
     * @param seed a random value to select a recipient from
     * @return the address of the recipient (either the minter or the WW Knight's owner)
     */
    function selectRecipient(uint256 seed) public view returns (address) {
        if (minted <= PAID_TOKENS || ((seed >> 245) % 10) != 0) {
            //console.log("Recipent is owner with Randomer : ", seed >> 245);
            return _msgSender();
        }
        // top 10 bits haven't been used
        address knight = battle.randomWWOwner(seed >> 144);
        //console.log("STOLEN_TOKEN_BY_WW_ALERTE !!! ", seed >> 144);
        // 144 bits reserved for trait selection
        if (knight == address(0x0)) return _msgSender();
        return knight;
    }

    /**
     * selects the species and all of its traits based on the seed value
     * @param seed a pseudorandom 256 bit number to derive traits from
     * @return t -  a struct of randomly selected traits
     */
    function selectTraits(uint256 seed)
        internal
        view
        returns (KnightWW memory t)
    {
        t.isKnight = (seed & 0xFFFF) % 10 != 0;
        uint8 shift = t.isKnight ? 0 : 10;

        seed >>= 16;
        t.background = selectTrait(uint16(seed & 0xFFFF), 0 + shift);

        seed >>= 16;
        t.body = selectTrait(uint16(seed & 0xFFFF), 1 + shift);

        seed >>= 16;
        t.head = selectTrait(uint16(seed & 0xFFFF), 2 + shift);

        seed >>= 16;
        t.leftHand = selectTrait(uint16(seed & 0xFFFF), 3 + shift);

        seed >>= 16;
        t.rightHand = selectTrait(uint16(seed & 0xFFFF), 4 + shift);

        // seed >>= 16;
        // t.headgear = selectTrait(uint16(seed & 0xFFFF), 5 + shift);

        seed >>= 16;
        if (!t.isKnight) {
            //     t.neckGear = selectTrait(uint16(seed & 0xFFFF), 6 + shift);
            t.alphaIndex = selectTrait(uint16(seed & 0xFFFF), 5 + shift);
            //console.log("ALPHA : ", t.alphaIndex);
        }
    }

    /**
     * converts a struct to a 256 bit hash to check for uniqueness
     * @param s the struct to pack into a hash
     * @return the 256 bit hash of the struct
     */
    function structToHash(KnightWW memory s) internal pure returns (uint256) {
        return
            uint256(
                keccak256(
                    abi.encodePacked(
                        s.isKnight,
                        s.background,
                        s.body,
                        s.head,
                        s.leftHand,
                        s.rightHand,
                        s.alphaIndex
                    )
                )
            );
    }

    /**
     * generates a pseudorandom number
     * @param seed a value ensure different outcomes for different sources in the same block
     * @return a pseudorandom value
     */
    function random(uint256 seed) internal view returns (uint256) {
        //console.log("Fetch New RANDOM with seed : ", seed);
        return
            uint256(
                keccak256(
                    abi.encodePacked(
                        tx.origin,
                        blockhash(block.number - 1),
                        block.timestamp,
                        seed
                    )
                )
            ) ^ randomSource.seed();
    }

    /***READ */

    function getTokenTraits(uint256 tokenId)
        external
        view
        override
        returns (KnightWW memory)
    {
        return tokenTraits[tokenId];
    }

    function getPaidTokens() external view override returns (uint256) {
        return PAID_TOKENS;
    }

    /***ADMIN */

    /**
     * called after deployment so that the contract can get random WW knight
     * @param _battle the address of the Battle
     */
    function setBattle(address _battle) external onlyOwner {
        battle = IBattle(_battle);
    }

    /**
     * allows Multisig to withdraw funds from minting
     */
    function withdraw() external onlyOwner {
        multisigWallet.call{value: address(this).balance}("");
    }

    /**
     * updates the number of tokens for sale
     */
    function setPaidTokens(uint256 _paidTokens) external onlyOwner {
        PAID_TOKENS = _paidTokens;
    }

    /**
     * enables owner to pause / unpause minting
     */
    function setPaused(bool _paused) external onlyOwner {
        if (_paused) _pause();
        else _unpause();
    }

    function setWhitelistActive(bool _wlEnd) external onlyOwner {
        isWhiteListActive = _wlEnd;
    }

    function setMerkleRoot(bytes32 root) public onlyOwner {
        merkleRoot = root;
    }

    function walletOfOwner(address _owner)
        public
        view
        returns (uint256[] memory)
    {
        uint256 ownerTokenCount = balanceOf(_owner);
        uint256[] memory tokenIds = new uint256[](ownerTokenCount);
        for (uint256 i; i < ownerTokenCount; i++) {
            tokenIds[i] = tokenOfOwnerByIndex(_owner, i);
        }
        return tokenIds;
    }

    /***RENDER */

    function hasWhitelisted(bytes32[] calldata _merkleProof)
        public
        view
        returns (bool)
    {
        bytes32 leaf = keccak256(abi.encodePacked(msg.sender));
        return MerkleProof.verify(_merkleProof, merkleRoot, leaf);
    }

    function tokenURI(uint256 tokenId)
        public
        view
        override
        returns (string memory)
    {
        require(
            _exists(tokenId),
            "ERC721Metadata: URI query for nonexistent token"
        );
        return traits.tokenURI(tokenId);
    }

    function changePrice(uint256 _price) public onlyOwner {
        MINT_PRICE = _price;
    }

    function setStakingActive(bool _staking) public onlyOwner {
        stakingActive = _staking;
    }

    function setTraits(ITraits addr) public onlyOwner {
        traits = addr;
    }
}
