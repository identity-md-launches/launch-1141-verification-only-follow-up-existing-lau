// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title IMD Index (IMDEX) launch token
/// @notice Fixed-supply ERC-20. The whole supply is minted once, to the deployer, and nothing can
/// change it afterwards: there is no mint, owner, pause, blocklist, fee or upgrade path.
contract LaunchToken is ERC20 {
    /// @notice 1,000,000,000 tokens with 18 decimals.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 1e18;

    constructor() ERC20("IMD Index", "IMDEX") {
        _mint(msg.sender, TOTAL_SUPPLY);
    }
}
