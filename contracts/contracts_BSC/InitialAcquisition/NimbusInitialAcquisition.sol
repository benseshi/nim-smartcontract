pragma solidity =0.8.0;

interface IBEP20 {
    function totalSupply() external view returns (uint256);
    function decimals() external view returns (uint8);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function getOwner() external view returns (address);

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
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

    function getOwner() external view returns (address) {
        return owner;
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

abstract contract Pausable is Ownable {
    event Paused(address account);
    event Unpaused(address account);

    bool private _paused;

    constructor () {
        _paused = false;
    }

    function paused() public view returns (bool) {
        return _paused;
    }

    modifier whenNotPaused() {
        require(!_paused, "Pausable: paused");
        _;
    }

    modifier whenPaused() {
        require(_paused, "Pausable: not paused");
        _;
    }


    function pause() external onlyOwner whenNotPaused {
        _paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner whenPaused {
        _paused = false;
        emit Unpaused(msg.sender);
    }
}

interface INBU is IBEP20 {
    function give(address recipient, uint256 amount, uint vesterId) external;
}

interface INimbusReferralProgram {
    function userSponsorByAddress(address user)  external view returns (uint);
    function userIdByAddress(address user) external view returns (uint);
    function userAddressById(uint id) external view returns (address);
    function userSponsorAddressByAddress(address user) external view returns (address);
}

interface INimbusStakingPool {
    function stakeFor(uint amount, address user) external;
    function balanceOf(address account) external view returns (uint256);
    function stakingToken() external view returns (IBEP20);
}

interface INBU_WBNB {
    function deposit() external payable;
    function transfer(address to, uint value) external returns (bool);
    function withdraw(uint) external;
}

interface INimbusRouter {
    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);
}

interface INimbusReferralProgramMarketing {
    function registerUser(address user, uint sponsorId) external returns(uint userId);
}

contract NimbusInitialAcquisition is Ownable, Pausable {
    INBU public immutable NBU;
    address public immutable NBU_WBNB;
    INimbusReferralProgram public referralProgram;
    INimbusReferralProgramMarketing public referralProgramMarketing;
    INimbusStakingPool[] public stakingPoolsSponsor;   //staking pools for checking sponsor balances

    mapping(uint => INimbusStakingPool) public stakingPools;

    address public recipient;                      
   
    INimbusRouter public swapRouter;                
    mapping (address => bool) public allowedTokens;
    address public swapToken;                       
    uint public swapTokenAmountForBonusThreshold;  
    
    uint public sponsorBonus;
    mapping(address => uint) public unclaimedBonusBases;

    bool public useWeightedRates;
    mapping(address => uint) public weightedTokenNbuExchangeRates;

    event BuyNbuForToken(address indexed token, uint tokenAmount, uint nbuAmount, address indexed nbuRecipient);
    event BuyNbuForBnb(uint bnbAmount, uint nbuAmount, address indexed nbuRecipient);
    event ProcessSponsorBonus(address indexed sponsor, address indexed user, uint bonusAmount);
    event AddUnclaimedSponsorBonus(address indexed user, uint nbuAmount);

    event UpdateTokenNbuWeightedExchangeRate(address indexed token, uint newRate);
    event ToggleUseWeightedRates(bool useWeightedRates);
    event Rescue(address indexed to, uint amount);
    event RescueToken(address indexed token, address indexed to, uint amount); 

    constructor (address nbu, address router, address nbuWbnb, address) {
        NBU = INBU(nbu);
        NBU_WBNB = nbuWbnb;
        sponsorBonus = 10;
        swapRouter = INimbusRouter(router);
        recipient = address(this);
    }

    function availableInitialSupply() external view returns (uint) {
        return NBU.balanceOf(address(this));
    }

    function getNbuAmountForToken(address token, uint tokenAmount) public view returns (uint) { 
        if (!useWeightedRates) {
            address[] memory path = new address[](2);
            path[0] = token;
            path[1] = address(NBU);
            return swapRouter.getAmountsOut(tokenAmount, path)[1];
        } else {
            return tokenAmount * weightedTokenNbuExchangeRates[token] / 1e18;
        }  
    }

    function getNbuAmountForBnb(uint bnbAmount) public view returns (uint) { 
        return getNbuAmountForToken(NBU_WBNB, bnbAmount); 
    }

    function getTokenAmountForNbu(address token, uint nbuAmount) public view returns (uint) { 
        if (!useWeightedRates) { 
            address[] memory path = new address[](2);
            path[0] = address(NBU);
            path[1] = token;
            return swapRouter.getAmountsOut(nbuAmount, path)[1];
        } else {
            return nbuAmount * 1e18 / weightedTokenNbuExchangeRates[token];
        }
    }

    function getBnbAmountForNbu(uint nbuAmount) public view returns (uint) { 
        return getTokenAmountForNbu(NBU_WBNB, nbuAmount);
    }

    function currentBalance(address token) external view returns (uint) { 
        return INBU(token).balanceOf(address(this));
    }

    function _buyNbu(address token, uint tokenAmount, uint nbuAmount, address nbuRecipient, uint stakingPoolId) private {
        stakingPools[stakingPoolId].stakeFor(nbuAmount, nbuRecipient);
        emit BuyNbuForToken(token, tokenAmount, nbuAmount, nbuRecipient);
        _processSponsor(nbuAmount);
    }

    function _processSponsor(uint nbuAmount) private {
        address sponsorAddress = _getUserSponsorAddress();
        if (sponsorAddress != address(0)) { 
            uint minNbuAmountForBonus = getNbuAmountForToken(swapToken, swapTokenAmountForBonusThreshold);
            if (nbuAmount > minNbuAmountForBonus) {
                uint sponsorAmount = NBU.balanceOf(sponsorAddress);
                for (uint i; i < stakingPoolsSponsor.length; i++) {
                    if (sponsorAmount > minNbuAmountForBonus) break;
                    sponsorAmount += stakingPoolsSponsor[i].balanceOf(sponsorAddress);
                }
                
                if (sponsorAmount > minNbuAmountForBonus) {
                    uint bonusBase = nbuAmount + unclaimedBonusBases[msg.sender];
                    uint sponsorBonusAmount = bonusBase * sponsorBonus / 100;
                    NBU.give(sponsorAddress, sponsorBonusAmount, 3);
                    unclaimedBonusBases[msg.sender] = 0;
                    emit ProcessSponsorBonus(sponsorAddress, msg.sender, sponsorBonusAmount);
                } else {
                    unclaimedBonusBases[msg.sender] += nbuAmount;
                    emit AddUnclaimedSponsorBonus(msg.sender, nbuAmount);
                }
            } else {
                unclaimedBonusBases[msg.sender] += nbuAmount;
                emit AddUnclaimedSponsorBonus(msg.sender, nbuAmount);
            }
        } else {
            unclaimedBonusBases[msg.sender] += nbuAmount;
            emit AddUnclaimedSponsorBonus(msg.sender, nbuAmount);
        }
    }

    function _getUserSponsorAddress() private view returns (address) {
        if (address(referralProgram) == address(0)) {
            return address(0);
        } else {
            return referralProgram.userSponsorAddressByAddress(msg.sender);
        } 
    }

    function buyExactNbuForTokensAndRegister(address token, uint nbuAmount, address nbuRecipient, uint stakingPoolId, uint sponsorId) external whenNotPaused {
        require(sponsorId >= 1000000001, "NimbusInitialAcquisition: Sponsor id must be grater than 1000000000");
        referralProgramMarketing.registerUser(msg.sender, sponsorId);
        buyExactNbuForTokens(token, nbuAmount, nbuRecipient, stakingPoolId);
    }

    function buyExactNbuForTokensAndRegister(address token, uint nbuAmount, address nbuRecipient, uint stakingPoolId) external whenNotPaused {
        referralProgramMarketing.registerUser(msg.sender, 1000000001);
        buyExactNbuForTokens(token, nbuAmount, nbuRecipient, stakingPoolId);
    }

    function buyExactNbuForBnbAndRegister(uint nbuAmount, address nbuRecipient, uint stakingPoolId, uint sponsorId) external whenNotPaused {
        require(sponsorId >= 1000000001, "NimbusInitialAcquisition: Sponsor id must be grater than 1000000000");
        referralProgramMarketing.registerUser(msg.sender, sponsorId);
        buyExactNbuForBnb(nbuAmount, nbuRecipient, stakingPoolId);
    }

    function buyExactNbuForBnbAndRegister(uint nbuAmount, address nbuRecipient, uint stakingPoolId) external whenNotPaused {
        referralProgramMarketing.registerUser(msg.sender, 1000000001);
        buyExactNbuForBnb(nbuAmount, nbuRecipient, stakingPoolId);
    }

    function buyNbuForExactBnbAndRegister(address nbuRecipient, uint stakingPoolId, uint sponsorId) payable external whenNotPaused {
        require(sponsorId >= 1000000001, "NimbusInitialAcquisition: Sponsor id must be grater than 1000000000");
        referralProgramMarketing.registerUser(msg.sender, sponsorId);
        buyNbuForExactBnb(nbuRecipient, stakingPoolId);
    }

    function buyNbuForExactBnbAndRegister(address nbuRecipient, uint stakingPoolId) payable external whenNotPaused {
        referralProgramMarketing.registerUser(msg.sender, 1000000001);
        buyNbuForExactBnb(nbuRecipient, stakingPoolId);
    }

    function buyNbuForExactTokensAndRegister(address token, uint tokenAmount, address nbuRecipient, uint stakingPoolId, uint sponsorId) external whenNotPaused {
        require(sponsorId >= 1000000001, "NimbusInitialAcquisition: Sponsor id must be grater than 1000000000");
        referralProgramMarketing.registerUser(msg.sender, sponsorId);
        buyNbuForExactTokens(token, tokenAmount, nbuRecipient, stakingPoolId);
    }

    function buyNbuForExactTokensAndRegister(address token, uint tokenAmount, address nbuRecipient, uint stakingPoolId) external whenNotPaused {
        referralProgramMarketing.registerUser(msg.sender, 1000000001);
        buyNbuForExactTokens(token, tokenAmount, nbuRecipient, stakingPoolId);
    }
    
    function buyExactNbuForTokens(address token, uint nbuAmount, address nbuRecipient, uint stakingPoolId) public whenNotPaused {
        require(address(stakingPools[stakingPoolId]) != address(0), "NimbusInitialAcquisition: No staking pool with provided id");
        require(allowedTokens[token], "NimbusInitialAcquisition: Not allowed token");
        uint tokenAmount = getTokenAmountForNbu(token, nbuAmount);
        TransferHelper.safeTransferFrom(token, msg.sender, recipient, tokenAmount);
        _buyNbu(token, tokenAmount, nbuAmount, nbuRecipient, stakingPoolId);
    }

    function buyNbuForExactTokens(address token, uint tokenAmount, address nbuRecipient, uint stakingPoolId) public whenNotPaused {
        require(address(stakingPools[stakingPoolId]) != address(0), "NimbusInitialAcquisition: No staking pool with provided id");
        require(allowedTokens[token], "NimbusInitialAcquisition: Not allowed token");
        uint nbuAmount = getNbuAmountForToken(token, tokenAmount);
        TransferHelper.safeTransferFrom(token, msg.sender, recipient, tokenAmount);
        _buyNbu(token, tokenAmount, nbuAmount, nbuRecipient, stakingPoolId);
    }

    function buyNbuForExactBnb(address nbuRecipient, uint stakingPoolId) payable public whenNotPaused {
        require(address(stakingPools[stakingPoolId]) != address(0), "NimbusInitialAcquisition: No staking pool with provided id");
        require(allowedTokens[NBU_WBNB], "NimbusInitialAcquisition: Not allowed purchase for BNB");
        uint nbuAmount = getNbuAmountForBnb(msg.value);
        INBU_WBNB(NBU_WBNB).deposit{value: msg.value}();
        _buyNbu(NBU_WBNB, msg.value, nbuAmount, nbuRecipient, stakingPoolId);
    }

    function buyExactNbuForBnb(uint nbuAmount, address nbuRecipient, uint stakingPoolId) payable public whenNotPaused {
        require(address(stakingPools[stakingPoolId]) != address(0), "NimbusInitialAcquisition: No staking pool with provided id");
        require(allowedTokens[NBU_WBNB], "NimbusInitialAcquisition: Not allowed purchase for BNB");
        uint nbuAmountMax = getNbuAmountForBnb(msg.value);
        require(nbuAmountMax >= nbuAmount, "NimbusInitialAcquisition: Not enough BNB");
        uint bnbAmount = nbuAmountMax == nbuAmount ? msg.value : getBnbAmountForNbu(nbuAmount);
        INBU_WBNB(NBU_WBNB).deposit{value: bnbAmount}();
        _buyNbu(NBU_WBNB, bnbAmount, nbuAmount, nbuRecipient, stakingPoolId);
        // refund dust bnb, if any
        if (nbuAmountMax > nbuAmount) TransferHelper.safeTransferBNB(msg.sender, msg.value - bnbAmount);
    }

    function claimSponsorBonusesBatch(address[] memory users) external { 
        for (uint i; i < users.length; i++) {
            claimSponsorBonuses(users[i]);
        }
    }

    function claimSponsorBonuses(address user) public {
        require(unclaimedBonusBases[user] > 0, "NimbusInitialAcquisition: No unclaimed bonuses");
        uint userSponsor = referralProgram.userSponsorByAddress(user);
        require(userSponsor == referralProgram.userIdByAddress(msg.sender) && userSponsor != 0, "NimbusInitialAcquisition: Not user sponsor");
        
        uint minNbuAmountForBonus = getNbuAmountForToken(swapToken, swapTokenAmountForBonusThreshold);
        uint bonusBase = unclaimedBonusBases[user];
        require (bonusBase >= minNbuAmountForBonus, "NimbusInitialAcquisition: Bonus threshold not met");

        uint sponsorAmount = NBU.balanceOf(msg.sender);
        for (uint i; i < stakingPoolsSponsor.length; i++) {
            if (sponsorAmount > minNbuAmountForBonus) break;
            sponsorAmount += stakingPoolsSponsor[i].balanceOf(msg.sender);
        }
        
        require (sponsorAmount > minNbuAmountForBonus, "NimbusInitialAcquisition: Sponsor balance threshold for bonus not met");
        uint sponsorBonusAmount = bonusBase * sponsorBonus / 100;
        NBU.give(msg.sender, sponsorBonusAmount, 3);
        unclaimedBonusBases[user] = 0;
        emit ProcessSponsorBonus(msg.sender, user, sponsorBonusAmount);
    }
    


    //Admin functions
    function rescue(address payable to, uint256 amount) external onlyOwner {
        require(to != address(0), "NimbusInitialAcquisition: Can't be zero address");
        require(amount > 0, "NimbusInitialAcquisition: Should be greater than 0");
        TransferHelper.safeTransferBNB(to, amount);
        emit Rescue(to, amount);
    }

    function rescue(address to, address token, uint256 amount) external onlyOwner {
        require(to != address(0), "NimbusInitialAcquisition: Can't be zero address");
        require(amount > 0, "NimbusInitialAcquisition: Should be greater than 0");
        TransferHelper.safeTransfer(token, to, amount);
        emit RescueToken(token, to, amount);
    }

    function updateStakingPool(uint id, address stakingPool) public onlyOwner {
        _updateStakingPool(id, stakingPool);
    }

    function updateStakingPool(uint[] memory ids, address[] memory _stakingPools) external onlyOwner {
        require(ids.length == _stakingPools.length, "NimbusInitialAcquisition: Ids and staking pools arrays have different size.");
        
        for(uint i = 0; i < ids.length; i++) {
            _updateStakingPool(ids[i], _stakingPools[i]);
        }
    }

    function updateAllowedTokens(address token, bool isAllowed) external onlyOwner {
        require (token != address(0), "NimbusInitialAcquisition: Wrong addresses");
        allowedTokens[token] = isAllowed;
    }
    
    function updateRecipient(address recipientAddress) external onlyOwner {
        require(recipientAddress != address(0), "NimbusInitialAcquisition: Address is zero");
        recipient = recipientAddress;
    } 

    function updateSponsorBonus(uint bonus) external onlyOwner {
        sponsorBonus = bonus;
    }

    function updateReferralProgramContract(address newReferralProgramContract) external onlyOwner {
        require(newReferralProgramContract != address(0), "NimbusInitialAcquisition: Address is zero");
        referralProgram = INimbusReferralProgram(newReferralProgramContract);
    }

    function updateReferralProgramMarketingContract(address newReferralProgramMarketingContract) external onlyOwner {
        require(newReferralProgramMarketingContract != address(0), "NimbusInitialAcquisition: Address is zero");
        referralProgramMarketing = INimbusReferralProgramMarketing(newReferralProgramMarketingContract);
    }

    function updateStakingPoolAdd(address newStakingPool) external onlyOwner {
        INimbusStakingPool pool = INimbusStakingPool(newStakingPool);
        require (pool.stakingToken() == NBU, "NimbusInitialAcquisition: Wrong pool staking tokens");

        for (uint i; i < stakingPoolsSponsor.length; i++) {
            require (address(stakingPoolsSponsor[i]) != newStakingPool, "NimbusInitialAcquisition: Pool exists");
        }
        stakingPoolsSponsor.push(pool);
    }

    function updateStakingPoolRemove(uint poolIndex) external onlyOwner {
        stakingPoolsSponsor[poolIndex] = stakingPoolsSponsor[stakingPoolsSponsor.length - 1];
        stakingPoolsSponsor.pop();
    }

    function updateSwapRouter(address newSwapRouter) external onlyOwner {
        require(newSwapRouter != address(0), "NimbusInitialAcquisition: Address is zero");
        swapRouter = INimbusRouter(newSwapRouter);
    }

    function updateSwapToken(address newSwapToken) external onlyOwner {
        require(newSwapToken != address(0), "NimbusInitialAcquisition: Address is zero");
        swapToken = newSwapToken;
    }

    function updateSwapTokenAmountForBonusThreshold(uint threshold) external onlyOwner {
        swapTokenAmountForBonusThreshold = threshold;
    }

    function updateTokenNbuWeightedExchangeRate(address token, uint rate) external onlyOwner {
        weightedTokenNbuExchangeRates[token] = rate;
        emit UpdateTokenNbuWeightedExchangeRate(token, rate);
    }

    function toggleUseWeightedRates() external onlyOwner {
        useWeightedRates = !useWeightedRates;
        emit ToggleUseWeightedRates(useWeightedRates);
    }

    function _updateStakingPool(uint id, address stakingPool) private {
        require(id != 0, "NimbusInitialAcquisition: Staking pool id cant be equal to 0.");
        require(stakingPool != address(0), "NimbusInitialAcquisition: Staking pool address cant be equal to address(0).");

        stakingPools[id] = INimbusStakingPool(stakingPool);
        require(NBU.approve(stakingPool, type(uint256).max), "NimbusInitialAcquisition: Error on approving");
    }
}

library TransferHelper {
    function safeApprove(address token, address to, uint value) internal {
        // bytes4(keccak256(bytes('approve(address,uint256)')));
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0x095ea7b3, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'TransferHelper: APPROVE_FAILED');
    }

    function safeTransfer(address token, address to, uint value) internal {
        // bytes4(keccak256(bytes('transfer(address,uint256)')));
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0xa9059cbb, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'TransferHelper: TRANSFER_FAILED');
    }

    function safeTransferFrom(address token, address from, address to, uint value) internal {
        // bytes4(keccak256(bytes('transferFrom(address,address,uint256)')));
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0x23b872dd, from, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'TransferHelper: TRANSFER_FROM_FAILED');
    }

    function safeTransferBNB(address to, uint value) internal {
        (bool success,) = to.call{value:value}(new bytes(0));
        require(success, 'TransferHelper: BNB_TRANSFER_FAILED');
    }
}