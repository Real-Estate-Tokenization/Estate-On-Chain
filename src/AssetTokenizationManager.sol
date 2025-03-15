// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import { TokenizedRealEstate } from "./TokenizedRealEstate.sol";
import { EstateAcrossChain } from "./Bridge/EstateAcrossChain.sol";
import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IRealEstateRegistry } from "./interfaces/IRealEstateRegistry.sol";
import { IVerifyingOperatorVault } from "./interfaces/IVerifyingOperatorVault.sol";
import { FunctionsClient, FunctionsRequest } from "@chainlink/contracts/src/v0.8/functions/v1_3_0/FunctionsClient.sol";
import { Base64 } from "@openzeppelin/contracts/utils/Base64.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { AggregatorV3Interface } from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
// import { console } from "forge-std/Test.sol";

interface IERC20Decimals {
    function decimals() external view returns (uint8);
}

contract AssetTokenizationManager is ERC721, EstateAcrossChain, FunctionsClient {
    // libraries
    using SafeERC20 for IERC20;
    using FunctionsRequest for FunctionsRequest.Request;

    // Errors
    error AssetTokenizationManager__NotAssetOwner();
    error AssetTokenizationManager__NotShareHolder();
    error AssetTokenizationManager__ChainNotSupported();
    error AssetTokenizationManager__OnlyOneTokenizedRealEstatePerUser();
    error AssetTokenizationManager__BaseChainRequired();
    error AssetTokenizationManager__TokenNotWhitelisted();

    // Structs
    struct EstateInfo {
        address estateOwner;
        uint256 percentageToTokenize;
        address tokenizedRealEstate;
        uint256 estateCost;
        uint256 accumulatedRewards;
        address verifyingOperator;
    }

    struct TokenizeFunctionCallRequest {
        address estateOwner;
        uint256[] chainsToDeploy;
        address paymentToken;
        address[] estateOwnerAcrossChain;
    }

    struct EstateVerificationFunctionsParams {
        string source;
        bytes encryptedSecretsUrls;
        uint64 subId;
        uint32 gasLimit;
        bytes32 donId;
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
    mapping(bytes32 reqId => TokenizeFunctionCallRequest) private s_reqIdToTokenizeFunctionCallRequest;
    mapping(uint256 => mapping(uint256 => address)) private s_tokenIdToChainIdToTokenizedRealEstate;
    bytes private s_latestError;
    uint256 private constant ESTATE_OWNER_COLLATERAL_USD = 200;

    EstateVerificationFunctionsParams private s_estateVerificationFunctionsParams;

    uint256 private constant CCIP_DEPLOY_TOKENIZED_REAL_ESTATE = 1;

    uint256 private constant MAX_DECIMALS_SHARE_PERCENTAGE = 5;
    uint256 private constant TOTAL_TRE = 1e6 * 1e18;

    // events
    event ValidatorAdded(address validator);
    event ShareholderAdded(address shareholder);
    event TokenizationRequestPlaced(bytes32 reqId, address estateOwner);
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
    ) ERC721("Asset Tokenization Manager", "ATM") EstateAcrossChain(_ccipRouter, _link, _supportedChains, _chainSelectors) FunctionsClient(_functionsRouter) {
        i_baseChain = _baseChainId;
        s_estateVerificationFunctionsParams = EstateVerificationFunctionsParams({
            source: _estateVerificationSource,
            encryptedSecretsUrls: _encryptedSecretsUrls,
            subId: _subId,
            gasLimit: _gasLimit,
            donId: _donID
        });
        for (uint256 i; i < _supportedChains.length; i++) {
            s_supportedChains.push(_supportedChains[i]);
            s_isSupportedChain[_supportedChains[i]] = true;
        }
    }

    function setRegistry(address _registry) external onlyRole(DEFAULT_ADMIN_ROLE) {
        s_registry = _registry;
    }

    function setEstateVerificationSource(EstateVerificationFunctionsParams memory _params) external onlyRole(DEFAULT_ADMIN_ROLE) {
        s_estateVerificationFunctionsParams = _params;
    }

    // functions
    /**
     * @dev calls chainlink function to query for data from the off-chain registry
     * @notice one user can have only one tokenized real estate registered
     * @param _paymentToken address of the token to be used for payment on the owner's real estate contract
     */
    function createTokenizedRealEstate(address _paymentToken, uint256[] memory chainsToDeploy, address[] memory _estateOwnerAcrossChain) external returns (bytes32) {
        require(balanceOf(msg.sender) == 0, AssetTokenizationManager__OnlyOneTokenizedRealEstatePerUser());
        require(block.chainid == i_baseChain, AssetTokenizationManager__ChainNotSupported());
        require(chainsToDeploy[0] == block.chainid, AssetTokenizationManager__BaseChainRequired());
        require(IRealEstateRegistry(s_registry).getDataFeedForToken(_paymentToken) != address(0), AssetTokenizationManager__TokenNotWhitelisted());
        require(msg.sender == _estateOwnerAcrossChain[0], AssetTokenizationManager__NotAssetOwner());
        for (uint256 i; i < chainsToDeploy.length; i++) {
            if (i > 0) {
                require(chainsToDeploy[i] != block.chainid, AssetTokenizationManager__ChainNotSupported());
            }
            require(s_isSupportedChain[chainsToDeploy[i]], AssetTokenizationManager__ChainNotSupported());
        }
        
        FunctionsRequest.Request memory req;
        string[] memory args = new string[](1);
        args[0] = Strings.toHexString(msg.sender);
        req.initializeRequestForInlineJavaScript(s_estateVerificationFunctionsParams.source);
        req.addSecretsReference(s_estateVerificationFunctionsParams.encryptedSecretsUrls);
        req.setArgs(args);

        bytes32 reqId = _sendRequest(
            req.encodeCBOR(),
            s_estateVerificationFunctionsParams.subId,
            s_estateVerificationFunctionsParams.gasLimit,
            s_estateVerificationFunctionsParams.donId
        );

        emit TokenizationRequestPlaced(reqId, msg.sender);
        s_reqIdToTokenizeFunctionCallRequest[reqId] = TokenizeFunctionCallRequest({
            estateOwner: msg.sender,
            chainsToDeploy: chainsToDeploy,
            paymentToken: _paymentToken,
            estateOwnerAcrossChain: _estateOwnerAcrossChain
        });

        return reqId;
    }

    function _fulfillRequest(bytes32 requestId, bytes memory response, bytes memory err) internal override {
        _fulfillCreateEstateRequest(requestId, response);
        s_latestError = err;
    }

    function createTestRequestIdResponse(TokenizeFunctionCallRequest memory _request, bytes memory _response) external {
        bytes32 _requestId = keccak256(abi.encode(_request));
        s_reqIdToTokenizeFunctionCallRequest[_requestId] = _request;
        _fulfillCreateEstateRequest(_requestId, _response);
    }

    function _fulfillCreateEstateRequest(bytes32 _reqId, bytes memory _response) internal {
        TokenizeFunctionCallRequest memory _request = s_reqIdToTokenizeFunctionCallRequest[_reqId];
        
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
            bridgeRequest(_chainId, bridgeData, 500_000);
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

    function handleTestCrossChainMessage(bytes32 _messageId, bytes memory _data) external {
        _handleCrossChainMessage(_messageId, _data);
    }

    function _handleCrossChainMessage(bytes32 /*_messageId*/, bytes memory _data) internal override {
        uint256 ccipRequestType;
        
        assembly {
            ccipRequestType := mload(add(_data, 0x20))
        }

        // console.log("ME HU BHAI:", ccipRequestType);

        if (ccipRequestType == CCIP_DEPLOY_TOKENIZED_REAL_ESTATE) {
            _handleDeployTokenizedRealEstate(_data);
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

    // function tokenURI(uint256 _tokenId) public view override returns (string memory) {
    //     EstateInfo memory estateInfo = s_tokenidToEstateInfo[_tokenId];
        
    //     string memory estateTokenUri = Base64.encode(
    //         abi.encodePacked(
    //             '{"name": "Tokenized Estate #', Strings.toString(_tokenId),
    //             '", "description": "This NFT represents a tokenized real estate asset",',
    //             '"attributes": {',
    //                 '"estateOwner": "', Strings.toHexString(estateInfo.estateOwner),
    //                 '", "percentageToTokenize": "', Strings.toString(estateInfo.percentageToTokenize),
    //                 '", "tokenizedRealEstate": "', Strings.toHexString(estateInfo.tokenizedRealEstate),
    //                 '", "estateCost": "', Strings.toString(estateInfo.estateCost),
    //                 '", "accumulatedRewards": "', Strings.toString(estateInfo.accumulatedRewards),
    //                 '", "verifyingOperator": "', Strings.toHexString(estateInfo.verifyingOperator),
    //             '"}'
    //             '}'
    //         )
    //     );

    //     return string.concat(_baseURI(), estateTokenUri);
    // }

    function getAllChainDeploymentAddr(address[] memory _estateOwner, uint256 _estateCost, uint256 _percentageToTokenize, uint256 _tokenId, bytes32 _salt, address _paymentToken, uint256[] memory _chainsToDeploy) external view returns (address[] memory) {
        return _getAllChainDeploymentAddr(_estateOwner, _estateCost, _percentageToTokenize, _tokenId, _salt, _paymentToken, _chainsToDeploy);
    }

    function getEstateInfo(uint256 tokenId) external view returns (EstateInfo memory) {
        return s_tokenidToEstateInfo[tokenId];
    }

    function getEstateOwnerToTokeinzedRealEstate(address estateOwner) external view returns (address) {
        return s_estateOwnerToTokenizedRealEstate[estateOwner];
    }

    // function getCollateralDepositedBy(address estateOwner) external view returns (uint256) {
    //     return s_getCollateralDepositedBy[estateOwner];
    // }

    // function getTokenCounter() external view returns (uint256) {
    //     return s_tokenCounter;
    // }

    // function getIsSupportedChain(uint256 chainId) external view returns (bool) {
    //     return s_isSupportedChain[chainId];
    // }

    // function getReqIdToTokenizeFunctionCallRequest(bytes32 reqId) external view returns (TokenizeFunctionCallRequest memory) {
    //     return s_reqIdToTokenizeFunctionCallRequest[reqId];
    // }

    function getTokenIdToChainIdToTokenizedRealEstate(uint256 tokenId, uint256 chainId) external view returns (address) {
        return s_tokenIdToChainIdToTokenizedRealEstate[tokenId][chainId];
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, EstateAcrossChain) returns (bool) {
        return ERC721.supportsInterface(interfaceId) || EstateAcrossChain.supportsInterface(interfaceId);
    }

    // function getBaseChain() external view returns (uint256) {
    //     return i_baseChain;
    // }

    // function getSupportedChains() external view returns (uint256[] memory) {
    //     return s_supportedChains;
    // }

    // function getLatestError() external view returns (bytes memory) {
    //     return s_latestError;
    // }

    // function _calculateNetAmountForShares(uint256 percentageForShareholders, uint256 amountOfAsset)
    //     internal
    //     pure
    //     returns (uint256)
    // {
    //     return (amountOfAsset * percentageForShareholders) / 100;
    // }

    // function _calculateNetTokenAmount(uint256 amount, uint256 netAmountForShareholders)
    //     internal
    //     pure
    //     returns (uint256)
    // {
    //     return (amount * TOTAL_TRE) / netAmountForShareholders;
    // }

    // function mintAssetTokenizedRealEstateForEth(uint256 percentageForShareholders, uint256 amountOfAsset) external {
    //     _mint(msg.sender, s_tokenCounter);
    //     address tokenizedRealEstate = address(new TokenizedRealEstate(address(this), msg.sender, amountOfAsset, percentageForShareholders, s_tokenCounter));

    //     TokenizedRealEstate(tokenizedRealEstate).mintTokenizedRealEstateForEth();
    //     uint256 netAmountForShares = _calculateNetAmountForShares(percentageForShareholders, amountOfAsset);
    //     s_tokenidToAssetInfo[s_tokenCounter] = EstateInfo({
    //         estateOwner: msg.sender,
    //         sharesAvailable: percentageForShareholders,
    //         token: address(tokenizedRealEstate),
    //         amountOfAsset: amountOfAsset,
    //         currRentAmount: 0,
    //         netAmountForShareholders: netAmountForShares
    //     });
    //     TokenizedRealEstate(tokenizedRealEstate).updateAssetInfo(s_tokenCounter);
    //     s_tokenCounter++;
    // }

    // function updateRentAmount(uint256 tokenid, uint256 rentAmount) external onlyEstateOwner(tokenid) {
    //     s_tokenidToAssetInfo[tokenid].currRentAmount = rentAmount;
    //     address tokenizedRealEstate = s_tokenidToAssetInfo[tokenid].token;
    //     TokenizedRealEstate(tokenizedRealEstate).updateAssetInfoRentAmount(tokenid, rentAmount);
    // }
}
