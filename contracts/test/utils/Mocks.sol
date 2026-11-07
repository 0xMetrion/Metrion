// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MetrionShare} from "../../src/libraries/MetrionShare.sol";

/// @dev Exposes the library's internal functions so tests can call them with a gas limit.
contract ShareHarness {
    function effective(address controller, uint256 ceilingBps) external view returns (uint16) {
        return MetrionShare.effectiveShareBps(controller, ceilingBps);
    }

    function current(address controller) external view returns (uint256) {
        return MetrionShare.readCurrentShareBps(controller);
    }

    function terms(address controller) external view returns (address, uint256, address) {
        return MetrionShare.readPayoutTerms(controller);
    }

    function checkCeiling(address controller, uint256 ceilingBps) external view {
        MetrionShare.requireValidCeiling(controller, ceilingBps);
    }

    function split(uint256 gross, uint256 shareBps, uint256 jarBps, uint256 tipBps)
        external
        pure
        returns (MetrionShare.FlushSplit memory)
    {
        return MetrionShare.splitFlush(gross, shareBps, jarBps, tipBps);
    }

    function portion(uint256 payroll, uint256 weightBps) external pure returns (uint256) {
        return MetrionShare.portion(payroll, weightBps);
    }

    function bpsOf(uint256 amount, uint256 bps) external pure returns (uint256) {
        return MetrionShare.bpsOf(amount, bps);
    }
}

contract MockFeeAdapter {
    // Named after Uniswap's V4FeeAdapter getter.
    // forge-lint: disable-next-line(mixed-case-variable)
    address public TOKEN_JAR;

    constructor(address jar) {
        TOKEN_JAR = jar;
    }

    function setJar(address jar) external {
        TOKEN_JAR = jar;
    }
}

/// @dev Returns whatever it is told to, including values no real controller would.
contract MockController {
    uint256 public shareRaw;
    uint256 public minCeilingRaw;
    address public treasuryAddr;
    uint256 public jarRaw;
    address public jarAddr;

    function set(uint256 share_, uint256 minCeiling_) external {
        shareRaw = share_;
        minCeilingRaw = minCeiling_;
    }

    function setTerms(address treasury_, uint256 jar_, address jarAddr_) external {
        treasuryAddr = treasury_;
        jarRaw = jar_;
        jarAddr = jarAddr_;
    }

    function currentShareBps() external view returns (uint256) {
        return shareRaw;
    }

    function minCeilingBps() external view returns (uint256) {
        return minCeilingRaw;
    }

    function payoutTerms() external view returns (address, uint256, address) {
        return (treasuryAddr, jarRaw, jarAddr);
    }
}

contract RevertingController {
    fallback() external {
        revert("no");
    }
}

contract GasBurnerController {
    fallback() external {
        while (true) {}
    }
}

contract ShortReturnController {
    fallback() external {
        assembly {
            mstore(0x00, 0xff)
            return(0x1f, 0x01)
        }
    }
}

/// @dev Returns 10 KiB whose first word is 250. A reader that copies it all pays for it.
contract ReturnBombController {
    fallback() external {
        assembly {
            mstore(0x00, 250)
            return(0x00, 10240)
        }
    }
}

/// @dev Reports the gas it was handed, so a test can prove the stipend arrives in full.
contract GasMeterController {
    function currentShareBps() external view returns (uint256) {
        return gasleft();
    }

    function payoutTerms() external view returns (address, uint256, address) {
        return (address(uint160(gasleft())), 0, address(0));
    }
}

contract DirtyTermsController {
    fallback() external {
        assembly {
            mstore(0x00, not(0))
            mstore(0x20, 100)
            mstore(0x40, 0xBEEF)
            return(0x00, 0x60)
        }
    }
}

/// @dev An ETH recipient that can be told to refuse, and to burn gas while refusing.
contract ToggleReceiver {
    bool public accept = true;
    bool public burn;

    function setAccept(bool accept_) external {
        accept = accept_;
    }

    function setBurn(bool burn_) external {
        burn = burn_;
    }

    receive() external payable {
        if (burn) {
            while (true) {}
        }
        if (!accept) revert("refused");
    }
}
