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
    //address public proxy;
    string public constant override name = "Strategy3PoolMTA";

    constructor(
        address _vault,
        address _mta,
        address _threePool,
        address _crv,
        address _threePoolMTA,
        address _gauge,
        address _unirouter,
        //address _proxy
    ) public BaseStrategy(_vault) {
        mta = _mta;
        threePool = _threePool;
        crv = _crv;
        threePoolMTA = _threePoolMTA;
        gauge = _gauge;
        unirouter = _unirouter;
        //proxy = _proxy;

        IERC20(threePool).safeApprove(threePoolMTA, uint256(-1));
        IERC20(threePoolMTA).safeApprove(gauge, uint256(-1));
        IERC20(mta).safeApprove(unirouter, uint256(-1));
        IERC20(crv).safeApprove(unirouter, uint256(-1));
    }

    function protectedTokens() internal override view returns (address[] memory) {
        address[] memory protected = new address[](5);
        protected[0] = threePool;
        protected[1] = threePoolMTA;
        protected[2] = mta;
        protected[3] = crv;
        protected[4] = address(want); // want is usdt
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

        // Update reserve with the available want so it's not considered profit
        setReserve(balanceOfWant().sub(_debtOutstanding));

        // claim/sell MTA and curve
        // claim MTA
        IGauge(gauge).claim_rewards(address(this));
        //claim crv
        IGauge(gauge).mint(address(this));



        // Final profit is want generated in the swap if ethProfit > 0
        _profit = balanceOfWant().sub(getReserve());
    }

    //todo: this
    function adjustPosition(uint256 _debtOutstanding) internal override {
       //emergency exit is dealt with in prepareReturn
        if (emergencyExit) {
          return;
       }

        // Reset the reserve value before
        setReserve(0);

       // Invest the rest of the want
       uint256 _wantAvailable = balanceOfWant().sub(_debtOutstanding);
        if (_wantAvailable > 0) {
            uint256 _availableFunds = IERC20(usdt).balanceOf(address(this));
            ICurve(threePool).add_liquidity([0,0,_availableFunds], 0);
            Vault(y3Pool).depositAll();
        }
    }

    // withdraws everything that is currently in the strategy, regardless of values.
    function exitPosition() internal override {
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
       IGauge(gauge).withdraw(_3PoolMTAAmount);
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

    function swapCRVto3Pool() internal {
        uint256 crvBalance = IERC20(crv).balanceOf(address(this));
            if (crvBalance > 0) {
                address[] memory path = new address[](3);
                path[0] = crv;
                path[1] = weth;
                path[2] = dai;
                path[3] = musd;

                Uni(unirouter).swapExactTokensForTokens(crvBalance,uint256(0), path, address(this), now.add(1 days));

                uint256 musdBalance = IERC20(musd).balanceOf(address(this));
                ICurve(threePoolMTA).add_liquidity([musdBalance,0], 0);
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

}

