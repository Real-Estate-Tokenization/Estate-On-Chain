// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { AssetTokenizationManager } from "./AssetTokenizationManager.sol";
import { IRealEstateRegistry } from "./interfaces/IRealEstateRegistry.sol";
import { IRealEstateRegistry } from "./interfaces/IRealEstateRegistry.sol";
import { IVerifyingOperatorVault } from "./interfaces/IVerifyingOperatorVault.sol";
import { AggregatorV3Interface } from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";

interface IERC20Decimals {
    function decimals() external view returns (uint8);
}

contract TokenizedRealEstate is ERC20 {
    using SafeERC20 for IERC20; 

    error TokenizedRealEstate__ZeroEthSent();
    error TokenizedRealEstate__OnlyAssetTokenizationManager();
    error TokenizedRealEstate__OnlyShareHolder();
    error TokenizedRealEstate__NotEnoughTokensToMint();
    error TokenizedRealEstate__NotEnoughCollateralToCoverEstateTokenDebt();
    error TokenizedRealEstate__OnlyEstateOwner();
    error TokenizedRealEstate__AlreadyOnBaseChain();
    error TokenizedRealEstate__NotOnBaseChain();
    
    address private immutable i_assetTokenizationManager;
    address private immutable i_estateOwner;
    uint256 private s_estateCost;
    uint256 private immutable i_tokenId;
    uint256 private immutable i_percentageToTokenize;
    address private immutable i_paymentToken;
    mapping(address => uint256) private s_collateralDeposited;
    mapping(address => uint256) private s_estateTokenOwnershipMinted;
    mapping(address => mapping(uint256 => uint256)) s_estateTokenOwnershipMintedForAnotherChain;
    mapping(address => uint256) private s_pendingEstateTokenOwnershipToMint;
    uint256 private s_perEstateTokenRewardStored;
    mapping(address estateTokenHolder => uint256 perTokenRewardClaimed) private s_perEstateTokenRewardClaimedBy;
    mapping(address estateTokenHolder => uint256 rewards) private s_claimableRewards;
    // mapping(address => shareHolderInfo) private s_shareHolderToShareHolderInfo;

    uint8 private constant MAX_DECIMALS = 18;
    uint256 private constant TOTAL_TRE_SUPPLY = 1e6 * 1e18;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant COLLATERAL_REQUIRED = 120e18;
    uint256 private constant PERCENT_PRECISION = 100e18;
    uint256 public constant BASE_CHAIN_ID = 43113;

    uint256 private constant CCIP_DEPLOY_TOKENIZED_REAL_ESTATE = 1;
    uint256 private constant CCIP_REQUEST_MINT_TOKENS = 2;

    // struct shareHolderInfo {
    //     uint256 tokenId;
    //     address shareholder;
    //     uint256 sharesAmount;
    //     uint256 fractionalShares;
    //     uint256 rentAmountIn;
    // }

    // Events
    event CollateralDeposited(address depositor, uint256 collateralAmount);
    event EstateOwnershipTokensMinted(address user, uint256 estateOwnershipTokensMinted);
    event RewardsAccumulated(uint256 currRewardsAvailable, uint256 perEstateTokenRewardStored);

    modifier onlyAssetTokenizationManager() {
        if (msg.sender != i_assetTokenizationManager) {
            revert TokenizedRealEstate__OnlyAssetTokenizationManager();
        }
        _;
    }

    modifier onlyEstateOwner() {
        require(msg.sender == i_estateOwner, TokenizedRealEstate__OnlyEstateOwner());
        _;
    }

    modifier updateReward() {
        uint256 reward = ((s_perEstateTokenRewardStored - s_perEstateTokenRewardClaimedBy[msg.sender]) * s_estateTokenOwnershipMinted[msg.sender]) / PRECISION;
        s_perEstateTokenRewardClaimedBy[msg.sender] = s_perEstateTokenRewardStored;
        s_claimableRewards[msg.sender] += reward;
        _;
    }

    constructor(
        address estateOwner,
        uint256 estateCost,
        uint256 percentageToTokenize,
        uint256 tokenId,
        address paymentTokenOnChain
    ) ERC20(
        string.concat("Tokenized Real Estate - ", Strings.toHexString(estateOwner)), 
        string.concat("TRE-", Strings.toHexString(estateOwner))
    ) {
        i_assetTokenizationManager = msg.sender;
        i_estateOwner = estateOwner;
        s_estateCost = estateCost;
        i_percentageToTokenize = percentageToTokenize;
        i_tokenId = tokenId;
        i_paymentToken = paymentTokenOnChain;
    }

    function depositCollateral(uint256 collateralAmount) external {
        s_collateralDeposited[msg.sender] += collateralAmount;
        emit CollateralDeposited(msg.sender, collateralAmount);
        IERC20(i_paymentToken).safeTransferFrom(msg.sender, address(this), collateralAmount);
    }

    /**
     * 
     * @param tokensToMint The amount of tokens to mint for collateral
     * @notice Calculates the amount of collateral with 120% over collateralization, takes collateral from user if not enough, and then mints the partial ownership tokens
     */
    function buyRealEstatePartialOwnershipWithCollateral(uint256 tokensToMint) external updateReward {
        require(block.chainid == BASE_CHAIN_ID, TokenizedRealEstate__NotOnBaseChain());
        uint256 tokensAvailableForMint = TOTAL_TRE_SUPPLY - totalSupply();
        require(tokensToMint <= tokensAvailableForMint, TokenizedRealEstate__NotEnoughTokensToMint());

        uint256 collateralRequired = calculateCollateralRequiredForTokens(tokensToMint + s_estateTokenOwnershipMinted[msg.sender]);

        if (collateralRequired > s_collateralDeposited[msg.sender]) {
            uint256 netCollateralRequired = collateralRequired - s_collateralDeposited[msg.sender];
            s_collateralDeposited[msg.sender] += netCollateralRequired;
            emit CollateralDeposited(msg.sender, netCollateralRequired);
            IERC20(i_paymentToken).safeTransferFrom(msg.sender, address(this), netCollateralRequired);
        }

        emit EstateOwnershipTokensMinted(msg.sender, tokensToMint);
        s_estateTokenOwnershipMinted[msg.sender] += tokensToMint;
        _mint(msg.sender, tokensToMint);
    }

    /**
     * 
     * @param tokensToMint Amount of tokens to mint on non base chain
     * @param mintIfLess If less tokens are available on avalanche chain than requested, then mint all left tokens if available
     */
    function buyRealEstatePartialOwnershipOnNonBaseChain(uint256 tokensToMint, bool mintIfLess, uint256 gasLimit) external {
        // check for enough collateral
        require(_hasEnoughCollateralForTokens(msg.sender, s_estateTokenOwnershipMinted[msg.sender] + s_pendingEstateTokenOwnershipToMint[msg.sender] + tokensToMint), TokenizedRealEstate__NotEnoughCollateralToCoverEstateTokenDebt());
        require(block.chainid != BASE_CHAIN_ID, TokenizedRealEstate__AlreadyOnBaseChain());

        s_pendingEstateTokenOwnershipToMint[msg.sender] += tokensToMint;

        // send a call to avalanche (base) chain to query for enough mint available
        bytes memory _ccipData = abi.encode(CCIP_REQUEST_MINT_TOKENS, msg.sender, tokensToMint, block.chainid, address(this), i_tokenId, mintIfLess);
        AssetTokenizationManager(i_assetTokenizationManager).bridgeRequestFromTRE(_ccipData, gasLimit, BASE_CHAIN_ID, i_tokenId);
    }

    function mintTokensFromAnotherChainRequest(address _user, uint256 _tokensToMint, uint256 _sourceChainId, bool _mintIfLess) external onlyAssetTokenizationManager returns (bool _success, uint256 _tokensMinted) {
        require(block.chainid == BASE_CHAIN_ID, TokenizedRealEstate__NotOnBaseChain());
        uint256 tokensAvailableForMint = TOTAL_TRE_SUPPLY - totalSupply();
                
        if (tokensAvailableForMint < _tokensToMint) {
            _tokensMinted = tokensAvailableForMint;
        }
        else {
            _tokensMinted = _tokensToMint;
        }

        _success = ((_mintIfLess && tokensAvailableForMint > 0) || _tokensMinted == _tokensToMint);

        if (_success) {
            // mint _tokensMinted to _user in another variable storing the chain id on which it is minted
            s_estateTokenOwnershipMintedForAnotherChain[_user][_sourceChainId] += _tokensMinted;
            s_estateTokenOwnershipMinted[_user] += _tokensMinted;
            emit EstateOwnershipTokensMinted(_user, _tokensMinted);
            _mint(_user, _tokensMinted);
        }
    }

    function burnEstateOwnershipTokens(uint256 tokensToBurn) external updateReward {
        s_estateTokenOwnershipMinted[msg.sender] -= tokensToBurn;
        _burn(msg.sender, tokensToBurn);
    }

    // @todo change for base chain and other chain in terms of required collateral
    function withdrawCollateral(uint256 collateralAmount) external {
        s_collateralDeposited[msg.sender] -= collateralAmount;
        require(_hasEnoughCollateral(msg.sender), TokenizedRealEstate__NotEnoughCollateralToCoverEstateTokenDebt());
        IERC20(i_paymentToken).safeTransfer(msg.sender, collateralAmount);
    }

    function claimRewardsForEstateOwnershipTokens() external {
        uint256 reward = ((s_perEstateTokenRewardStored - s_perEstateTokenRewardClaimedBy[msg.sender]) * s_estateTokenOwnershipMinted[msg.sender]) / PRECISION;
        s_perEstateTokenRewardClaimedBy[msg.sender] = s_perEstateTokenRewardStored;
        reward += s_claimableRewards[msg.sender];
        s_claimableRewards[msg.sender] = 0;
        IERC20(i_paymentToken).safeTransfer(msg.sender, reward);
    }

    /**
     * 
     * @param rewardsAvailable The amount of rewards available to be distributed
     * @notice 20% of the rewards sent to verifying operator vault, rest 80% to estate token holders
     */
    function sendRegularEstateRewardsAccumulated(uint256 rewardsAvailable) external onlyEstateOwner {
        uint256 estateHolderRewards = (rewardsAvailable * 80) / 100;
        uint256 nodeOperatorVaultReward = rewardsAvailable - estateHolderRewards;

        address _registry = AssetTokenizationManager(i_assetTokenizationManager).getRegistry();
        address operatorVault = IRealEstateRegistry(_registry).getOperatorVault(AssetTokenizationManager(i_assetTokenizationManager).getEstateInfo(i_tokenId).verifyingOperator);

        IERC20(i_paymentToken).approve(operatorVault, nodeOperatorVaultReward);
        uint256 amountUtilized = IVerifyingOperatorVault(operatorVault).receiveRewards(i_paymentToken, nodeOperatorVaultReward);
        uint256 leftAmount = nodeOperatorVaultReward - amountUtilized;
        estateHolderRewards += leftAmount;
        IERC20(i_paymentToken).approve(operatorVault, 0);

        IERC20(i_paymentToken).safeTransferFrom(msg.sender, address(this), estateHolderRewards);
        s_perEstateTokenRewardStored += ((estateHolderRewards * PRECISION)  / totalSupply());
        emit RewardsAccumulated(estateHolderRewards, s_perEstateTokenRewardStored);
    }

    function _hasEnoughCollateral(address user) internal view returns (bool) {
        uint256 collateralDeposited = s_collateralDeposited[user];
        uint256 collateralRequired = calculateCollateralRequiredForTokens(s_estateTokenOwnershipMinted[user]);
        return collateralDeposited >= collateralRequired;
    }

    /**
     * 
     * @param user address of the user
     * @param tokens the amount of estate tokens for which user collateral has to be checked for enough overcollateralization
     */
    function _hasEnoughCollateralForTokens(address user, uint256 tokens) internal view returns (bool) {
        uint256 collateralDeposited = s_collateralDeposited[user];
        uint256 collateralRequired = calculateCollateralRequiredForTokens(tokens);
        return collateralDeposited >= collateralRequired;
    }

    function calculateCollateralRequiredForTokens(uint256 estateTokens) public view returns (uint256) {
        uint256 tokenPriceInPaymentToken = (getPerEstateTokenPrice() * estateTokens) / PRECISION;
        uint256 collateralRequired = (COLLATERAL_REQUIRED * tokenPriceInPaymentToken) / PERCENT_PRECISION;
        return collateralRequired;
    }

    function getCurrentOnChainTokenizedAmount() public view returns (uint256) {
        return (i_percentageToTokenize * s_estateCost) / PERCENT_PRECISION;
    }

    function getPerEstateTokenPrice() public view returns (uint256) {
        uint256 currentEstateCostOnChain = getCurrentOnChainTokenizedAmount();
        return (currentEstateCostOnChain * PRECISION) / TOTAL_TRE_SUPPLY;
    }

    function getEstateOwner() external view returns (address) {
        return i_estateOwner;
    }

    function getEstateCost() external view returns (uint256) {
        return s_estateCost;
    }

    function getPercentageToTokenize() external view returns (uint256) {
        return i_percentageToTokenize;
    }

    function getTokenId() external view returns (uint256) {
        return i_tokenId;
    }

    function getPaymentToken() external view returns (address) {
        return i_paymentToken;
    }

    function getAssetTokenizationManager() external view returns (address) {
        return i_assetTokenizationManager;
    }
}
