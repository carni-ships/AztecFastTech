// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script, console2} from "forge-std/Script.sol";
import {ProverBatcher} from "../src/ProverBatcher.sol";

/// @notice Deploy ProverBatcher to mainnet
/// @dev Run with:
///   forge script script/DeployProverBatcher.s.sol:DeployProverBatcher \
///     --rpc-url <MAINNET_RPC> \
///     --private-key <DEPLOYER_KEY> \
///     --broadcast \
///     -vvv
contract DeployProverBatcher is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address rollup = vm.envAddress("ROLLUP_ADDRESS");
        address aztecToken = vm.envAddress("AZTEC_TOKEN_ADDRESS");
        address swapRouter = vm.envAddress("SWAP_ROUTER_ADDRESS");
        address weth = vm.envAddress("WETH_ADDRESS");
        address operator = vm.envAddress("OPERATOR_ADDRESS");

        vm.startBroadcast(deployerPrivateKey);

        ProverBatcher batcher = new ProverBatcher(
            rollup,
            aztecToken,
            swapRouter,
            weth,
            operator
        );

        vm.stopBroadcast();

        console2.log("ProverBatcher deployed at:", address(batcher));
        console2.log("Operator:", operator);
    }
}
