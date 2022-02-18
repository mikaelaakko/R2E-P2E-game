// SPDX-License-Identifier: MIT LICENSE

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "./GameOfRisk.sol";
import "./THRONE.sol";

contract Battle is Ownable, IERC721Receiver, Pausable {
    // maximum alpha score for a WW
    uint8 public constant MAX_ALPHA = 8;

    // struct to store a stake's token, owner, and earning values
    struct Stake {
        uint16 tokenId;
        uint80 value;
        address owner;
    }

    event TokenStaked(address owner, uint256 tokenId, uint256 value);
    event KnightClaimed(uint256 tokenId, uint256 earned, bool unstaked);
    event WWClaimed(uint256 tokenId, uint256 earned, bool unstaked);

    // reference to the GameOfRisk NFT contract
    GameOfRisk game;
    // reference to the $THRONE contract for minting $THRONE earnings
    THRONE throne;

    // maps tokenId to stake
    mapping(uint256 => Stake) public battle;
    // maps alpha to all WW stakes with that alpha
    mapping(uint256 => Stake[]) public pack;
    // tracks location of each WW in Pack
    mapping(uint256 => uint256) public packIndices;

    // // maps tokenIds by owner
    // //counter for each staker
    mapping(address => mapping(uint256 => uint256)) public tokenIDsByWallet;
    mapping(address => uint256) public counterByWallet;
    mapping(uint256 => uint256) public _ownedTokensIndex;

    // total alpha scores staked
    uint256 public totalAlphaStaked = 0;
    // any rewards distributed when no WW are staked
    uint256 public unaccountedRewards = 0;
    // amount of $THRONE due for each alpha point staked
    uint256 public thronePerAlpha = 0;

    // knight earn 10000 $THRONE per day
    uint256 public DAILY_THRONE_RATE = 10000 ether;
    // knight must have 2 days worth of $THRONE to unstake or else it's too cold
    uint256 public MINIMUM_TO_EXIT = 2 days;
    // WW take a 20% tax on all $THRONE claimed
    uint256 public constant THRONE_CLAIM_TAX_PERCENTAGE = 20;
    // there will only ever be (roughly) 2.4 billion $THRONE earned through staking
    uint256 public constant MAXIMUM_GLOBAL_THRONE = 2400000000 ether;

    // amount of $THRONE earned so far
    uint256 public totalThroneEarned;
    // number of Knight staked in the Battle
    uint256 public totalKnightStaked;
    // number of WW staked in the Battle
    uint256 public totalWWStaked;
    // the last time $THRONE was claimed
    uint256 public lastClaimTimestamp;

    // emergency rescue to allow unstaking without any checks but without $THRONE
    bool public rescueEnabled = false;

    bool private _reentrant = false;

    modifier nonReentrant() {
        require(!_reentrant, "No reentrancy");
        _reentrant = true;
        _;
        _reentrant = false;
    }

    /**
     * @param _game reference to the GameOfRisk NFT contract
     * @param _throne reference to the $THRONE token
     */
    constructor(GameOfRisk _game, THRONE _throne) {
        game = _game;
        throne = _throne;
    }

    /***STAKING */

    /**
     * adds Knight and WW to the Battle and Pack
     * @param account the address of the staker
     * @param tokenIds the IDs of the Knight and WW to stake
     */
    function addManyToBattleAndPack(address account, uint16[] calldata tokenIds)
        external
        nonReentrant
    {
        require(
            (account == _msgSender() && account == tx.origin) ||
                _msgSender() == address(game),
            "DONT GIVE YOUR TOKENS AWAY"
        );

        for (uint256 i = 0; i < tokenIds.length; i++) {
            if (tokenIds[i] == 0) {
                continue;
            }

            if (_msgSender() != address(game)) {
                // dont do this step if its a mint + stake
                require(
                    game.ownerOf(tokenIds[i]) == _msgSender(),
                    "AINT YO TOKEN"
                );
                game.transferFrom(_msgSender(), address(this), tokenIds[i]);
            }

            if (isKnight(tokenIds[i])) _addKnightToBattle(account, tokenIds[i]);
            else _addWWToPack(account, tokenIds[i]);
        }
    }

    /**
     * adds a single Knight to the Battle
     * @param account the address of the staker
     * @param tokenId the ID of the Knight to add to the Battle
     */
    function _addKnightToBattle(address account, uint256 tokenId)
        internal
        whenNotPaused
        _updateEarnings
    {
        battle[tokenId] = Stake({
            owner: account,
            tokenId: uint16(tokenId),
            value: uint80(block.timestamp)
        });
        addTokenToOwnerEnumeration(account, tokenId);
        totalKnightStaked += 1;
        emit TokenStaked(account, tokenId, block.timestamp);
    }

    /**
     * adds a single WW to the Pack
     * @param account the address of the staker
     * @param tokenId the ID of the WW to add to the Pack
     */
    function _addWWToPack(address account, uint256 tokenId) internal {
        uint256 alpha = _alphaForWW(tokenId);
        totalAlphaStaked += alpha;
        // Portion of earnings ranges from 8 to 5
        packIndices[tokenId] = pack[alpha].length;
        // Store the location of the WW in the Pack
        pack[alpha].push(
            Stake({
                owner: account,
                tokenId: uint16(tokenId),
                value: uint80(thronePerAlpha)
            })
        );
        addTokenToOwnerEnumeration(account, tokenId);
        totalWWStaked++;
        // Add the WW to the Pack
        emit TokenStaked(account, tokenId, thronePerAlpha);
    }

    /***CLAIMING / UNSTAKING */

    /**
     * realize $THRONE earnings and optionally unstake tokens from the Battle / Pack
     * to unstake a knight it will require it has 2 days worth of $THRONE unclaimed
     * @param tokenIds the IDs of the tokens to claim earnings from
     * @param unstake whether or not to unstake ALL of the tokens listed in tokenIds
     */
    function claimManyFromBattleAndPack(
        uint16[] calldata tokenIds,
        bool unstake
    ) external nonReentrant whenNotPaused _updateEarnings {
        require(msg.sender == tx.origin, "Only EOA");
        uint256 owed = 0;
        for (uint256 i = 0; i < tokenIds.length; i++) {
            if (isKnight(tokenIds[i]))
                owed += _claimKnightFromBattle(tokenIds[i], unstake);
            else owed += _claimWWFromPack(tokenIds[i], unstake);
        }
        if (owed == 0) return;
        throne.mint(_msgSender(), owed);
    }

    /**
     * realize $THRONE earnings for a single Knight and optionally unstake it
     * if not unstaking, pay a 20% tax to the staked WW
     * if unstaking, there is a 50% chance all $THRONE is stolen
     * @param tokenId the ID of the Knight to claim earnings from
     * @param unstake whether or not to unstake the Knight
     * @return owed - the amount of $THRONE earned
     */
    function _claimKnightFromBattle(uint256 tokenId, bool unstake)
        internal
        returns (uint256 owed)
    {
        Stake memory stake = battle[tokenId];
        require(stake.owner == _msgSender(), "SWIPER, NO SWIPING");
        require(
            !(unstake && block.timestamp - stake.value < MINIMUM_TO_EXIT),
            "GONNA BE COLD WITHOUT TWO DAY'S THRONE"
        );
        if (totalThroneEarned < MAXIMUM_GLOBAL_THRONE) {
            owed =
                ((block.timestamp - stake.value) * DAILY_THRONE_RATE) /
                1 days;
        } else if (stake.value > lastClaimTimestamp) {
            owed = 0;
            // $THRONE production stopped already
        } else {
            owed =
                ((lastClaimTimestamp - stake.value) * DAILY_THRONE_RATE) /
                1 days;
            // stop earning additional $THRONE if it's all been earned
        }
        if (unstake) {
            if (random(tokenId) & 1 == 1) {
                // 50% chance of all $THRONE stolen
                _payWWTax(owed);
                owed = 0;
            }
            game.transferFrom(address(this), _msgSender(), tokenId);
            removeTokenFromOwnerEnumeration(_msgSender(), tokenId);
            // send back Knight
            delete battle[tokenId];
            totalKnightStaked -= 1;
        } else {
            _payWWTax((owed * THRONE_CLAIM_TAX_PERCENTAGE) / 100);
            // percentage tax to staked WW
            owed = (owed * (100 - THRONE_CLAIM_TAX_PERCENTAGE)) / 100;
            // remainder goes to Knight owner
            battle[tokenId] = Stake({
                owner: _msgSender(),
                tokenId: uint16(tokenId),
                value: uint80(block.timestamp)
            });
            // reset stake
        }
        emit KnightClaimed(tokenId, owed, unstake);
    }

    /**
     * realize $THRONE earnings for a single WW and optionally unstake it
     * WW earn $THRONE proportional to their Alpha rank
     * @param tokenId the ID of the WW to claim earnings from
     * @param unstake whether or not to unstake the WW
     * @return owed - the amount of $THRONE earned
     */
    function _claimWWFromPack(uint256 tokenId, bool unstake)
        internal
        returns (uint256 owed)
    {
        require(
            game.ownerOf(tokenId) == address(this),
            "AINT A PART OF THE PACK"
        );
        uint256 alpha = _alphaForWW(tokenId);
        Stake memory stake = pack[alpha][packIndices[tokenId]];
        require(stake.owner == _msgSender(), "SWIPER, NO SWIPING");
        owed = (alpha) * (thronePerAlpha - stake.value);
        // Calculate portion of tokens based on Alpha
        if (unstake) {
            totalAlphaStaked -= alpha;
            // Remove Alpha from total staked
            game.transferFrom(address(this), _msgSender(), tokenId);
            removeTokenFromOwnerEnumeration(_msgSender(), tokenId);
            totalWWStaked--;
            // Send back WW
            Stake memory lastStake = pack[alpha][pack[alpha].length - 1];
            pack[alpha][packIndices[tokenId]] = lastStake;
            // Shuffle last WW to current position
            packIndices[lastStake.tokenId] = packIndices[tokenId];
            pack[alpha].pop();
            // Remove duplicate
            delete packIndices[tokenId];
            // Delete old mapping
        } else {
            pack[alpha][packIndices[tokenId]] = Stake({
                owner: _msgSender(),
                tokenId: uint16(tokenId),
                value: uint80(thronePerAlpha)
            });
            // reset stake
        }
        emit WWClaimed(tokenId, owed, unstake);
    }

    /**
     * emergency unstake tokens
     * @param tokenIds the IDs of the tokens to claim earnings from
     */
    function rescue(uint256[] calldata tokenIds) external nonReentrant {
        require(rescueEnabled, "RESCUE DISABLED");
        uint256 tokenId;
        Stake memory stake;
        Stake memory lastStake;
        uint256 alpha;
        for (uint256 i = 0; i < tokenIds.length; i++) {
            tokenId = tokenIds[i];
            if (isKnight(tokenId)) {
                stake = battle[tokenId];
                require(stake.owner == _msgSender(), "SWIPER, NO SWIPING");
                game.transferFrom(address(this), _msgSender(), tokenId);
                removeTokenFromOwnerEnumeration(_msgSender(), tokenId);
                // send back Knight
                delete battle[tokenId];
                totalKnightStaked -= 1;
                emit KnightClaimed(tokenId, 0, true);
            } else {
                alpha = _alphaForWW(tokenId);
                stake = pack[alpha][packIndices[tokenId]];
                require(stake.owner == _msgSender(), "SWIPER, NO SWIPING");
                totalAlphaStaked -= alpha;
                // Remove Alpha from total staked
                game.transferFrom(address(this), _msgSender(), tokenId);
                removeTokenFromOwnerEnumeration(_msgSender(), tokenId);
                // Send back WW
                lastStake = pack[alpha][pack[alpha].length - 1];
                pack[alpha][packIndices[tokenId]] = lastStake;
                // Shuffle last WW to current position
                packIndices[lastStake.tokenId] = packIndices[tokenId];
                pack[alpha].pop();
                // Remove duplicate
                delete packIndices[tokenId];
                // Delete old mapping
                emit WWClaimed(tokenId, 0, true);
            }
        }
    }

    /***ACCOUNTING */

    /**
     * add $THRONE to claimable pot for the Pack
     * @param amount $THRONE to add to the pot
     */
    function _payWWTax(uint256 amount) internal {
        if (totalAlphaStaked == 0) {
            // if there's no staked WW
            unaccountedRewards += amount;
            // keep track of $THRONE due to WW
            return;
        }
        // makes sure to include any unaccounted $THRONE
        thronePerAlpha += (amount + unaccountedRewards) / totalAlphaStaked;
        unaccountedRewards = 0;
    }

    /**
     * tracks $THRONE earnings to ensure it stops once 2.4 billion is eclipsed
     */
    modifier _updateEarnings() {
        if (totalThroneEarned < MAXIMUM_GLOBAL_THRONE) {
            totalThroneEarned +=
                ((block.timestamp - lastClaimTimestamp) *
                    totalKnightStaked *
                    DAILY_THRONE_RATE) /
                1 days;
            lastClaimTimestamp = block.timestamp;
        }
        _;
    }

    function calculateRewards(uint256 tokenId)
        external
        view
        returns (uint256 owed)
    {
        if (isKnight(tokenId)) {
            Stake memory stake = battle[tokenId];
            if (totalThroneEarned < MAXIMUM_GLOBAL_THRONE) {
                owed =
                    ((block.timestamp - stake.value) * DAILY_THRONE_RATE) /
                    1 days;
            } else if (stake.value > lastClaimTimestamp) {
                owed = 0; // $Throne production stopped already
            } else {
                owed =
                    ((lastClaimTimestamp - stake.value) * DAILY_THRONE_RATE) /
                    1 days; // stop earning additional $THRONE if it's all been earned
            }
        } else {
            uint256 alpha = _alphaForWW(tokenId);
            Stake memory stake = pack[alpha][packIndices[tokenId]];
            owed = (alpha) * (thronePerAlpha - stake.value);
        }
    }

    /***ADMIN */

    function setSettings(uint256 rate, uint256 exit) external onlyOwner {
        MINIMUM_TO_EXIT = exit;
        DAILY_THRONE_RATE = rate;
    }

    /**
     * allows owner to enable "rescue mode"
     * simplifies accounting, prioritizes tokens out in emergency
     */
    function setRescueEnabled(bool _enabled) external onlyOwner {
        rescueEnabled = _enabled;
    }

    /**
     * enables owner to pause / unpause minting
     */
    function setPaused(bool _paused) external onlyOwner {
        if (_paused) _pause();
        else _unpause();
    }

    /***READ ONLY */

    /**
     * checks if a token is a Knight
     * @param tokenId the ID of the token to check
     * @return knight - whether or not a token is a Knight
     */
    function isKnight(uint256 tokenId) public view returns (bool knight) {
        (knight, , , , , , ) = game.tokenTraits(tokenId);
    }

    /**
     * gets the alpha score for a WW
     * @param tokenId the ID of the WW to get the alpha score for
     * @return the alpha score of the WW (5-8)
     */
    function _alphaForWW(uint256 tokenId) internal view returns (uint8) {
        (, , , , , , uint8 alphaIndex) = game.tokenTraits(tokenId);
        return MAX_ALPHA - alphaIndex;
        // alpha index is 0-3
    }

    /***OWNER DATA */

    function addTokenToOwnerEnumeration(address to, uint256 tokenId) internal {
        uint256 length = counterByWallet[to];
        tokenIDsByWallet[to][length] = tokenId;
        _ownedTokensIndex[tokenId] = length;
        counterByWallet[to]++;
    }

    function removeTokenFromOwnerEnumeration(address from, uint256 tokenId)
        internal
    {
        // To prevent a gap in from's tokens array, we store the last token in the index of the token to delete, and
        // then delete the last slot (swap and pop).
        uint256 tokenIndex;
        for (uint256 i = 0; i < counterByWallet[from] - 1; i++) {
            if (tokenIDsByWallet[from][i] == tokenId) tokenIndex = i;
        }
        uint256 lastTokenIndex = counterByWallet[from] - 1;
        // When the token to delete is the last token, the swap operation is unnecessary
        if (tokenIndex != lastTokenIndex) {
            uint256 lastTokenId = tokenIDsByWallet[from][lastTokenIndex];

            tokenIDsByWallet[from][tokenIndex] = lastTokenId; // Move the last token to the slot of the to-delete token
            _ownedTokensIndex[lastTokenId] = tokenIndex; // Update the moved token's index
        }

        // This also deletes the contents at the last position of the array
        counterByWallet[from]--;
        delete _ownedTokensIndex[tokenId];
        delete tokenIDsByWallet[from][lastTokenIndex];
    }

    function walletOfOwner(address _owner)
        public
        view
        returns (uint256[] memory)
    {
        uint256 ownerTokenCount = counterByWallet[_owner];
        uint256[] memory tokenIds = new uint256[](ownerTokenCount);
        for (uint256 i; i < ownerTokenCount; i++) {
            // tokenIds[i] = game.tokenOfOwnerByIndex(_owner, i);
            tokenIds[i] = tokenIDsByWallet[_owner][i];
        }
        return tokenIds;
    }

    /*********************************************** */

    /**
     * chooses a random WW knight when a newly minted token is stolen
     * @param seed a random value to choose a WW from
     * @return the owner of the randomly selected WW knight
     */
    function randomWWOwner(uint256 seed) external view returns (address) {
        if (totalAlphaStaked == 0) return address(0x0);
        uint256 bucket = (seed & 0xFFFFFFFF) % totalAlphaStaked;
        // choose a value from 0 to total alpha staked
        uint256 cumulative;
        seed >>= 32;
        // loop through each bucket of WW with the same alpha score
        for (uint256 i = MAX_ALPHA - 3; i <= MAX_ALPHA; i++) {
            cumulative += pack[i].length * i;
            // if the value is not inside of that bucket, keep going
            if (bucket >= cumulative) continue;
            // get the address of a random WW with that alpha score
            return pack[i][seed % pack[i].length].owner;
        }
        return address(0x0);
    }

    /**
     * generates a pseudorandom number
     * @param seed a value ensure different outcomes for different sources in the same block
     * @return a pseudorandom value
     */
    function random(uint256 seed) internal view returns (uint256) {
        return
            uint256(
                keccak256(
                    abi.encodePacked(
                        tx.origin,
                        blockhash(block.number - 1),
                        block.timestamp,
                        seed,
                        totalKnightStaked,
                        totalAlphaStaked,
                        lastClaimTimestamp
                    )
                )
            ) ^ game.randomSource().seed();
    }

    function onERC721Received(
        address,
        address from,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
        require(from == address(0x0), "Cannot send tokens to Barn directly");
        return IERC721Receiver.onERC721Received.selector;
    }
}
