// SPDX-License-Identifier: MIT

pragma experimental ABIEncoderV2;
pragma solidity 0.6.12;

import "@openzeppelinV3/contracts/token/ERC20/IERC20.sol";
import "@openzeppelinV3/contracts/math/SafeMath.sol";
import "@openzeppelinV3/contracts/math/Math.sol";
import "@openzeppelinV3/contracts/utils/Address.sol";
import "@openzeppelinV3/contracts/token/ERC20/SafeERC20.sol";
import {BaseStrategy, StrategyParams} from "@yearnvaults/contracts/BaseStrategy.sol";

import "../../interfaces/curve/ICurve.sol";
import "../../interfaces/curve/IGauge.sol";
import "../../interfaces/uniswap/Uni.sol";
import "../../interfaces/yearn/Vault.sol";


contract Strategy3PoolMTA is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    address public mta;
    address public threePool;
    address public crv;
    address public unirouter;
    address public threePoolMTA;
    address public gauge;
    address public proxy;
    address public voter;
    address public musd;
    address public weth;
    address public dai;
    string public constant override name = "Strategy3PoolMTA";

    uint256 public keepCRV = 1000;
    //uint256 public performanceFee = 450;
    //uint256 public strategistReward = 50;
    //uint256 public withdrawalFee = 50;
    uint256 public constant FEE_DENOMINATOR = 10000;

    constructor(
        address _vault,
        address _mta,
        address _threePool,
        address _crv,
        address _threePoolMTA,
        address _gauge,
        address _unirouter,
        address _proxy,
        address _voter,
        address _musd,
        address _weth,
        address _dai
    ) public BaseStrategy(_vault) {
        mta = _mta;
        threePool = _threePool;
        crv = _crv;
        threePoolMTA = _threePoolMTA;
        gauge = _gauge;
        unirouter = _unirouter;
        proxy = _proxy;
        voter = _voter;
        musd = _musd;
        weth = _weth;
        dai = _dai;

        IERC20(threePool).safeApprove(threePoolMTA, uint256(-1));
        IERC20(threePoolMTA).safeApprove(gauge, uint256(-1));
        IERC20(mta).safeApprove(unirouter, uint256(-1));
        IERC20(crv).safeApprove(unirouter, uint256(-1));
        IERC20(threePoolMTA).safeApprove(proxy, uint256(-1));
        IERC20(musd).safeApprove(threePoolMTA, uint256(-1));
    }

    function protectedTokens() internal override view returns (address[] memory) {
        address[] memory protected = new address[](5);
        // threePool is protected by default as "want"
        protected[0] = threePoolMTA;
        protected[1] = mta;
        protected[2] = crv;
        protected[3] = weth;
        protected[4] = dai;
        return protected;
    }

    // returns sum of all assets, realized and unrealized
    function estimatedTotalAssets() public override view returns (uint256) {
        return balanceOfWant().add(balanceOfStake()).add(balanceOfPool());
    }

    function prepareReturn(uint256 _debtOutstanding) internal override returns (uint256 _profit) {
       // We might need to return want to the vault
        if (_debtOutstanding > 0) {
           liquidatePosition(_debtOutstanding);
        }

        // claim/sell MTA and curve
        // claim MTA
        IGauge(gauge).claim_rewards(address(voter));
        //claim crv
        proxy(proxy).harvest(gauge);
        uint256 crvBalance = IERC20(crv).balanceOf(address(this));
        if (crvBalance > 0) {
            uint256 _keepCRV = (crvBalance).mul(keepCRV).div(FEE_DENOMINATOR);
            IERC20(crv).safeTransfer(voter, _keepCRV);
           uint256 swapCRV = (crvBalance).min(_keepCRV);
            swapCRVto3Pool(swapCRV);
        }

        voter(voter).withdraw(IERC20(mta));

        uint256 balanceOfWantBefore = balanceOfWant();

        // Final profit is want generated in the swap if ethProfit > 0
        _profit = balanceOfWant().sub(balanceOfWantBefore);
    }

    //todo: this
    function adjustPosition(uint256 _debtOutstanding) internal override {
       //emergency exit is dealt with in prepareReturn
        if (emergencyExit) {
          return;
       }

       // Invest the rest of the want
       uint256 _wantAvailable = balanceOfWant().sub(_debtOutstanding);
        if (_wantAvailable > 0) {
            uint256 _availableFunds = IERC20(want).balanceOf(address(this));
            IERC20(want).safeTransfer(proxy, _availableFunds);
            proxy(proxy).deposit(gauge, want);
        }
    }

    // withdraws everything that is currently in the strategy, regardless of values.
    function exitPosition(uint256 _debtOutstanding)
        internal
        override
        returns (
          uint256 _profit,
          uint256 _loss,
          uint256 _debtPayment
        ) {
        //uint256 y3PoolBalance = IERC20(y3Pool).balanceOf(address(this));
        uint256 gaugeBalance = IGauge(gauge).balanceOf(address(this));
        IGauge(gauge).withdraw(gaugeBalance);
        uint256 threePoolMTABalance = IERC20(threePoolMTA).balanceOf(address(this));
        ICurve(threePoolMTA).remove_liquidity_one_coin(threePoolMTABalance, 2, 0);
        }

    //this math only deals with want, which is 3pool.
    function liquidatePosition(uint256 _amountNeeded) internal override returns (uint256 _amountFreed) {
        if (balanceOfWant() < _amountNeeded) {
            // We need to sell stakes to get back more want
            _withdrawSome(_amountNeeded.sub(balanceOfWant()));
        }

        // Since we might free more than needed, let's send back the min
        _amountFreed = Math.min(balanceOfWant(), _amountNeeded);
    }


    // withdraw some usdt from the vaults
    function _withdrawSome(uint256 _amount) internal returns (uint256) {
       uint256 _3poolMTAAmount = (_amount).mul(1e18).mul(ICurve(threePoolMTA).get_virtual_price());
       IGauge(gauge).withdraw(_3poolMTAAmount);
       uint256 _3PoolMTABalance = IERC20(threePoolMTA).balanceOf(address(this));
       uint256 _3PoolMTAPrice = (_3PoolMTABalance).mul(ICurve(threePoolMTA).get_virtual_price());
       ICurve(threePoolMTA).remove_liquidity_one_coin(_3PoolMTAPrice, 2, 0);
       uint256 _3PoolBalance = IERC20(threePool).balanceOf(address(this));
    }


    // it looks like this function transfers not just "want" tokens, but all tokens
    //transfer want, threepoolMTA, crv, mta.
    function prepareMigration(address _newStrategy) internal override {
        want.transfer(_newStrategy, balanceOfWant());
        IERC20(threePoolMTA).transfer(_newStrategy, IERC20(threePoolMTA).balanceOf(address(this)));
        IERC20(crv).transfer(_newStrategy, IERC20(crv).balanceOf(address(this)));
        IERC20(mta).transfer(_newStrategy, IERC20(mta).balanceOf(address(this)));
    }

    // returns value of total 3pool staked in Gauge
    function balanceOfStake() internal view returns (uint256) {
        uint256 _balanceG = IGauge(gauge).balanceOf(address(this));
        return _balanceG;
    }

    // returns value of total 3pool
    function balanceOfPool() internal view returns (uint256) {
        uint256 _balance = IERC20(threePoolMTA).balanceOf(address(this));
        uint256 _virtualBalance = (_balance).mul(ICurve(threePoolMTA).get_virtual_price());
        return _virtualBalance;
    }

    // returns balance of threePool
    function balanceOfWant() public view returns (uint256) {
        return IERC20(want).balanceOf(address(this));
    }

    function swapCRVto3Pool(uint256 swap) internal {
        uint256 crvBalance = IERC20(crv).balanceOf(address(this));
            if (crvBalance > 0) {
                address[] memory path = new address[](3);
                path[0] = crv;
                path[1] = weth;
                path[2] = dai;
                path[3] = musd;

                Uni(unirouter).swapExactTokensForTokens(swap, uint256(0), path, address(this), now.add(1 days));

                uint256 musdBalance = IERC20(musd).balanceOf(address(this));
                ICurve(threePoolMTA).add_liquidity([musdBalance, 0], 0);
            }
    }

    function swapMTAto3Pool() internal {
        uint256 mtaBalance = IERC20(mta).balanceOf(address(this));
            if (mtaBalance > 0) {
                address[] memory path = new address[](3);
                path[0] = mta;
                path[1] = weth;
                path[2] = dai;
                path[3] = musd;

                Uni(unirouter).swapExactTokensForTokens(mtaBalance,uint256(0), path, address(this), now.add(1 days));

                uint256 musdBalance = IERC20(musd).balanceOf(address(this));
                ICurve(threePoolMTA).add_liquidity([musdBalance,0], 0);
            }
    }

    function setKeepCRV(uint256 _keepCRV) external {
        require(msg.sender == governance, "!governance");
        keepCRV = _keepCRV;
    }

}

