// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @dev Same ledger rules as the verified PonsV2FeeEscrow: credit is permissionless, claims pay
///      msg.sender everything and revert NoBalance at zero.
contract MockPonsEscrow {
    error NoBalance();
    error TransferFailed();

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public balanceOfToken;

    function credit(address recipient) external payable {
        balanceOf[recipient] += msg.value;
    }

    function creditToken(address recipient, address token, uint256 amount) external {
        require(MockERC20(token).transferFrom(msg.sender, address(this), amount), "pull");
        balanceOfToken[recipient][token] += amount;
    }

    function claim() external returns (uint256 amount) {
        amount = balanceOf[msg.sender];
        if (amount == 0) revert NoBalance();
        balanceOf[msg.sender] = 0;
        (bool ok,) = payable(msg.sender).call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    function claimToken(address token) external returns (uint256 amount) {
        amount = balanceOfToken[msg.sender][token];
        if (amount == 0) revert NoBalance();
        balanceOfToken[msg.sender][token] = 0;
        require(MockERC20(token).transfer(msg.sender, amount), "push");
    }
}

/// @dev sweepPoolFees with the verified hook's access rules: operator or current creator, and the
///      creator only when no internal swap is needed. Pays 70% to the creator, 30% to protocol.
contract MockPonsMemeHook {
    error NotFeeSweepOperator();
    error InternalSwapRequiresOperator();
    error UnknownPool();

    MockPonsEscrow public immutable feeEscrow;
    address public buybackVault;
    address public feeSweepOperator;
    address public protocolFeeRecipient = address(0xBEEF);

    mapping(bytes32 => address) public creatorOf;
    mapping(bytes32 => uint256) public pendingEth;
    mapping(bytes32 => uint256) public pendingMemecoin;

    constructor(MockPonsEscrow escrow_, address operator_) {
        feeEscrow = escrow_;
        feeSweepOperator = operator_;
    }

    function setBuybackVault(address v) external {
        buybackVault = v;
    }

    function setPool(bytes32 poolId, address creator, uint256 memecoinPending) external payable {
        creatorOf[poolId] = creator;
        pendingEth[poolId] += msg.value;
        pendingMemecoin[poolId] = memecoinPending;
    }

    function sweepPoolFees(bytes32 poolId, uint256, uint256) external {
        address creator = creatorOf[poolId];
        if (creator == address(0)) revert UnknownPool();
        bool isOperator = msg.sender == feeSweepOperator;
        if (!isOperator && msg.sender != creator) revert NotFeeSweepOperator();
        if (!isOperator && pendingMemecoin[poolId] != 0) revert InternalSwapRequiresOperator();
        uint256 total = pendingEth[poolId];
        if (total == 0) return;
        pendingEth[poolId] = 0;
        pendingMemecoin[poolId] = 0;
        uint256 protocol = (total * 3_000) / 10_000;
        feeEscrow.credit{value: total - protocol}(creator);
        feeEscrow.credit{value: protocol}(protocolFeeRecipient);
    }
}

/// @dev release with the verified vault's access rule: only the vest's beneficiaries.
contract MockPonsBuybackVault {
    error NotVestBeneficiary();

    MockPonsEscrow public immutable feeEscrow;
    mapping(address token => address) public creatorRecipient;
    mapping(address token => uint256) public releasable;

    constructor(MockPonsEscrow escrow_) {
        feeEscrow = escrow_;
    }

    function setVest(address token, address creator, uint256 amount) external {
        creatorRecipient[token] = creator;
        releasable[token] = amount;
        MockERC20(token).mint(address(this), amount);
    }

    function release(address token) external returns (uint256 released) {
        if (msg.sender != creatorRecipient[token]) revert NotVestBeneficiary();
        released = releasable[token];
        if (released == 0) return 0;
        releasable[token] = 0;
        require(MockERC20(token).approve(address(feeEscrow), released), "approve");
        feeEscrow.creditToken(msg.sender, token, released);
    }
}

/// @dev The launch factory's recipient rules from the verified source: only the current creator
///      fee recipient may hand it on or enable buyback, and the factory owner may only disable.
contract MockPonsLaunchFactory {
    error NotCreatorFeeRecipient();
    error NotBuybackController();
    error ZeroAddress();

    address public owner = address(0x0B0B);
    mapping(address token => address) public creatorFeeRecipient;
    mapping(address token => bool) public buybackEnabled;

    function launch(address token, address recipient) external {
        creatorFeeRecipient[token] = recipient;
    }

    function transferCreatorFeeRecipient(address token, address newRecipient) external {
        if (msg.sender != creatorFeeRecipient[token]) revert NotCreatorFeeRecipient();
        if (newRecipient == address(0)) revert ZeroAddress();
        creatorFeeRecipient[token] = newRecipient;
    }

    function setBuybackEnabled(address token, bool enabled) external {
        bool isCreator = msg.sender == creatorFeeRecipient[token];
        if (!isCreator && msg.sender != owner) revert NotBuybackController();
        if (enabled && !isCreator) revert NotBuybackController();
        buybackEnabled[token] = enabled;
    }
}

/// @dev USDT-style: transfer returns nothing.
contract NoReturnToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }
}

/// @dev Refuses transfers to blocked addresses, the way a frozen USDG account would.
contract BlockingToken is MockERC20 {
    mapping(address => bool) public blocked;

    constructor() MockERC20("Blocking USD", "BUSD", 6) {}

    function setBlocked(address who, bool b) external {
        blocked[who] = b;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        require(!blocked[to], "blocked");
        return super.transfer(to, amount);
    }
}
