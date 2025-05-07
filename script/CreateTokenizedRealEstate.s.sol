// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {AssetTokenizationManager} from "../src/AssetTokenizationManager.sol";
import {USDC} from "../test/mocks/MockUSDCToken.sol";
import {EstateVerification} from "../src/Computation/EstateVerification.sol";

contract CreateTokenizedRealEstate is Script {
    function run() external {
        uint256 ownerKey = vm.envUint("PRIVATE_KEY");
        address asset = address(0);  // feed your asset address here
        vm.startBroadcast(ownerKey);
        
        address usdc = address(0);   // feed your USDC address here
        address owner = address(0);  // feed admin address here
        
        USDC(usdc).mint(owner, 1000000e18);
        USDC(usdc).approve(asset, type(uint256).max);

        address estateVerification = AssetTokenizationManager(asset).getEstateVerification();

        EstateVerification.TokenizeFunctionCallRequest memory request;
        request.estateOwner = owner;
        request.chainsToDeploy = new uint256[](2);
        request.chainsToDeploy[0] = 43113;
        request.chainsToDeploy[1] = 11155111;
        request.paymentToken = usdc;
        request.estateOwnerAcrossChain = new address[](2);
        request.estateOwnerAcrossChain[0] = owner;
        request.estateOwnerAcrossChain[1] = owner;

        uint256 estateCost = 1e6 * 1e18;
        uint256 percentageToTokenize = 100e18;
        bool isApproved = true;
        bytes memory _saltBytes = bytes("6969");
        address _verifyingOperator = address(0);    // feed your verifying operator address here

        bytes memory response = abi.encode(estateCost, percentageToTokenize, isApproved, _saltBytes, _verifyingOperator);

        EstateVerification(estateVerification).createTestRequestIdResponse(request, response);

        vm.stopBroadcast();
    }
}