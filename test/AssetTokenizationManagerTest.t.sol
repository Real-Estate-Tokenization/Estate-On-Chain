// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {TokenizedRealEstate} from "../src/TokenizedRealEstate.sol";
import {AssetTokenizationManager} from "../src/AssetTokenizationManager.sol";
import {DeployAssetTokenizationManager} from "../script/DeployAssetTokenizationManager.s.sol";
import {HelperConfig} from "../script/HelperConfig.s.sol";
import {VerifyingOperatorVault} from "../src/VerifyingOperatorVault.sol";
import {RealEstateRegistry} from "../src/RealEstateRegistry.sol";
import {MockERC20} from "../test/mocks/MockERC20Token.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {USDC} from "../test/mocks/MockUSDCToken.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {EstateVerification} from "../src/Computation/EstateVerification.sol";

contract AssetTokenizationManagerTest is Test {
    error AssetTokenizationManager__BaseChainRequired();
    error AssetTokenizationManager__TokenNotWhitelisted();
    error AssetTokenizationManager__NotAssetOwner();
    error RealEstateRegistry__InvalidToken();
    error RealEstateRegistry__InvalidCollateral();
    error RealEstateRegistry__InvalidENSName();
    error EstateVerification__TokenNotWhitelisted();
    error EstateVerification__NotAssetOwner();
    error EstateVerification__BaseChainRequired();

    TokenizedRealEstate public tokenizedRealEstate;
    address public user;
    address owner;
    uint256 ownerKey;
    address slasher;
    address signer;
    address nodeOperator;
    uint256 signerKey;
    ERC20 mockToken;
    USDC public usdc;
    HelperConfig public helperConfig;
    HelperConfig.NetworkConfig public networkConfig;
    AssetTokenizationManager public assetTokenizationManager;
    DeployAssetTokenizationManager public deployer;
    RealEstateRegistry public realEstateRegistry;
    VerifyingOperatorVault public verifyingOperatorVault;
    EstateVerification public estateVerification;

    function setUp() public {
        (owner, ownerKey) = makeAddrAndKey("owner");
        slasher = makeAddr("slasher");
        (signer, signerKey) = makeAddrAndKey("signer");
        nodeOperator = makeAddr("nodeOperator");
        mockToken = new MockERC20();

        deployer = new DeployAssetTokenizationManager();
        (assetTokenizationManager, verifyingOperatorVault, realEstateRegistry, usdc, estateVerification,helperConfig) = deployer.deploy(owner, ownerKey);
        networkConfig = helperConfig.getNetworkConfig();

        address[] memory _acceptedTokens = new address[](1);
        _acceptedTokens[0] = networkConfig.link;
        address[] memory dataFeeds = new address[](1);
        dataFeeds[0] = makeAddr("dataFeed");
        
        // verifyingOperatorVault = new VerifyingOperatorVault();

        // vm.startPrank(address(owner));
        // realEstateRegistry = new RealEstateRegistry(
        //     slasher,
        //     signer,
        //     1e18,
        //     _acceptedTokens,
        //     dataFeeds,
        //     address(verifyingOperatorVault),
        //     networkConfig.swapRouter,
        //     address(assetTokenizationManager)
        // );

        // vm.stopPrank();

        user = makeAddr("user");
    }

    function test_ccipReceiveWithDataX() public {
        address router = networkConfig.ccipRouter;

        address tokenizationManagerSource = makeAddr("tokenizationManagerSource");

        uint256 MESSAGE_TYPE = 1;
        address estateOwner = nodeOperator;
        uint256 estateCost = 1000000e18;
        uint256 percentageToTokenize = 100e18;
        uint256 tokenId = 1;
        bytes32 salt = bytes32(abi.encode(69));
        address paymentToken = address(usdc);
        uint256[] memory chainsToDeploy = new uint256[](2);
        chainsToDeploy[0] = networkConfig.supportedChains[0];
        chainsToDeploy[1] = networkConfig.supportedChains[1];
        address[] memory deploymentAddrForOtherChains = new address[](2);
        deploymentAddrForOtherChains[0] = makeAddr("deploymentAddrForOtherChains0");
        deploymentAddrForOtherChains[1] = makeAddr("deploymentAddrForOtherChains1");

        Client.Any2EVMMessage memory any2EvmMessage = Client.Any2EVMMessage({
            messageId: bytes32(abi.encode(69)),
            sourceChainSelector: 14767482510784806043, // 43113
            sender: abi.encode(tokenizationManagerSource),
            data: abi.encode(MESSAGE_TYPE, estateOwner, estateCost, percentageToTokenize, tokenId, salt, paymentToken, chainsToDeploy, deploymentAddrForOtherChains),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        vm.prank(owner);
        assetTokenizationManager.allowlistManager(14767482510784806043, tokenizationManagerSource);

        vm.prank(router);
        assetTokenizationManager.ccipReceive(any2EvmMessage);

        console.log(assetTokenizationManager.getEstateInfo(1).estateOwner, "estateOwner");
        console.log(assetTokenizationManager.getEstateOwnerToTokeinzedRealEstate(estateOwner), "estateOwnerToTokeinzedRealEstate");
    }

    // function test_ccipReceiveWithDataFork() public {
    //     address router = networkConfig.ccipRouter;

    //     address tokenizationManagerSource = makeAddr("tokenizationManagerSource");

    //     uint256 MESSAGE_TYPE = 1;
    //     address estateOwner = nodeOperator;
    //     uint256 estateCost = 1000000e18;
    //     uint256 percentageToTokenize = 100e18;
    //     uint256 tokenId = 2;
    //     bytes32 salt = bytes32(abi.encode(70));
    //     address paymentToken = address(usdc);
    //     uint256[] memory chainsToDeploy = new uint256[](2);
    //     chainsToDeploy[0] = networkConfig.supportedChains[0];
    //     chainsToDeploy[1] = networkConfig.supportedChains[1];
    //     address[] memory deploymentAddrForOtherChains = new address[](2);
    //     deploymentAddrForOtherChains[0] = makeAddr("deploymentAddrForOtherChains0");
    //     deploymentAddrForOtherChains[1] = makeAddr("deploymentAddrForOtherChains1");

    //     Client.Any2EVMMessage memory any2EvmMessage = Client.Any2EVMMessage({
    //         messageId: bytes32(abi.encode(69)),
    //         sourceChainSelector: 14767482510784806043, // 43113
    //         sender: abi.encode(tokenizationManagerSource),
    //         data: abi.encode(MESSAGE_TYPE, estateOwner, estateCost, percentageToTokenize, tokenId, salt, paymentToken, chainsToDeploy, deploymentAddrForOtherChains),
    //         destTokenAmounts: new Client.EVMTokenAmount[](0)
    //     });

    //     vm.prank(owner);
    //     assetTokenizationManager.allowlistManager(14767482510784806043, tokenizationManagerSource);

    //     console.log("Total Supply:", assetTokenizationManager.balanceOf(estateOwner));

    //     vm.prank(router);
    //     assetTokenizationManager.ccipReceive(any2EvmMessage);

    //     AssetTokenizationManager.EstateInfo memory info = assetTokenizationManager.getEstateInfo(2);
    //     console.log("Total Supply:", assetTokenizationManager.balanceOf(estateOwner));
    //     console.log(info.estateOwner, "estateOwner");
    //     console.log(info.percentageToTokenize, "percentageToTokenize");
    //     console.log(info.tokenizedRealEstate, "percentageToTokenize");
    //     console.log(info.estateCost, "percentageToTokenize");
    // }

    // function test_ccipReceiveWithDataFork_2() public {
    //     address router = networkConfig.ccipRouter;

    //     address tokenizationManagerSource = makeAddr("tokenizationManagerSource");;
    //     AssetTokenizationManager currATM = AssetTokenizationManager(makeAddr("AssetTokenizationManager"););

    //     uint256 MESSAGE_TYPE = 1;
    //     address estateOwner = nodeOperator;
    //     uint256 estateCost = 1000000e18;
    //     uint256 percentageToTokenize = 100e18;
    //     uint256 tokenId = 2;
    //     bytes32 salt = bytes32(abi.encode(70));
    //     address paymentToken = address(usdc);
    //     uint256[] memory chainsToDeploy = new uint256[](2);
    //     chainsToDeploy[0] = networkConfig.supportedChains[0];
    //     chainsToDeploy[1] = networkConfig.supportedChains[1];
    //     address[] memory deploymentAddrForOtherChains = new address[](2);
    //     deploymentAddrForOtherChains[0] = makeAddr("deploymentAddrForOtherChains0");
    //     deploymentAddrForOtherChains[1] = makeAddr("deploymentAddrForOtherChains1");

    //     Client.Any2EVMMessage memory any2EvmMessage = Client.Any2EVMMessage({
    //         messageId: bytes32(abi.encode(69)),
    //         sourceChainSelector: 14767482510784806043, // 43113
    //         sender: abi.encode(tokenizationManagerSource),
    //         data: abi.encode(MESSAGE_TYPE, estateOwner, estateCost, percentageToTokenize, tokenId, salt, paymentToken, chainsToDeploy, deploymentAddrForOtherChains),
    //         destTokenAmounts: new Client.EVMTokenAmount[](0)
    //     });

    //     console.log("Total Supply:", currATM.balanceOf(estateOwner));

    //     vm.prank(router);
    //     currATM.ccipReceive(any2EvmMessage);

    //     // AssetTokenizationManager.EstateInfo memory info = currATM.getEstateInfo(2);
    //     console.log("Total Supply:", currATM.balanceOf(estateOwner));
    //     console.log("Owner:", currATM.ownerOf(tokenId));
    //     // console.log(info.estateOwner, "estateOwner");
    //     // console.log(info.percentageToTokenize, "percentageToTokenize");
    //     // console.log(info.tokenizedRealEstate, "percentageToTokenize");
    //     // console.log(info.estateCost, "percentageToTokenize");
    // }


    // function test_ccipReceiveWithDataFork_Curr() public {
    //     address router = 0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59;

    //     address tokenizationManagerSource = makeAddr("tokenizationManagerSource");;
    //     AssetTokenizationManager currATM = AssetTokenizationManager(makeAddr("AssetTokenizationManager"););

    //     address estateOwner = makeAddr("estateOwner");
    //     // uint256 MESSAGE_TYPE = 1;
    //     // uint256 estateCost = 1000;
    //     // uint256 percentageToTokenize = 100e18;
    //     uint256 tokenId = 1;
    //     // bytes32 salt = bytes32(bytes("7000"));
    //     // address paymentToken = address(usdc);
    //     // uint256[] memory chainsToDeploy = new uint256[](2);
    //     // chainsToDeploy[0] = networkConfig.supportedChains[0];
    //     // chainsToDeploy[1] = networkConfig.supportedChains[1];
    //     // address[] memory deploymentAddrForOtherChains = new address[](2);
    //     // deploymentAddrForOtherChains[0] = makeAddr("deploymentAddrForOtherChains0");
    //     // deploymentAddrForOtherChains[1] = makeAddr("deploymentAddrForOtherChains1");

    //     Client.Any2EVMMessage memory any2EvmMessage = Client.Any2EVMMessage({
    //         messageId: bytes32(keccak256("message_id")),
    //         sourceChainSelector: 14767482510784806043, // 43113
    //         sender: abi.encode(tokenizationManagerSource),
    //         data: hex"0000000000000000000000000000000000000000000000000000000000000001000000000000000000000000697f5e7a089e1621ea329fe4e906ea45d16e79c600000000000000000000000000000000000000000000000000000000000003e80000000000000000000000000000000000000000000000056bc75e2d63100000000000000000000000000000000000000000000000000000000000000000000137303030000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000012000000000000000000000000000000000000000000000000000000000000001800000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000a8690000000000000000000000000000000000000000000000000000000000aa36a700000000000000000000000000000000000000000000000000000000000000020000000000000000000000003b9c38ddbe817335c8aea40204938ab42186c969000000000000000000000000de482fd8265dbad60dd5c0761ab8ccc848a71699",
    //         destTokenAmounts: new Client.EVMTokenAmount[](0)
    //     });

    //     console.log("Total Supply:", currATM.balanceOf(estateOwner));

    //     vm.prank(router);
    //     currATM.ccipReceive(any2EvmMessage);

    //     // AssetTokenizationManager.EstateInfo memory info = currATM.getEstateInfo(2);
    //     console.log("Total Supply:", currATM.balanceOf(estateOwner));
    //     console.log("Owner:", currATM.ownerOf(tokenId));
    //     // console.log(info.estateOwner, "estateOwner");
    //     // console.log(info.percentageToTokenize, "percentageToTokenize");
    //     // console.log(info.tokenizedRealEstate, "percentageToTokenize");
    //     // console.log(info.estateCost, "percentageToTokenize");
    // }

    function test_ConstructorAssetTokenizationManager() public view {
        assertEq(assetTokenizationManager.getBaseChain(), networkConfig.baseChainId);
        uint256[] memory supportedChains = assetTokenizationManager.getSupportedChains();
        for (uint256 i = 0; i < supportedChains.length; i++) {
            assertEq(supportedChains[i], networkConfig.supportedChains[i]);
        }
    }

    function test_createTokenizedRealEstate_IsBaseChainRequired() public {
        uint256[] memory _chainsToDeploy = new uint256[](2);

        address[] memory _estateOwnerAcrossChain = new address[](2);

        vm.startPrank(user);
        vm.expectRevert(EstateVerification__BaseChainRequired.selector);
        estateVerification.createTokenizedRealEstate(networkConfig.link, _chainsToDeploy, _estateOwnerAcrossChain);
        vm.stopPrank();
    }

    function test_createTokenizedRealEstate() public {
        uint256[] memory _chainsToDeploy = new uint256[](2);
        _chainsToDeploy[0] = networkConfig.supportedChains[0];
        _chainsToDeploy[1] = networkConfig.supportedChains[1];

        address[] memory _estateOwnerAcrossChain = new address[](2);

        vm.startPrank(user);
        vm.expectRevert();
        estateVerification.createTokenizedRealEstate(networkConfig.link, _chainsToDeploy, _estateOwnerAcrossChain);
        vm.stopPrank();
    }

    function test_setRegistryIsNotCallableFroUsers() public {
        vm.startPrank(user);
        vm.expectRevert();
        assetTokenizationManager.setRegistry(address(realEstateRegistry));
        vm.stopPrank();
    }

    function test_setEstateVerificationSourceIsNotCallableFroUsers() public {
        EstateVerification.EstateVerificationFunctionsParams memory _params;
        _params.source = "source";
        _params.encryptedSecretsUrls = "encryptedSecretsUrls";
        _params.subId = 1;
        _params.gasLimit = 1;
        _params.donId = "0x1";

        vm.startPrank(user);
        vm.expectRevert();
        estateVerification.setEstateVerificationSource(_params);
        vm.stopPrank();
    }

    function test_setEstateVerificationSource() public {
        EstateVerification.EstateVerificationFunctionsParams memory _params;
        _params.source = "source";
        _params.encryptedSecretsUrls = "encryptedSecretsUrls";
        _params.subId = 1;
        _params.gasLimit = 1;
        _params.donId = "0x1";

        vm.startPrank(address(owner));
        estateVerification.setEstateVerificationSource(_params);
        vm.stopPrank();
    }

    function test_setRegistry() public {
        vm.startPrank(address(owner));
        assetTokenizationManager.setRegistry(address(realEstateRegistry));
        vm.stopPrank();
    }

    function test_createTokenizedRealEstateRegistryIfTokenNotWhitelisted() public {
        uint256[] memory _chainsToDeploy = new uint256[](2);
        _chainsToDeploy[0] = networkConfig.supportedChains[0];
        _chainsToDeploy[1] = networkConfig.supportedChains[1];

        address[] memory _estateOwnerAcrossChain = new address[](2);
        
        vm.startPrank(owner);
        assetTokenizationManager.setRegistry(address(realEstateRegistry));
        vm.stopPrank();

        address paymentToken = makeAddr("paymentToken");
        vm.expectRevert(EstateVerification__TokenNotWhitelisted.selector);
        vm.startPrank(address(user));
        estateVerification.createTokenizedRealEstate(paymentToken, _chainsToDeploy, _estateOwnerAcrossChain);
        vm.stopPrank();
    }

    function test_createTokenizedRealEstateRegistryNotAssetOwner() public {
        uint256[] memory _chainsToDeploy = new uint256[](2);
        _chainsToDeploy[0] = networkConfig.supportedChains[0];
        _chainsToDeploy[1] = networkConfig.supportedChains[1];

        address[] memory _estateOwnerAcrossChain = new address[](2);
        
        vm.startPrank(owner);
        assetTokenizationManager.setRegistry(address(realEstateRegistry));
        vm.stopPrank();

        address paymentToken = networkConfig.link;
        vm.startPrank(address(user));
        vm.expectRevert(EstateVerification__NotAssetOwner.selector);
        estateVerification.createTokenizedRealEstate(paymentToken, _chainsToDeploy, _estateOwnerAcrossChain);
        vm.stopPrank();
    }

    // function test_createTokenizedRealEstate_RegistryYOYO() public {
    //     uint256[] memory _chainsToDeploy = new uint256[](2);
    //     _chainsToDeploy[0] = networkConfig.supportedChains[0];
    //     _chainsToDeploy[1] = networkConfig.supportedChains[1];

    //     address[] memory _estateOwnerAcrossChain = new address[](2);
    //     _estateOwnerAcrossChain[0] = address(user);
    //     _estateOwnerAcrossChain[1] = address(0x2);

    //     // vm.deal(user, 1e18);
    //     vm.startPrank(owner);
    //     assetTokenizationManager.setRegistry(address(realEstateRegistry));
    //     vm.stopPrank();

    //     address paymentToken = networkConfig.link;
    //     vm.startPrank(address(user));
    //     estateVerification.createTokenizedRealEstate(paymentToken, _chainsToDeploy, _estateOwnerAcrossChain);
    //     vm.stopPrank();
    // }

    function test_setTokenForAnotherChainIfNotSETTER_ROLE() public {
        address token = makeAddr("token");
        uint256 chainId = 1;

        vm.startPrank(user);
        vm.expectRevert();
        realEstateRegistry.setTokenForAnotherChain(token, chainId, networkConfig.link);
        vm.stopPrank();
    }

    function test_setTokenForAnotherChainIfInvalidToken() public {
        address token = makeAddr("token");
        uint256 chainId = 1;

        vm.startPrank(owner);
        vm.expectRevert(RealEstateRegistry__InvalidToken.selector);
        realEstateRegistry.setTokenForAnotherChain(token, chainId, networkConfig.link);
        vm.stopPrank();
    }

    function test_setTokenForAnotherChain() public {
        address token = networkConfig.link;
        uint256 chainId = 1;

        vm.startPrank(owner);
        realEstateRegistry.setTokenForAnotherChain(token, chainId, networkConfig.link);
        vm.stopPrank();
    }

    function test_addCollateralTokenIfNotSETTER_ROLE() public {
        address token = networkConfig.link;
        address datafeed = makeAddr("datafeed");

        vm.startPrank(user);
        vm.expectRevert();
        realEstateRegistry.addCollateralToken(token, datafeed);
        vm.stopPrank();
    }

    function test_setSwapRouterIfNotSETTER_ROLE() public {
        address swapRouter = makeAddr("swapRouter");

        vm.startPrank(user);
        vm.expectRevert();
        realEstateRegistry.setSwapRouter(swapRouter);
        vm.stopPrank();
    }

    function test_setSwapRouter() public {
        address swapRouter = makeAddr("swapRouter");

        vm.startPrank(owner);
        realEstateRegistry.setSwapRouter(swapRouter);
        vm.stopPrank();
    }

    function test_updateVOVImplementation() public {
        address newImplementation = makeAddr("newImplementation");

        vm.startPrank(owner);
        realEstateRegistry.updateVOVImplementation(newImplementation);
        vm.stopPrank();
    }

    function test_updateVOVImplementationIfNotSETTER_ROLE() public {
        address newImplementation = makeAddr("newImplementation");

        vm.startPrank(user);
        vm.expectRevert();
        realEstateRegistry.updateVOVImplementation(newImplementation);
        vm.stopPrank();
    }

    function test_setCollateralRequiredForOperatorIfInvalidLowCollateral() public {
        uint256 newOperatorCollateral = 1_000;

        vm.startPrank(owner);
        vm.expectRevert(RealEstateRegistry__InvalidCollateral.selector);
        realEstateRegistry.setCollateralRequiredForOperator(newOperatorCollateral);
        vm.stopPrank();
    }

    function test_setCollateralRequiredForOperatorIfInvalidHighCollateral() public {
        uint256 newOperatorCollateral = 1_30_000;

        vm.startPrank(owner);
        vm.expectRevert(RealEstateRegistry__InvalidCollateral.selector);
        realEstateRegistry.setCollateralRequiredForOperator(newOperatorCollateral);
        vm.stopPrank();
    }

    function test_setCollateralRequiredForOperatorIfNotSETTER_ROLE() public {
        uint256 newOperatorCollateral = 50_000;

        vm.startPrank(user);
        vm.expectRevert();
        realEstateRegistry.setCollateralRequiredForOperator(newOperatorCollateral);
        vm.stopPrank();
    }

    function test_setCollateralRequiredForOperator() public {
        uint256 newOperatorCollateral = 50_000;

        vm.startPrank(owner);
        realEstateRegistry.setCollateralRequiredForOperator(newOperatorCollateral);
        vm.stopPrank();
        assertEq(realEstateRegistry.getFiatCollateralRequiredForOperator(), newOperatorCollateral);
    }

    function test_approveOperatorVaultInvalidENSName() public {
        string memory operatorVaultEns = "operatorVaultEns";
        uint256 collateral = 50_000;

        vm.startPrank(owner);
        realEstateRegistry.setCollateralRequiredForOperator(collateral);
        vm.expectRevert(RealEstateRegistry__InvalidENSName.selector);
        realEstateRegistry.approveOperatorVault(operatorVaultEns);
        vm.stopPrank();
    }

    // function test_handleCrossChainMessage() public {
    //     bytes memory _data = hex"0000000000000000000000000000000000000000000000000000000000000001000000000000000000000000f1c8170181364ded1c56c4361ded2eb47f2eef1b00000000000000000000000000000000000000000000000000000000000003e80000000000000000000000000000000000000000000000056bc75e2d63100000000000000000000000000000000000000000000000000000000000000000000136390000000000000000000000000000000000000000000000000000000000000000000000000000000000001c6db13f57da5eaac72e591adcc96bc76d987623000000000000000000000000000000000000000000000000000000000000012000000000000000000000000000000000000000000000000000000000000001800000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000a8690000000000000000000000000000000000000000000000000000000000aa36a700000000000000000000000000000000000000000000000000000000000000020000000000000000000000006fe732c2eef2eeeec64e2216205b1efa1a8f83d8000000000000000000000000a10a8420a99eb2002058ad45e134df03208e6a02";
    //     assetTokenizationManager.handleTestCrossChainMessage(bytes32(0), _data);
    // }

    function test_crossChainDecoding() public pure {
        bytes memory _data = hex"0000000000000000000000000000000000000000000000000000000000000001000000000000000000000000f1c8170181364ded1c56c4361ded2eb47f2eef1b00000000000000000000000000000000000000000000000000000000000003e80000000000000000000000000000000000000000000000056bc75e2d63100000000000000000000000000000000000000000000000000000000000000000000136390000000000000000000000000000000000000000000000000000000000000000000000000000000000001c6db13f57da5eaac72e591adcc96bc76d987623000000000000000000000000000000000000000000000000000000000000012000000000000000000000000000000000000000000000000000000000000001800000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000a8690000000000000000000000000000000000000000000000000000000000aa36a700000000000000000000000000000000000000000000000000000000000000020000000000000000000000006fe732c2eef2eeeec64e2216205b1efa1a8f83d8000000000000000000000000a10a8420a99eb2002058ad45e134df03208e6a02";
        (
            uint256 reqType,
            address _estateOwner,
            uint256 _estateCost,
            uint256 _percentageToTokenize,
            uint256 _tokenId,
            bytes32 _salt,
            address _paymentToken,
            uint256[] memory _chainsToDeploy,
            address[] memory _deploymentAddrForOtherChains
        ) = abi.decode(_data, (uint256, address, uint256, uint256, uint256, bytes32, address, uint256[], address[]));
    
        uint256 ccipRequestType;
        
        assembly ("memory-safe") {
            ccipRequestType := mload(add(_data, 0x20))
        }

        console.log("CRT:", ccipRequestType);

        console.log(reqType);
        console.log(_estateOwner);
        console.log(_estateCost);
        console.log(_percentageToTokenize);
        console.log(_tokenId);
        console.logBytes32(_salt);
        console.log(_paymentToken);
        console.log(_chainsToDeploy[0]);
        console.log(_chainsToDeploy[1]);
        console.log(_deploymentAddrForOtherChains[0]);
        console.log(_deploymentAddrForOtherChains[1]);
    }

    // function test_approveOperatorVault__() public {
    //     string memory operatorVaultEns = "operatorVaultEns";
    //     uint256 collateral = 50_000;

    //     vm.startPrank(signer);
    //     realEstateRegistry.setCollateralRequiredForOperator(collateral);
    //     realEstateRegistry.approveOperatorVault(operatorVaultEns);
    //     vm.stopPrank();
    // }

    // function test_depositCollateralAndRegisterVault() public {
    //     string memory operatorVaultEns = "operatorVaultEns";
    //     uint256 collateral = 50_000;
    //     bytes memory data = abi.encode(operatorVaultEns, networkConfig.link, 1e18);

    //     vm.startPrank(owner);
    //     realEstateRegistry.setCollateralRequiredForOperator(collateral);
    //     realEstateRegistry.depositCollateralAndRegisterVault(operatorVaultEns, networkConfig.link, data, false);
    //     vm.stopPrank();
    // }

    function prepareAndSignSignature(address _nodeOperaror, string memory _ensName) internal view returns (bytes memory _signature) {
        bytes32 digest = realEstateRegistry.prepareRegisterVaultHash(_nodeOperaror, _ensName);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        _signature = abi.encodePacked(r, s, v);
    }

    // function test_fulfillCreateEstateRequest() public {
    //     bytes memory _signature = prepareAndSignSignature(nodeOperator, "nodeOpEns");
    //     vm.startPrank(nodeOperator);

    //     mockToken.approve(address(realEstateRegistry), 1e18);
    //     realEstateRegistry.depositCollateralAndRegisterVault("nodeOpEns", address(mockToken), _signature, true);

    //     vm.stopPrank();

    //     vm.prank(owner);
    //     realEstateRegistry.approveOperatorVault("nodeOpEns");

    //     address vault = realEstateRegistry.getOperatorVault(nodeOperator);
        
    //     console.log(vault, "________________________________ghffu________");

        // AssetTokenizationManager.TokenizeFunctionCallRequest memory request;
        // request.estateOwner = user;
        // request.chainsToDeploy = new uint256[](2);
        // request.chainsToDeploy[0] = networkConfig.supportedChains[0];
        // request.chainsToDeploy[1] = networkConfig.supportedChains[1];
        // request.paymentToken = networkConfig.link;
        // request.estateOwnerAcrossChain = new address[](2);
        // request.estateOwnerAcrossChain[0] = user;
        // request.estateOwnerAcrossChain[1] = makeAddr("owner");

    //     // uint256 estateCost = 1e18;
    //     // uint256 percentageToTokenize = 50;
    //     // bool isApproved = true;
    //     // bytes memory _saltBytes = abi.encode(5802);
    //     // address _verifyingOperator = nodeOperator;

        // bytes memory response = abi.encode(estateCost, percentageToTokenize, isApproved, _saltBytes, _verifyingOperator);
        
    //     // vm.startPrank(owner);
    //     // assetTokenizationManager.createTestRequestIdResponse(request, response);
    //     // vm.stopPrank();
    // }
}
