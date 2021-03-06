pragma solidity ^0.6.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./IUniswapRouter.sol";
import "./IMasterchef.sol";

contract StrategyRamen is Ownable, Pausable {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /**
     * @dev Tokens Used:
     * {wbnb} - Required for liquidity routing when doing swaps.
     * {ramen} - Token that the strategy maximizes. The same token that users deposit in the vault.
     */
    address constant public wbnb = address(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    address constant public ramen = address(0x4F47A0d15c1E53F3d94c069C7D16977c29F9CB6B);

    /**
     * @dev Third Party Contracts:
     * {unirouter} - PancakeSwap unirouter
     * {masterchef} - MasterChef contract.
     */
    address constant public unirouter  = address(0x05fF2B0DB69458A0750badebc4f9e13aDd608C7F);
    address constant public masterchef = address(0x97DD424B4628C8D3bD7fCf3A4e974Cebba011651);

    /**
     * @dev Ramen Contracts:
     * {vault} - Address of the vault that controls the strategy's funds.
     */
    address constant public burnAddress = address(0x000000000000000000000000000000000000dEaD);
    address public vault;

    /**
     * @dev Distribution of fees earned. This allocations relative to the % implemented on chargeFees().
     * Current implementation separates 10% for profit fees.
     *
     * {REWARDS_FEE} - 9.5% goes to Ramen BuyBack and Burn.
     * {CALL_FEE} - 0.5% goes to whoever executes the harvest function as gas subsidy.
     * {MAX_FEE} - Aux const used to safely calc the correct amounts.
     */
    uint constant public REWARDS_FEE    = 950;
    uint constant public CALL_FEE       = 50;
    uint constant public MAX_FEE        = 1000;

    /**
     * @dev Routes we take to swap tokens using PancakeSwap.
     * {ramenToWbnbRoute} - Route we take to go from {ramen} into {wbnb}.
     * {wbnbToRamenRoute} - Route we take to go from {wbnb} into {ramen}.
     */
    address[] public ramenToWbnbRoute = [ramen, wbnb];
    address[] public wbnbToRamenRoute = [wbnb, ramen];

    /**
     * @dev Event that is fired each time someone harvests the strat.
     */
    event StratHarvest(address indexed harvester);

    /**
     * @dev Initializes the strategy with the token that it will look to maximize.
     * @param _vault Address to initialize {vault}
     */
    constructor(address _vault) public {
        vault = _vault;

        IERC20(ramen).safeApprove(masterchef, uint(-1));
        IERC20(ramen).safeApprove(unirouter, uint(-1));
        IERC20(wbnb).safeApprove(unirouter, uint(-1));
    }

    /**
     * @dev Function that puts the funds to work.
     * It gets called whenever someone deposits in the strategy's vault contract.
     * It deposits ramen in the MasterChef to earn rewards in ramen.
     */
    function deposit() public whenNotPaused {
        uint256 ramenBal = IERC20(ramen).balanceOf(address(this));

        if (ramenBal > 0) {
            IMasterChef(masterchef).enterStaking(ramenBal);
        }
    }

    /**
     * @dev It withdraws ramen from the MasterChef and sends it to the vault.
     */
    function withdraw(uint256 _amount) external {
        require(msg.sender == vault, "!vault");

        uint256 ramenBal = IERC20(ramen).balanceOf(address(this));

        if (ramenBal < _amount) {
            IMasterChef(masterchef).leaveStaking(_amount.sub(ramenBal));
            ramenBal = IERC20(ramen).balanceOf(address(this));
        }

        if (ramenBal > _amount) {
            ramenBal = _amount;    
        }

        IERC20(ramen).safeTransfer(vault, ramenBal);
        
    }

    /**
     * @dev Core function of the strat, in charge of collecting and re-investing rewards.
     * 1. It claims rewards from the MasterChef
     * 2. It charges the system fee
     * 3. It re-invests the remaining profits.
     */
    function harvest() external whenNotPaused {
        require(!Address.isContract(msg.sender), "!contract");
        IMasterChef(masterchef).leaveStaking(0);
        chargeFees();
        deposit();

        emit StratHarvest(msg.sender);
    }

    /**
     * @dev Takes out 10% as system fees from the rewards. 
     * 0.5% -> Call Fee
     * 9.5% -> BuyBack and Burn
     */
    function chargeFees() internal {
        uint256 toWbnb = IERC20(ramen).balanceOf(address(this)).mul(10).div(100);
        IUniswapRouter(unirouter).swapExactTokensForTokens(toWbnb, 0, ramenToWbnbRoute, address(this), now.add(600));
    
        uint256 wbnbBal = IERC20(wbnb).balanceOf(address(this));
        
        uint256 callFee = wbnbBal.mul(CALL_FEE).div(MAX_FEE);
        IERC20(wbnb).safeTransfer(msg.sender, callFee);
        
        uint256 rewardsFee = wbnbBal.mul(REWARDS_FEE).div(MAX_FEE);
        IUniswapRouter(unirouter).swapExactTokensForTokens(rewardsFee, 0, wbnbToRamenRoute, burnAddress, now.add(600));
    }

    /**
     * @dev Function to calculate the total underlaying {ramen} held by the strat.
     * It takes into account both the funds in hand, as the funds allocated in the MasterChef.
     */
    function balanceOf() public view returns (uint256) {
        return balanceOfRamen().add(balanceOfPool());
    }

    /**
     * @dev It calculates how much {ramen} the contract holds.
     */
    function balanceOfRamen() public view returns (uint256) {
        return IERC20(ramen).balanceOf(address(this));
    }

    /**
     * @dev It calculates how much {ramen} the strategy has allocated in the MasterChef
     */
    function balanceOfPool() public view returns (uint256) {
        (uint256 _amount, ) = IMasterChef(masterchef).userInfo(0, address(this));
        return _amount;
    }

    /**
     * @dev Function that has to be called as part of strat migration. It sends all the available funds back to the
     * vault, ready to be migrated to the new strat.
     */
    function retireStrat() external {
        require(msg.sender == vault, "!vault");

        IMasterChef(masterchef).emergencyWithdraw(0);

        uint256 ramenBal = IERC20(ramen).balanceOf(address(this));
        IERC20(ramen).transfer(vault, ramenBal);
    }

    /**
     * @dev Pauses deposits. Withdraws all funds from the MasterChef, leaving rewards behind
     */
    function panic() public onlyOwner {
        pause();
        IMasterChef(masterchef).emergencyWithdraw(0);
    }

    /**
     * @dev Pauses the strat.
     */
    function pause() public onlyOwner {
        _pause();

        IERC20(ramen).safeApprove(masterchef, 0);
        IERC20(ramen).safeApprove(unirouter, 0);
        IERC20(wbnb).safeApprove(unirouter, 0);
    }

    /**
     * @dev Unpauses the strat.
     */
    function unpause() external onlyOwner {
        _unpause();

        IERC20(ramen).safeApprove(masterchef, uint(-1));
        IERC20(ramen).safeApprove(unirouter, uint(-1));
        IERC20(wbnb).safeApprove(unirouter, uint(-1));
    }

}
