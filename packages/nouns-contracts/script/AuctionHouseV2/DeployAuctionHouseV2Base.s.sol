// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

import 'forge-std/Script.sol';
import { NounsAuctionHouse } from '../../contracts/NounsAuctionHouse.sol';
import { NounsAuctionHouseV2 } from '../../contracts/NounsAuctionHouseV2.sol';
import { NounsAuctionHousePreV2Migration } from '../../contracts/NounsAuctionHousePreV2Migration.sol';
import { OptimizedScript } from '../OptimizedScript.s.sol';

abstract contract DeployAuctionHouseV2Base is OptimizedScript {
    NounsAuctionHouse public immutable auctionV1;

    constructor(address _auctionHouseProxy) {
        auctionV1 = NounsAuctionHouse(payable(_auctionHouseProxy));
    }

    function run() public returns (NounsAuctionHouseV2 newLogic, NounsAuctionHousePreV2Migration migratorLogic) {
        requireDefaultProfile();
        uint256 deployerKey = vm.envUint('DEPLOYER_PRIVATE_KEY');

        vm.startBroadcast(deployerKey);

        newLogic = new NounsAuctionHouseV2(auctionV1.nouns(), auctionV1.weth(), 0x26DD80569a8B23768A1d80869Ed7339e07595E85, 0x6CC14824Ea2918f5De5C2f75A9Da968ad4BD6344);
        migratorLogic = new NounsAuctionHousePreV2Migration();

        vm.stopBroadcast();
    }
}
