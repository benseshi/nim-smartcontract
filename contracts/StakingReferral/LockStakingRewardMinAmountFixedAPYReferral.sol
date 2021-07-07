pragma solidity =0.8.0;

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

interface INimbusRouter {
    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);
}

interface ILockStakingRewards {
    function earned(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function stake(uint256 amount) external;
    function stakeFor(uint256 amount, address user) external;
    function getReward() external;
    function withdraw(uint256 nonce) external;
    function withdrawAndGetReward(uint256 nonce) external;
}

interface IERC20Permit {
    function permit(address owner, address spender, uint value, uint deadline, uint8 v, bytes32 r, bytes32 s) external;
}

interface INimbusReferralProgramUsers {
    function userIdByAddress(address user) external view returns (uint);
}

interface INimbusReferralProgramMarketing {
    function updateReferralProfitAmount(address user, address token, uint amount) external;
}

contract Ownable {
    address public owner;
    address public newOwner;

    event OwnershipTransferred(address indexed from, address indexed to);

    constructor() {
        owner = msg.sender;
        emit OwnershipTransferred(address(0), owner);
    }

    modifier onlyOwner {
        require(msg.sender == owner, "Ownable: Caller is not the owner");
        _;
    }

    function transferOwnership(address transferOwner) external onlyOwner {
        require(transferOwner != newOwner);
        newOwner = transferOwner;
    }

    function acceptOwnership() virtual external {
        require(msg.sender == newOwner);
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
        newOwner = address(0);
    }
}

contract ReentrancyGuard {
    /// @dev counter to allow mutex lock with only one SSTORE operation
    uint256 private _guardCounter;

    constructor () {
        // The counter starts at one to prevent changing it from zero to a non-zero
        // value, which is a more expensive operation.
        _guardCounter = 1;
    }

    modifier nonReentrant() {
        _guardCounter += 1;
        uint256 localCounter = _guardCounter;
        _;
        require(localCounter == _guardCounter, "ReentrancyGuard: reentrant call");
    }
}

library Address {
    function isContract(address account) internal view returns (bool) {
        // This method relies in extcodesize, which returns 0 for contracts in construction, 
        // since the code is only stored at the end of the constructor execution.

        uint256 size;
        // solhint-disable-next-line no-inline-assembly
        assembly { size := extcodesize(account) }
        return size > 0;
    }
}

library SafeERC20 {
    using Address for address;

    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        callOptionalReturn(token, abi.encodeWithSelector(token.transfer.selector, to, value));
    }

    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        callOptionalReturn(token, abi.encodeWithSelector(token.transferFrom.selector, from, to, value));
    }

    function safeApprove(IERC20 token, address spender, uint256 value) internal {
        require((value == 0) || (token.allowance(address(this), spender) == 0),
            "SafeERC20: approve from non-zero to non-zero allowance"
        );
        callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, value));
    }

    function safeIncreaseAllowance(IERC20 token, address spender, uint256 value) internal {
        uint256 newAllowance = token.allowance(address(this), spender) + value;
        callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, newAllowance));
    }

    function safeDecreaseAllowance(IERC20 token, address spender, uint256 value) internal {
        uint256 newAllowance = token.allowance(address(this), spender) - value;
        callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, newAllowance));
    }

    function callOptionalReturn(IERC20 token, bytes memory data) private {
        require(address(token).isContract(), "SafeERC20: call to non-contract");

        (bool success, bytes memory returndata) = address(token).call(data);
        require(success, "SafeERC20: low-level call failed");

        if (returndata.length > 0) { 
            require(abi.decode(returndata, (bool)), "SafeERC20: ERC20 operation did not succeed");
        }
    }
}

contract LockStakingRewardMinAmountFixedAPYReferral is ILockStakingRewards, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable rewardsToken;
    IERC20 public immutable stakingToken;
    uint256 public rewardRate;
    uint256 public referralRewardRate;
    uint256 public withdrawalCashbackRate;
    uint256 public stakingCashbackRate;
    uint256 public immutable lockDuration; 
    uint256 public constant rewardDuration = 365 days; 
    
    INimbusReferralProgramUsers public referralProgramUsers;
    INimbusReferralProgramMarketing public referralProgramMarketing;
     
    INimbusRouter public swapRouter;
    address public swapToken;                       
    uint public swapTokenAmountThresholdForStaking;

    bool public onlyAllowedAddresses;
    mapping(address => bool) public allowedAddresses;

    mapping(address => uint256) public weightedStakeDate;
    mapping(address => mapping(uint256 => uint256)) public stakeLocks;
    mapping(address => mapping(uint256 => uint256)) public stakeAmounts;
    mapping(address => mapping(uint256 => uint256)) public stakeAmountsRewardEquivalent;
    mapping(address => uint256) public stakeNonces;

    uint256 private _totalSupply;
    uint256 private _totalSupplyRewardEquivalent;
    mapping(address => uint256) private _balances;
    mapping(address => uint256) private _balancesRewardEquivalent;

    event RewardUpdated(uint256 reward);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event Rescue(address indexed to, uint amount);
    event RescueToken(address indexed to, address indexed token, uint amount);
    event WithdrawalCashbackSent(address indexed to, uint withdrawnAmount, uint cashbackAmout);
    event StakingCashbackSent(address indexed to, uint stakedAmount, uint cashbackAmout);

    constructor(
        address _rewardsToken,
        address _stakingToken,
        address _referralProgramUsers,
        address _referralProgramMarketing,
        uint _rewardRate,
        uint _referralRewardRate,
        uint _stakingCashbackRate,
        uint _withdrawalCashbackRate,
        uint _lockDuration,
        address _swapRouter,
        address _swapToken,
        uint _swapTokenAmount
    ) {
        rewardsToken = IERC20(_rewardsToken);
        stakingToken = IERC20(_stakingToken);
        referralProgramUsers = INimbusReferralProgramUsers(_referralProgramUsers);
        referralProgramMarketing = INimbusReferralProgramMarketing(_referralProgramMarketing);
        rewardRate = _rewardRate;
        referralRewardRate = _referralRewardRate;
        stakingCashbackRate = _stakingCashbackRate;
        withdrawalCashbackRate = _withdrawalCashbackRate;
        lockDuration = _lockDuration;
        swapRouter = INimbusRouter(_swapRouter);
        swapToken = _swapToken;
        swapTokenAmountThresholdForStaking = _swapTokenAmount;
    }

    function totalSupply() external view override returns (uint256) {
        return _totalSupply;
    }

    function totalSupplyRewardEquivalent() external view returns (uint256) {
        return _totalSupplyRewardEquivalent;
    }

    function balanceOf(address account) external view override returns (uint256) {
        return _balances[account];
    }
    
    function balanceOfRewardEquivalent(address account) external view returns (uint256) {
        return _balancesRewardEquivalent[account];
    }

    function earned(address account) public view override returns (uint256) {
        if(address(referralProgramUsers) == address(0) || referralProgramUsers.userIdByAddress(account) == 0) {
            return (_balancesRewardEquivalent[account] * (block.timestamp - weightedStakeDate[account]) * rewardRate) / (100 * rewardDuration);
        } else {
            return (_balancesRewardEquivalent[account] * (block.timestamp - weightedStakeDate[account]) * referralRewardRate) / (100 * rewardDuration);
        }
    }

    function isAmountMeetsMinThreshold(uint amount) public view returns (bool) {
        address[] memory path = new address[](2);
        path[0] = address(stakingToken);
        path[1] = swapToken;
        uint tokenAmount = swapRouter.getAmountsOut(amount, path)[1];
        return tokenAmount >= swapTokenAmountThresholdForStaking;
    }

    function stakeWithPermit(uint256 amount, uint deadline, uint8 v, bytes32 r, bytes32 s) external nonReentrant {
        require(amount > 0, "LockStakingRewardMinAmountFixedAPYReferral: Cannot stake 0");

        if(onlyAllowedAddresses) {
            require(allowedAddresses[msg.sender], "LockStakingRewardMinAmountFixedAPYReferral: Only allowed addresses.");
        }

        // permit
        IERC20Permit(address(stakingToken)).permit(msg.sender, address(this), amount, deadline, v, r, s);
        _stake(amount, msg.sender);
    }

    function stake(uint256 amount) external override nonReentrant {
        require(amount > 0, "LockStakingRewardMinAmountFixedAPYReferral: Cannot stake 0");

        if(onlyAllowedAddresses) {
            require(allowedAddresses[msg.sender], "LockStakingRewardMinAmountFixedAPYReferral: Only allowed addresses.");
        }
        
        _stake(amount, msg.sender);
    }

    function stakeFor(uint256 amount, address user) external override nonReentrant {
        require(amount > 0, "LockStakingRewardMinAmountFixedAPYReferral: Cannot stake 0");
        require(user != address(0), "LockStakingRewardMinAmountFixedAPYReferral: Cannot stake for zero address");

        if(onlyAllowedAddresses) {
            require(allowedAddresses[user], "LockStakingRewardMinAmountFixedAPYReferral: Only allowed addresses.");
        }

        _stake(amount, user);
    }

    function _stake(uint256 amount, address user) private {
        require(isAmountMeetsMinThreshold(amount), "LockStakingRewardMinAmountFixedAPYReferral: Amount is less than min stake");
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        uint amountRewardEquivalent = getEquivalentAmount(amount);
        _sendStakingCashback(user, amountRewardEquivalent);

        _totalSupply += amount;
        _totalSupplyRewardEquivalent += amountRewardEquivalent;
        uint previousAmount = _balances[user];
        uint newAmount = previousAmount + amount;
        weightedStakeDate[user] = (weightedStakeDate[user] * previousAmount / newAmount) + (block.timestamp * amount / newAmount);
        _balances[user] = newAmount;

        uint stakeNonce = stakeNonces[user]++;
        stakeAmounts[user][stakeNonce] = amount;
        stakeLocks[user][stakeNonce] = block.timestamp + lockDuration;
        
        stakeAmountsRewardEquivalent[user][stakeNonce] = amountRewardEquivalent;
        _balancesRewardEquivalent[user] += amountRewardEquivalent;
        referralProgramMarketing.updateReferralProfitAmount(user, address(stakingToken), amount);
        emit Staked(user, amount);
    }


    //A user can withdraw its staking tokens even if there is no rewards tokens on the contract account
    function withdraw(uint256 nonce) public override nonReentrant {
        require(stakeAmounts[msg.sender][nonce] > 0, "LockStakingRewardMinAmountFixedAPYReferral: This stake nonce was withdrawn");
        require(stakeLocks[msg.sender][nonce] < block.timestamp, "LockStakingRewardMinAmountFixedAPYReferral: Locked");
        uint amount = stakeAmounts[msg.sender][nonce];
        uint amountRewardEquivalent = stakeAmountsRewardEquivalent[msg.sender][nonce];
        _totalSupply -= amount;
        _totalSupplyRewardEquivalent -= amountRewardEquivalent;
        _balances[msg.sender] -= amount;
        _balancesRewardEquivalent[msg.sender] -= amountRewardEquivalent;
        stakingToken.safeTransfer(msg.sender, amount);
        _sendWithdrawalCashback(msg.sender, amountRewardEquivalent);
        stakeAmounts[msg.sender][nonce] = 0;
        stakeAmountsRewardEquivalent[msg.sender][nonce] = 0;
        emit Withdrawn(msg.sender, amount);
    }

    function getReward() public override nonReentrant {
        uint256 reward = earned(msg.sender);
        if (reward > 0) {
            weightedStakeDate[msg.sender] = block.timestamp;
            rewardsToken.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    function withdrawAndGetReward(uint256 nonce) external override {
        getReward();
        withdraw(nonce);
    }

    function getEquivalentAmount(uint amount) public view returns (uint) {
        address[] memory path = new address[](2);

        uint equivalent;
        if (stakingToken != rewardsToken) {
            path[0] = address(stakingToken);            
            path[1] = address(rewardsToken);
            equivalent = swapRouter.getAmountsOut(amount, path)[1];
        } else {
            equivalent = amount;   
        }
        
        return equivalent;
    }

    function getUserReferralId(address account) external view returns (uint256 id) {
        require(address(referralProgramUsers) != address(0), "LockStakingRewardSameTokenFixedAPYReferral: Referral Program was not added.");
        return referralProgramUsers.userIdByAddress(account);
    }

    function updateOnlyAllowedAddresses(bool allowance) external onlyOwner {
        onlyAllowedAddresses = allowance;
    }

    function updateAllowedAddress(address _address, bool allowance) public onlyOwner {
        require(_address != address(0), "LockStakingRewardMinAmountFixedAPYReferral: allowed address can't be equal to address(0)");
        allowedAddresses[_address] = allowance;
    }

    function updateAllowedAddresses(address[] memory addresses, bool[] memory allowances) external onlyOwner {
        require(addresses.length == allowances.length, "LockStakingRewardMinAmountFixedAPYReferral: Addresses and allowances arrays have different size.");

        for(uint i = 0; i < addresses.length; i++) {
            updateAllowedAddress(addresses[i], allowances[i]);
        }
    }

    function updateRewardAmount(uint256 reward) external onlyOwner {
        rewardRate = reward;
        emit RewardUpdated(reward);
    }

    function updateSwapRouter(address newSwapRouter) external onlyOwner {
        require(newSwapRouter != address(0), "LockStakingRewardMinAmountFixedAPYReferral: Address is zero");
        swapRouter = INimbusRouter(newSwapRouter);
    }

    function updateSwapToken(address newSwapToken) external onlyOwner {
        require(newSwapToken != address(0), "LockStakingRewardMinAmountFixedAPYReferral: Address is zero");
        swapToken = newSwapToken;
    }

    function updateStakeSwapTokenAmountThreshold(uint threshold) external onlyOwner {
        swapTokenAmountThresholdForStaking = threshold;
    }

    function updateRewardRate(uint256 _rewardRate) external onlyOwner {
        require(_rewardRate > 0, "LockStakingRewardFixedAPYReferral: Reward rate must be grater than 0");
        rewardRate = _rewardRate;
    }
    
    function updateReferralRewardRate(uint256 _referralRewardRate) external onlyOwner {
        require(_referralRewardRate >= rewardRate, "LockStakingRewardMinAmountFixedAPYReferral: Referral reward rate can't be lower than reward rate");
        referralRewardRate = _referralRewardRate;
    }
    
    function updateStakingCashbackRate(uint256 _stakingCashbackRate) external onlyOwner {
        //Staking cahsback can be equal to 0
        require(_stakingCashbackRate >= 0, "LockStakingRewardMinAmountFixedAPYReferral: Staking cashback rate can't be lower than 0");
        stakingCashbackRate = _stakingCashbackRate;
    }
    
    function updateWithdrawalCashbackRate(uint256 _withdrawalCashbackRate) external onlyOwner {
        //Withdrawal cahsback can be equal to 0
        require(_withdrawalCashbackRate >= 0, "LockStakingRewardMinAmountFixedAPYReferral: Withdrawal cashback rate can't be lower than 0");
        withdrawalCashbackRate = _withdrawalCashbackRate;
    }
    
    function updateReferralProgramUsers(address _referralProgramUsers) external onlyOwner {
        require(_referralProgramUsers != address(0), "LockStakingRewardMinAmountFixedAPYReferral: Referral program users address can't be equal to address(0)");
        referralProgramUsers = INimbusReferralProgramUsers(_referralProgramUsers);
    }

    function updateReferralProgramMarketing(address _referralProgramMarketing) external onlyOwner {
        require(_referralProgramMarketing != address(0), "LockStakingRewardFixedAPYReferral: Referral program marketing address can't be equal to address(0)");
        referralProgramMarketing = INimbusReferralProgramMarketing(_referralProgramMarketing);
    }

    function rescue(address to, address token, uint256 amount) external onlyOwner {
        require(to != address(0), "LockStakingRewardMinAmountFixedAPYReferral: Cannot rescue to the zero address");
        require(amount > 0, "LockStakingRewardMinAmountFixedAPYReferral: Cannot rescue 0");
        require(token != address(stakingToken), "LockStakingRewardMinAmountFixedAPYReferral: Cannot rescue staking token");
        //owner can rescue rewardsToken if there is spare unused tokens on staking contract balance

        IERC20(token).safeTransfer(to, amount);
        emit RescueToken(to, address(token), amount);
    }

    function rescue(address payable to, uint256 amount) external onlyOwner {
        require(to != address(0), "LockStakingRewardMinAmountFixedAPYReferral: Cannot rescue to the zero address");
        require(amount > 0, "LockStakingRewardMinAmountFixedAPYReferral: Cannot rescue 0");

        to.transfer(amount);
        emit Rescue(to, amount);
    }

    function _sendWithdrawalCashback(address account, uint _withdrawalAmount) internal {
        if(address(referralProgramUsers) != address(0) && referralProgramUsers.userIdByAddress(account) != 0) {
            uint256 cashbackAmount = (_withdrawalAmount * withdrawalCashbackRate) / 100;
            rewardsToken.safeTransfer(account, cashbackAmount);
            emit WithdrawalCashbackSent(account, _withdrawalAmount, cashbackAmount);
        }
    }
    
    function _sendStakingCashback(address account, uint _stakingAmount) internal {
        if(address(referralProgramUsers) != address(0) && referralProgramUsers.userIdByAddress(account) != 0) {
            uint256 cashbackAmount = (_stakingAmount * stakingCashbackRate) / 100;
            rewardsToken.safeTransfer(account, cashbackAmount);
            emit StakingCashbackSent(account, _stakingAmount, cashbackAmount);
        }
    }
}