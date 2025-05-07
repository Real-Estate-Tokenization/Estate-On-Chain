// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {TokenizedRealEstate} from "../src/TokenizedRealEstate.sol";
import {AssetTokenizationManager} from "../src/AssetTokenizationManager.sol";
import {DeployAssetTokenizationManager} from "../script/DeployAssetTokenizationManager.s.sol";
import {HelperConfig} from "../script/HelperConfig.s.sol";
import {VerifyingOperatorVault} from "../src/VerifyingOperatorVault.sol";
import {ERC1967ProxyAutoUp} from "../src/ERC1967ProxyAutoUp.sol";
import {RealEstateRegistry} from "../src/RealEstateRegistry.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MockERC20} from "./mocks/MockERC20Token.sol";
import {USDC} from "./mocks/MockUSDCToken.sol";
import {MockV3Aggregator} from "@chainlink/contracts/src/v0.8/tests/MockV3Aggregator.sol";

contract AssetTokenizationManagerTest is Test {
    error AssetTokenizationManager__BaseChainRequired();
    error AssetTokenizationManager__TokenNotWhitelisted();
    error AssetTokenizationManager__NotAssetOwner();
    error RealEstateRegistry__InvalidToken();
    error RealEstateRegistry__InvalidCollateral();
    error VerifyingOperatorVault__IncorrectSlippage();

    // TokenizedRealEstate public tokenizedRealEstate;
    // address owner;
    // uint256 ownerKey;
    // HelperConfig public helperConfig;
    // HelperConfig.NetworkConfig public networkConfig;
    // AssetTokenizationManager public assetTokenizationManager;
    // DeployAssetTokenizationManager public deployer;
    VerifyingOperatorVault public vov;
    address public vovAddr;
    RealEstateRegistry public realEstateRegistry;
    address admin;
    address public user;
    address nodeOperator;
    address estateOwner;
    address slasher;
    address signer;
    uint256 signerKey;
    uint256 fiatReqForCollateral_RER;
    ERC20 mockToken;
    address[] token = new address[](1);
    address[] dataFeeds = new address[](1);

    function setUp() public {
        vov = new VerifyingOperatorVault();
        vovAddr = address(vov);

        fiatReqForCollateral_RER = 3000; // 1000 USD

        admin = makeAddr("admin");
        nodeOperator = makeAddr("nodeOperator");
        estateOwner = makeAddr("estateOwner");
        slasher = makeAddr("slasher");
        (signer, signerKey) = makeAddrAndKey("signer");

        vm.startPrank(nodeOperator);
        mockToken = new MockERC20();
        MockV3Aggregator aggregator = new MockV3Aggregator(8, 3000e8);
        vm.stopPrank();

        token[0] = address(mockToken);
        dataFeeds[0] = address(aggregator);

        vm.prank(admin);
        realEstateRegistry = new RealEstateRegistry(
            slasher, signer, fiatReqForCollateral_RER, token, dataFeeds, vovAddr, address(0), address(0)
        );
    }

    function test_fork_receivedRewards() public {        
        VerifyingOperatorVault vovF = VerifyingOperatorVault(makeAddr("VerifyingOperatorVault"));

        USDC usdc = USDC(makeAddr("usdc"));
        vm.startPrank(admin);
        usdc.mint(admin, 100e18);
        usdc.approve(address(vovF), 100e18);
        vovF.stakeCollateral(100e18);
        vm.stopPrank();

        vm.prank(makeAddr("admin"));
        RealEstateRegistry(makeAddr("realEstateRegistry")).updateVOVImplementation(makeAddr("newVovImplementation"));

        vm.prank(makeAddr("assetTokenizationManager"));
        vovF.addNewTokenizedRealEstate(makeAddr("newTre"));

        console.log(usdc.balanceOf(address(vovF)));
        console.log(usdc.balanceOf(makeAddr("newTre")));
        vm.prank(makeAddr("newTre"));
        vovF.receiveRewards(address(usdc), 205e20);
    }

    function test_DepositCollateralAndRegisterVault() public {
        bytes memory _signature = prepareAndSignSignature(nodeOperator, "nodeOpEns");

        vm.startPrank(nodeOperator);

        mockToken.approve(address(realEstateRegistry), 1e18);
        realEstateRegistry.depositCollateralAndRegisterVault("nodeOpEns", address(mockToken), _signature, true);

        vm.stopPrank();

        vm.prank(admin);
        realEstateRegistry.approveOperatorVault("nodeOpEns");

        address vault = realEstateRegistry.getOperatorVault(nodeOperator);
        bool isApproved = realEstateRegistry.getOperatorInfo(nodeOperator).isApproved;
        require(vault != address(0) && isApproved, "Vault not registered");

        assert(ERC1967ProxyAutoUp(payable(vault)).getImplementation() == vovAddr);
        console.log(VerifyingOperatorVault(vault).isAutoUpdateEnabled());
    }

    function test_autoUpgradingChangesImplementation() public {
        bytes memory _signature = prepareAndSignSignature(nodeOperator, "nodeOpEns");

        vm.startPrank(nodeOperator);

        mockToken.approve(address(realEstateRegistry), 1e18);
        realEstateRegistry.depositCollateralAndRegisterVault("nodeOpEns", address(mockToken), _signature, true);

        vm.stopPrank();

        vm.prank(admin);
        realEstateRegistry.approveOperatorVault("nodeOpEns");

        address newVovImplementation = address(new VerifyingOperatorVault());

        vm.prank(admin);
        realEstateRegistry.updateVOVImplementation(newVovImplementation);

        console.log("Old:", vovAddr);
        console.log("New:", newVovImplementation);

        address vault = realEstateRegistry.getOperatorVault(nodeOperator);
        assertEq(ERC1967ProxyAutoUp(payable(vault)).getImplementation(), newVovImplementation);

        vm.prank(nodeOperator);
        VerifyingOperatorVault(vault).toggleAutoUpdate();

        assert(VerifyingOperatorVault(vault).isAutoUpdateEnabled() == false);
        assertEq(ERC1967ProxyAutoUp(payable(vault)).getImplementation(), newVovImplementation);

        // again new implementation
        address newVovImplementation2 = address(new VerifyingOperatorVault());
        vm.prank(admin);
        realEstateRegistry.updateVOVImplementation(newVovImplementation2);

        assert(newVovImplementation != newVovImplementation2);

        // the current implementation of vault should be the newVovImplementation
        assertEq(ERC1967ProxyAutoUp(payable(vault)).getImplementation(), newVovImplementation);

        // node operator turns on auto update
        vm.prank(nodeOperator);
        VerifyingOperatorVault(vault).toggleAutoUpdate();
        assert(VerifyingOperatorVault(vault).isAutoUpdateEnabled() == true);
        assertEq(ERC1967ProxyAutoUp(payable(vault)).getImplementation(), newVovImplementation2);
    }

    function test_forceAutoUpgrade() public {
        bytes memory _signature = prepareAndSignSignature(nodeOperator, "nodeOpEns");

        vm.startPrank(nodeOperator);

        mockToken.approve(address(realEstateRegistry), 1e18);
        realEstateRegistry.depositCollateralAndRegisterVault("nodeOpEns", address(mockToken), _signature, false);

        vm.stopPrank();

        vm.prank(admin);
        realEstateRegistry.approveOperatorVault("nodeOpEns");

        VerifyingOperatorVault vault = VerifyingOperatorVault(realEstateRegistry.getOperatorVault(nodeOperator));
        assertEq(vault.isAutoUpdateEnabled(), false);

        address newVovImplementation = address(new VerifyingOperatorVault());

        vm.prank(admin);
        realEstateRegistry.updateVOVImplementation(newVovImplementation);

        assertEq(ERC1967ProxyAutoUp(payable(address(vault))).getImplementation(), vovAddr);

        vm.prank(admin);
        realEstateRegistry.forceUpdateOperatorVault("nodeOpEns");

        assertEq(ERC1967ProxyAutoUp(payable(address(vault))).getImplementation(), newVovImplementation);
    }

    function prepareAndSignSignature(address _nodeOperaror, string memory _ensName)
        internal
        view
        returns (bytes memory _signature)
    {
        bytes32 digest = realEstateRegistry.prepareRegisterVaultHash(_nodeOperaror, _ensName);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        _signature = abi.encodePacked(r, s, v);
    }

    function test_setMaxSlippageMoreThanSlippage() public {
        bytes memory _signature = prepareAndSignSignature(nodeOperator, "nodeOpEns");
        vm.startPrank(nodeOperator);

        mockToken.approve(address(realEstateRegistry), 1e18);
        realEstateRegistry.depositCollateralAndRegisterVault("nodeOpEns", address(mockToken), _signature, true);

        vm.stopPrank();

        vm.prank(admin);
        realEstateRegistry.approveOperatorVault("nodeOpEns");

        address vault = realEstateRegistry.getOperatorVault(nodeOperator);

        uint256 moreThanSlippage = 100e18 + 1;
        vm.startPrank(nodeOperator);
        vm.expectRevert(VerifyingOperatorVault__IncorrectSlippage.selector);
        VerifyingOperatorVault(vault).setMaxSlippage(moreThanSlippage);
        vm.stopPrank();
    }

    // function test_setMaxSlippageLessOrEqualThanSlippage() public {
    //     bytes memory _signature = prepareAndSignSignature(nodeOperator, "nodeOpEns");
    //     vm.startPrank(nodeOperator);

    //     mockToken.approve(address(realEstateRegistry), 1e18);
    //     realEstateRegistry.depositCollateralAndRegisterVault("nodeOpEns", address(mockToken), _signature, true);

    //     vm.stopPrank();

    //     vm.prank(admin);
    //     realEstateRegistry.approveOperatorVault("nodeOpEns");

    //     address vault = realEstateRegistry.getOperatorVault(nodeOperator);

    //     uint256 lessThanSlippage = 100;
    //     vm.startPrank(nodeOperator);
    //     VerifyingOperatorVault(vault).setMaxSlippage(lessThanSlippage);
    //     vm.stopPrank();
    //     assertEq(VerifyingOperatorVault(vault).s_maxSlippage(), lessThanSlippage);
    // }

    function test_stakeCollateral() public {
        bytes memory _signature = prepareAndSignSignature(nodeOperator, "nodeOpEns");
        vm.startPrank(nodeOperator);

        mockToken.approve(address(realEstateRegistry), 1e18);
        realEstateRegistry.depositCollateralAndRegisterVault("nodeOpEns", address(mockToken), _signature, true);

        vm.stopPrank();

        vm.prank(admin);
        realEstateRegistry.approveOperatorVault("nodeOpEns");

        address vault = realEstateRegistry.getOperatorVault(nodeOperator);

        vm.startPrank(nodeOperator);
        vm.expectRevert("Amount must be greater than 0");
        VerifyingOperatorVault(vault).stakeCollateral(0);
        vm.stopPrank();
    }

    function test_slashVault() public {
        bytes memory _signature = prepareAndSignSignature(nodeOperator, "nodeOpEns");
        vm.startPrank(nodeOperator);

        mockToken.approve(address(realEstateRegistry), 1e18);
        realEstateRegistry.depositCollateralAndRegisterVault("nodeOpEns", address(mockToken), _signature, true);

        vm.stopPrank();

        vm.prank(admin);
        realEstateRegistry.approveOperatorVault("nodeOpEns");

        address vault = realEstateRegistry.getOperatorVault(nodeOperator);

        vm.startPrank(nodeOperator);
        vm.expectRevert();
        VerifyingOperatorVault(vault).slashVault();
        vm.stopPrank();
    }

    function test_getRealEstateRegistry() public {
        bytes memory _signature = prepareAndSignSignature(nodeOperator, "nodeOpEns");
        vm.startPrank(nodeOperator);

        mockToken.approve(address(realEstateRegistry), 1e18);
        realEstateRegistry.depositCollateralAndRegisterVault("nodeOpEns", address(mockToken), _signature, true);

        vm.stopPrank();

        vm.prank(admin);
        realEstateRegistry.approveOperatorVault("nodeOpEns");

        address vault = realEstateRegistry.getOperatorVault(nodeOperator);

        assertEq(VerifyingOperatorVault(vault).getRealEstateRegistry(), address(realEstateRegistry));
    }

    function test_getIsSlashed() public {
        bytes memory _signature = prepareAndSignSignature(nodeOperator, "nodeOpEns");
        vm.startPrank(nodeOperator);

        mockToken.approve(address(realEstateRegistry), 1e18);
        realEstateRegistry.depositCollateralAndRegisterVault("nodeOpEns", address(mockToken), _signature, true);

        vm.stopPrank();

        vm.prank(admin);
        realEstateRegistry.approveOperatorVault("nodeOpEns");

        address vault = realEstateRegistry.getOperatorVault(nodeOperator);

        assertEq(VerifyingOperatorVault(vault).getIsSlashed(), false);
    }

    function test_isAutoUpdateEnabled() public {
        bytes memory _signature = prepareAndSignSignature(nodeOperator, "nodeOpEns");
        vm.startPrank(nodeOperator);

        mockToken.approve(address(realEstateRegistry), 1e18);
        realEstateRegistry.depositCollateralAndRegisterVault("nodeOpEns", address(mockToken), _signature, true);

        vm.stopPrank();

        vm.prank(admin);
        realEstateRegistry.approveOperatorVault("nodeOpEns");

        address vault = realEstateRegistry.getOperatorVault(nodeOperator);

        assertEq(VerifyingOperatorVault(vault).isAutoUpdateEnabled(), true);
    }

    function testSetTokenForAnotherChainTokenNotOnBaseChain() public {
        address tokenNotOnBaseChain = makeAddr("tokenNotOnBaseChain");
        uint256 chainId = 11155111;
        address tokenOnAnotherChain = makeAddr("tokenOnAnotherChain");
        vm.startPrank(admin);
        vm.expectRevert(RealEstateRegistry__InvalidToken.selector);
        realEstateRegistry.setTokenForAnotherChain(tokenNotOnBaseChain, chainId, tokenOnAnotherChain);
        vm.stopPrank();
    }

    function testSetTokenForAnotherChain() public {
        address tokenNotOnBaseChain = token[0];
        uint256 chainId = 11155111;
        address tokenOnAnotherChain = makeAddr("tokenOnAnotherChain");
        vm.startPrank(admin);
        realEstateRegistry.setTokenForAnotherChain(tokenNotOnBaseChain, chainId, tokenOnAnotherChain);
        vm.stopPrank();

        assertEq(realEstateRegistry.getAcceptedTokenOnChain(tokenNotOnBaseChain, chainId), tokenOnAnotherChain);
    }

    function testSetCollateralRequiredForOperator() public {
        uint256 newCollateral = 50_000;
        vm.startPrank(admin);
        realEstateRegistry.setCollateralRequiredForOperator(newCollateral);
        vm.stopPrank();

        assertEq(realEstateRegistry.getFiatCollateralRequiredForOperator(), newCollateral);
    }

    function testSetCollateralRequiredForOperatorLessThanOrMoreFIAT_COLLATERAL() public {
        uint256 newCollateral = 30_000;
        vm.startPrank(admin);
        vm.expectRevert(RealEstateRegistry__InvalidCollateral.selector);
        realEstateRegistry.setCollateralRequiredForOperator(newCollateral);
        vm.stopPrank();

        newCollateral = 1_30_000;
        vm.startPrank(admin);
        vm.expectRevert(RealEstateRegistry__InvalidCollateral.selector);
        realEstateRegistry.setCollateralRequiredForOperator(newCollateral);
        vm.stopPrank();
    }

    function testUpdateVOVImplementation() public {
        address newImplementation = makeAddr("newImplementation");
        vm.startPrank(admin);
        realEstateRegistry.updateVOVImplementation(newImplementation);
        vm.stopPrank();

        assertEq(realEstateRegistry.getOperatorVaultImplementation(), newImplementation);
    }

    function testSetSwapRouter() public {
        address newSwapRouter = makeAddr("newSwapRouter");
        vm.startPrank(admin);
        realEstateRegistry.setSwapRouter(newSwapRouter);
        vm.stopPrank();

        assertEq(realEstateRegistry.getSwapRouter(), newSwapRouter);
    }

    function testDepositCollateralAndRegisterVault() public {
        bytes memory _signature = prepareAndSignSignature(nodeOperator, "nodeOpEns");

        vm.startPrank(nodeOperator);

        mockToken.approve(address(realEstateRegistry), 1e18);
        realEstateRegistry.depositCollateralAndRegisterVault("nodeOpEns", address(mockToken), _signature, true);

        vm.stopPrank();

        vm.prank(admin);
        realEstateRegistry.approveOperatorVault("nodeOpEns");

        // address vault = realEstateRegistry.getOperatorVault(nodeOperator);
        bool isApproved = realEstateRegistry.getOperatorInfo(nodeOperator).isApproved;
        require(isApproved, "Vault not registered");

        vm.startPrank(slasher);
        realEstateRegistry.slashOperatorVault("nodeOpEns");
        vm.stopPrank();

        isApproved = realEstateRegistry.getOperatorInfo(nodeOperator).isApproved;
        require(!isApproved, "Vault registered");
    }
}
