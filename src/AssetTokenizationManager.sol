// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import { TokenizedRealEstate } from "./TokenizedRealEstate.sol";
import { EstateAcrossChain } from "./Bridge/EstateAcrossChain.sol";
import { EstateVerification } from "./Computation/EstateVerification.sol";
import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IRealEstateRegistry } from "./interfaces/IRealEstateRegistry.sol";
import { IVerifyingOperatorVault } from "./interfaces/IVerifyingOperatorVault.sol";
import { Base64 } from "@openzeppelin/contracts/utils/Base64.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { AggregatorV3Interface } from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import { CcipRequestTypes } from "./CcipRequestTypes.sol";

interface IERC20Decimals {
    function decimals() external view returns (uint8);
}

contract AssetTokenizationManager is ERC721, EstateAcrossChain, CcipRequestTypes {
    // libraries
    using SafeERC20 for IERC20;

    // Errors
    error AssetTokenizationManager__NotAssetOwner();
    error AssetTokenizationManager__OnlyOneTokenizedRealEstatePerUser();
    error AssetTokenizationManager__NotAuthorized();

    // Structs
    struct EstateInfo {
        address estateOwner;
        uint256 percentageToTokenize;
        address tokenizedRealEstate;
        uint256 estateCost;
        uint256 accumulatedRewards;
        address verifyingOperator;
    }
    
    // variables
    address private s_registry;
    mapping(uint256 tokenId => EstateInfo) private s_tokenidToEstateInfo;
    mapping(address estateOwner => address tokenizedRealEstate) private s_estateOwnerToTokenizedRealEstate;
    mapping(address estateOwner => uint256 collateralAmount) private s_getCollateralDepositedBy;
    uint256 private s_tokenCounter;
    uint256[] private s_supportedChains;
    mapping(uint256 chainId => bool) private s_isSupportedChain;
    uint256 private immutable i_baseChain;
    mapping(uint256 => mapping(uint256 => address)) private s_tokenIdToChainIdToTokenizedRealEstate;
    EstateVerification private immutable i_estateVerification;

    uint256 private constant ESTATE_OWNER_COLLATERAL_USD = 200;

    // events
    event TokenizedRealEstateDeployed(uint256 tokenId, address tokenizedRealEstate, address estateOwner);

    // modifiers
    modifier onlyEstateOwner(uint256 tokenId) {
        if (msg.sender != s_tokenidToEstateInfo[tokenId].estateOwner) {
            revert AssetTokenizationManager__NotAssetOwner();
        }
        _;
    }

    // constructor
    /// @param _baseChainId here this chainId is of the avalanche chain
    constructor(
        address _ccipRouter, 
        address _link, 
        address _functionsRouter, 
        uint256 _baseChainId, 
        uint256[] memory _supportedChains, 
        uint64[] memory _chainSelectors,
        string memory _estateVerificationSource,
        bytes memory _encryptedSecretsUrls,
        uint64 _subId,
        uint32 _gasLimit,
        bytes32 _donID
    ) ERC721("Asset Tokenization Manager", "ATM") EstateAcrossChain(_ccipRouter, _link, _supportedChains, _chainSelectors) {
        i_baseChain = _baseChainId;
        
        for (uint256 i; i < _supportedChains.length; i++) {
            s_supportedChains.push(_supportedChains[i]);
            s_isSupportedChain[_supportedChains[i]] = true;
        }

        i_estateVerification = new EstateVerification(_functionsRouter, _baseChainId, _supportedChains, _estateVerificationSource, _encryptedSecretsUrls, _subId, _gasLimit, _donID, msg.sender);
    }

    // functions
    function setRegistry(address _registry) external onlyOwner {
        s_registry = _registry;
        i_estateVerification.setRegistry(_registry);
    }

    function bridgeRequestFromTRE(bytes memory _data, uint256 _gasLimit, uint256 _destChainId, uint256 _tokenId) external {
        address tokenizedRealEstate = s_tokenidToEstateInfo[_tokenId].tokenizedRealEstate;
        require(msg.sender == tokenizedRealEstate, AssetTokenizationManager__NotAuthorized());
        bridgeRequest(_destChainId, _data, _gasLimit);
    }

    function fulfillCreateEstateRequest(EstateVerification.TokenizeFunctionCallRequest memory _request, bytes memory _response) external {
        require(msg.sender == address(i_estateVerification), AssetTokenizationManager__NotAuthorized());
        require(balanceOf(_request.estateOwner) == 0, AssetTokenizationManager__OnlyOneTokenizedRealEstatePerUser());

        uint256 estateCost;
        uint256 percentageToTokenize;
        bool isApproved;
        bytes memory _saltBytes;
        bytes32 _salt;
        address _paymentToken = _request.paymentToken;
        address _verifyingOperator;
        uint256 _tokenId = s_tokenCounter;

        (estateCost, percentageToTokenize, isApproved, _saltBytes, _verifyingOperator) = abi.decode(_response, (uint256, uint256, bool, bytes, address));
        _salt = bytes32(_saltBytes);

        require(isApproved, AssetTokenizationManager__NotAssetOwner());

        _mint(_request.estateOwner, _tokenId);
        s_tokenCounter++;

        address _operatorVault = IRealEstateRegistry(s_registry).getOperatorVault(_verifyingOperator);
        address tokenizedRealEstate = address(new TokenizedRealEstate{ salt: _salt }(_request.estateOwner, estateCost, percentageToTokenize, _tokenId, _paymentToken));
        IVerifyingOperatorVault(_operatorVault).addNewTokenizedRealEstate(tokenizedRealEstate);
        s_tokenIdToChainIdToTokenizedRealEstate[_tokenId][block.chainid] = tokenizedRealEstate;

        s_tokenidToEstateInfo[_tokenId] = EstateInfo({
            estateOwner: _request.estateOwner,
            percentageToTokenize: percentageToTokenize,
            tokenizedRealEstate: tokenizedRealEstate,
            estateCost: estateCost,
            accumulatedRewards: 0,
            verifyingOperator: _verifyingOperator
        });

        s_estateOwnerToTokenizedRealEstate[_request.estateOwner] = tokenizedRealEstate;

        // take collateral from estate owner
        // collateral deposited only on base (avalanche) chain
        _processCollateralFromEstateOwner(_request.estateOwner, _paymentToken);

        // @audit should be use tokenId from counter or instead use tokenid from salt
        address[] memory _deploymentAddrForOtherChains = _getAllChainDeploymentAddr(_request.estateOwnerAcrossChain, estateCost, percentageToTokenize, _tokenId, _salt, _paymentToken, _request.chainsToDeploy);

        for (uint256 i = 1; i < _request.chainsToDeploy.length; i++) {
            address _paymentTokenOnChain = IRealEstateRegistry(s_registry).getAcceptedTokenOnChain(_paymentToken, _request.chainsToDeploy[i]);
            bytes memory bridgeData = abi.encode(CCIP_DEPLOY_TOKENIZED_REAL_ESTATE, _request.estateOwnerAcrossChain[i], estateCost, percentageToTokenize, _tokenId, _salt, _paymentTokenOnChain, _request.chainsToDeploy, _deploymentAddrForOtherChains);
            uint256 _chainId = _request.chainsToDeploy[i];
            s_tokenIdToChainIdToTokenizedRealEstate[_tokenId][_chainId] = _deploymentAddrForOtherChains[i];
            bridgeRequest(_chainId, bridgeData, 26_00_000);
        }
    }

    function _processCollateralFromEstateOwner(address _estateOwner, address _paymentToken) internal {
        address _priceFeed = IRealEstateRegistry(s_registry).getDataFeedForToken(_paymentToken);
        uint256 paymentTokenDecimals;

        if (_paymentToken == address(0)) {
            paymentTokenDecimals = 18;
        }
        else {    
            paymentTokenDecimals = IERC20Decimals(_paymentToken).decimals();
        }

        uint256 decimals = AggregatorV3Interface(_priceFeed).decimals();
        (, int256 answer, , ,) = AggregatorV3Interface(_priceFeed).latestRoundData();
        uint256 collateralAmount = ESTATE_OWNER_COLLATERAL_USD * (10 ** (paymentTokenDecimals + decimals)) / uint256(answer);

        s_getCollateralDepositedBy[_estateOwner] = collateralAmount;
        IERC20(_paymentToken).safeTransferFrom(_estateOwner, address(this), collateralAmount);
    }

    // function handleTestCrossChainMessage(bytes32 _messageId, bytes memory _data) external {
    //     _handleCrossChainMessage(_messageId, _data);
    // }

    function _handleCrossChainMessage(bytes32 /*_messageId*/, bytes memory _data) internal override {
        uint256 ccipRequestType;
        
        assembly {
            ccipRequestType := mload(add(_data, 0x20))
        }

        if (ccipRequestType == CCIP_DEPLOY_TOKENIZED_REAL_ESTATE) {
            _handleDeployTokenizedRealEstate(_data);
        }
        else if (ccipRequestType == CCIP_REQUEST_MINT_TOKENS) {
            _handleMintTokenRequestFromNonBaseChain(_data);
        }
        else if (ccipRequestType == CCIP_MINT_REQUEST_ACK) {
            _handleMintTokenAckRequest(_data);
        }
        else if (ccipRequestType == CCIP_REQUEST_BURN_TOKENS) {
            _handleBurnTokenRequestFromNonBaseChain(_data);
        }
    }

    function _handleDeployTokenizedRealEstate(bytes memory _data) internal {
        (
            ,
            address _estateOwner,
            uint256 _estateCost,
            uint256 _percentageToTokenize,
            uint256 _tokenId,
            bytes32 _salt,
            address _paymentToken,
            uint256[] memory _chainsToDeploy,
            address[] memory _deploymentAddrForOtherChains
        ) = abi.decode(_data, (uint256, address, uint256, uint256, uint256, bytes32, address, uint256[], address[]));

        _mint(_estateOwner, _tokenId);
        s_tokenCounter++;

        address tokenizedRealEstate = address(new TokenizedRealEstate{ salt: _salt }(_estateOwner, _estateCost, _percentageToTokenize, _tokenId, _paymentToken));
        emit TokenizedRealEstateDeployed(_tokenId, tokenizedRealEstate, _estateOwner);

        s_tokenidToEstateInfo[_tokenId] = EstateInfo({
            estateOwner: _estateOwner,
            percentageToTokenize: _percentageToTokenize,
            tokenizedRealEstate: tokenizedRealEstate,
            estateCost: _estateCost,
            accumulatedRewards: 0,
            verifyingOperator: address(0)
        });

        s_estateOwnerToTokenizedRealEstate[_estateOwner] = tokenizedRealEstate;

        for (uint256 i = 0; i < _chainsToDeploy.length; i++) {
            s_tokenIdToChainIdToTokenizedRealEstate[_tokenId][_chainsToDeploy[i]] = _deploymentAddrForOtherChains[i];
        }
    }

    function _handleMintTokenRequestFromNonBaseChain(bytes memory _data) internal {
        (
            ,
            address _user,
            uint256 _tokensToMint,
            uint256 _sourceChainId,
            /* address sourceTokenizedRealEstate */,
            uint256 _tokenId,
            bool _mintIfLess
        ) = abi.decode(_data, (uint256, address, uint256, uint256, address, uint256, bool));

        // call the tokenized real estate on the current chain, i.e. base chain (avalanche chain)
        TokenizedRealEstate _tre = TokenizedRealEstate(s_tokenIdToChainIdToTokenizedRealEstate[_tokenId][block.chainid]);
        (bool _success, uint256 _tokensMinted) = _tre.mintTokensFromAnotherChainRequest(_user, _tokensToMint, _sourceChainId, _mintIfLess);

        // prepare message to send on the source chain
        bytes memory _ccipData = abi.encode(CCIP_MINT_REQUEST_ACK, _user, _tokensToMint, _tokensMinted, _tokenId, _success);
        bridgeRequest(_sourceChainId, _ccipData, 600_000);
    }

    function _handleMintTokenAckRequest(bytes memory _data) internal {
        (
            /* ccipMesageType */, 
            address _user, 
            uint256 _tokensToMint,
            uint256 _tokensMinted, 
            uint256 _tokenId, 
            bool _success
        ) = abi.decode(_data, (uint256, address, uint256, uint256, uint256, bool));
        TokenizedRealEstate(s_tokenidToEstateInfo[_tokenId].tokenizedRealEstate).fulfillBuyRealEstateOwnershipOnNonBaseChain(_user, _tokensToMint, _tokensMinted, _success);
    }

    function _handleBurnTokenRequestFromNonBaseChain(bytes memory _data) internal {
        (
            /* CCIP_REQUEST_BURN_TOKENS */, 
            address user, 
            uint256 tokensToBurn, 
            uint256 sourceChainId, 
            /* address sourceTokenizedRealEstate */, 
            uint256 tokenId
        ) = abi.decode(_data, (uint256, address, uint256, uint256, address, uint256));
        TokenizedRealEstate _tre = TokenizedRealEstate(s_tokenIdToChainIdToTokenizedRealEstate[tokenId][block.chainid]);
        _tre.burnTokensFromAnotherChainRequest(user, tokensToBurn, sourceChainId);
    }

    function _getAllChainDeploymentAddr(address[] memory _estateOwner, uint256 _estateCost, uint256 _percentageToTokenize, uint256 _tokenId, bytes32 _salt, address _paymentToken, uint256[] memory _chainsToDeploy) internal view returns (address[] memory) {
        address[] memory _deploymentAddrForOtherChains = new address[](_chainsToDeploy.length);
        for (uint256 i; i < _chainsToDeploy.length; i++) {
            address _paymentTokenOnChain = IRealEstateRegistry(s_registry).getAcceptedTokenOnChain(_paymentToken, _chainsToDeploy[i]);
            address _manager = chainSelectorToManager[chainIdToSelector[_chainsToDeploy[i]]];
            bytes memory _creationCode = type(TokenizedRealEstate).creationCode;
            bytes memory code = abi.encodePacked(
                _creationCode, 
                abi.encode(
                    _estateOwner[i], 
                    _estateCost,
                    _percentageToTokenize, 
                    _tokenId, 
                    _paymentTokenOnChain
                )
            );
            bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), _manager, _salt, keccak256(code)));
            _deploymentAddrForOtherChains[i] = address(uint160(uint256(hash)));
        }
        return _deploymentAddrForOtherChains;
    }

    function _baseURI() internal pure override returns (string memory) {
        return "data:application/json;base64,";
    }

    function tokenURI(uint256 _tokenId) public view override returns (string memory) {
        EstateInfo memory estateInfo = s_tokenidToEstateInfo[_tokenId];
        
        string memory estateTokenUri = Base64.encode(
            abi.encodePacked(
                '{"name": "Tokenized Estate #', Strings.toString(_tokenId),
                '", "description": "This NFT represents a tokenized real estate asset",',
                '"attributes": {',
                    '"estateOwner": "', Strings.toHexString(estateInfo.estateOwner),
                    '", "percentageToTokenize": "', Strings.toString(estateInfo.percentageToTokenize),
                    '", "tokenizedRealEstate": "', Strings.toHexString(estateInfo.tokenizedRealEstate),
                    '", "estateCost": "', Strings.toString(estateInfo.estateCost),
                    '", "accumulatedRewards": "', Strings.toString(estateInfo.accumulatedRewards),
                    '", "verifyingOperator": "', Strings.toHexString(estateInfo.verifyingOperator),
                '"}'
                '}'
            )
        );

        return string.concat(_baseURI(), estateTokenUri);
    }

    // function getAllChainDeploymentAddr(address[] memory _estateOwner, uint256 _estateCost, uint256 _percentageToTokenize, uint256 _tokenId, bytes32 _salt, address _paymentToken, uint256[] memory _chainsToDeploy) external view returns (address[] memory) {
    //     return _getAllChainDeploymentAddr(_estateOwner, _estateCost, _percentageToTokenize, _tokenId, _salt, _paymentToken, _chainsToDeploy);
    // }

    function getEstateInfo(uint256 tokenId) external view returns (EstateInfo memory) {
        return s_tokenidToEstateInfo[tokenId];
    }

    function getEstateOwnerToTokeinzedRealEstate(address estateOwner) external view returns (address) {
        return s_estateOwnerToTokenizedRealEstate[estateOwner];
    }

    function getRegistry() external view returns (address) {
        return s_registry;
    }

    function getEstateVerification() external view returns (address) {
        return address(i_estateVerification);
    }

    function getCollateralDepositedBy(address estateOwner) external view returns (uint256) {
        return s_getCollateralDepositedBy[estateOwner];
    }

    function getTokenCounter() external view returns (uint256) {
        return s_tokenCounter;
    }

    function getIsSupportedChain(uint256 chainId) external view returns (bool) {
        return s_isSupportedChain[chainId];
    }

    function getTokenIdToChainIdToTokenizedRealEstate(uint256 tokenId, uint256 chainId) external view returns (address) {
        return s_tokenIdToChainIdToTokenizedRealEstate[tokenId][chainId];
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, EstateAcrossChain) returns (bool) {
        return ERC721.supportsInterface(interfaceId) || EstateAcrossChain.supportsInterface(interfaceId);
    }

    function getBaseChain() external view returns (uint256) {
        return i_baseChain;
    }

    function getSupportedChains() external view returns (uint256[] memory) {
        return s_supportedChains;
    }
}
