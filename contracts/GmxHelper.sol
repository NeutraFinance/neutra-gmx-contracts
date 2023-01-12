// SPDX-License-Identifier: MIT

pragma solidity 0.8.11;

import {IERC20} from "./interfaces/IERC20.sol";
import {IVault as IGmxVault} from "./interfaces/gmx/IVault.sol";
import {IRewardTracker} from "./interfaces/gmx/IRewardTracker.sol";
import {IGlpManager} from "./interfaces/gmx/IGlpManager.sol";
import {IPositionRouter} from "./interfaces/gmx/IPositionRouter.sol";

struct GmxConfig {
    address vault;
    address glp;
    address fsGlp;
    address glpManager;
    address positionRouter;
    address usdg;
}

contract GmxHelper {
    address public gov;

    // deposit token
    address public want;
    address public wbtc;
    address public weth;

    // GMX contracts
    address public gmxVault;
    address public glp;
    address public fsGlp;
    address public nGlp;
    address public glpManager;
    address public positionRouter;
    address public usdg;

    modifier onlyGov() {
        _onlyGov();
        _;
    }

    function _onlyGov() internal view {
        require(msg.sender == gov, "GMXStrategy: Not Authorized");
    }

    constructor(GmxConfig memory _config, address _nGlp, address _want, address _wbtc, address _weth) {
        gmxVault = _config.vault;
        glp = _config.glp;
        fsGlp = _config.fsGlp;
        glpManager = _config.glpManager;
        positionRouter = _config.positionRouter;
        
        nGlp = _nGlp;
        want = _want;
        wbtc = _wbtc;
        weth = _weth;
    }

    function getAumInUsdg(bool _maximise) public view returns (uint256) {
        return IGlpManager(glpManager).getAumInUsdg(_maximise);
    }

    function getGlpTotalSupply() public view returns (uint256) {
        return IERC20(glp).totalSupply();
    }

    function getConfig(address _vault) public view returns (uint256[] memory) {
        
        uint256[] memory config = new uint256[](15);
        config[0] = IGlpManager(glpManager).getAum(true);
        config[1] = IGlpManager(glpManager).getAum(false);

        address[] memory tokens = new address[](2);
        tokens[0] = wbtc;
        tokens[1] = weth;
        uint256[] memory aums = getTokenAums(tokens, false);

        config[2] = aums[0];
        config[3] = aums[1];

        (uint256 wbtcSize, uint256 wbtcCollateral, uint256 wbtcAvgPrice,,,,,) = getPosition(_vault, wbtc);
        (uint256 wethSize, uint256 wethCollateral, uint256 wethAvgPrice,,,,,) = getPosition(_vault, weth);

        config[4] = IERC20(glp).totalSupply();
        config[5] = IERC20(fsGlp).balanceOf(_vault);
        config[6] = wbtcSize;
        config[7] = wbtcCollateral;
        config[8] = wbtcAvgPrice;
        config[9] = wethSize;
        config[10] = wethCollateral;
        config[11] = wethAvgPrice;
        config[12] = getPrice(wbtc, false);
        config[13] = getPrice(weth, false);
        config[14] = IERC20(nGlp).totalSupply();

        return config;
    }

    function getTokenAums(address[] memory _tokens, bool _maximise) public view returns (uint256[] memory) {
        uint256[] memory aums = new uint256[](_tokens.length);
        IGmxVault _gmxVault = IGmxVault(gmxVault);
        for (uint256 i = 0; i < _tokens.length; i++) {
            address token = _tokens[i];
            uint256 aum;

            if (!_gmxVault.whitelistedTokens(token)) {
                aums[i] = 0;
                continue;
            }

            // ignore stable token
            if (_gmxVault.stableTokens(token)) {
                aums[i] = 0;
                continue;
            }

            uint256 price = _maximise ? _gmxVault.getMaxPrice(token) : _gmxVault.getMinPrice(token);
            uint256 poolAmount = _gmxVault.poolAmounts(token);
            uint256 decimals = _gmxVault.tokenDecimals(token);
            uint256 reservedAmount = _gmxVault.reservedAmounts(token);

            aum = aum + _gmxVault.guaranteedUsd(token);
            aum = aum + (((poolAmount - reservedAmount) * price) / (10 ** decimals));
            aums[i] = aum;
        }
        return aums;
    }

    /// @notice calculate aums of each wbtc and weth depending on '_fsGlpAmount'
    function getTokenAumsPerAmount(uint256 _fsGlpAmount, bool _maximise) public view returns (uint256, uint256) {
        address[] memory tokens = new address[](2);
        tokens[0] = wbtc;
        tokens[1] = weth;
        uint256[] memory aums = getTokenAums(tokens, _maximise);
        uint256 totalSupply = IERC20(glp).totalSupply();

        uint256 wbtcAum = (aums[0] * _fsGlpAmount) / totalSupply;
        uint256 wethAum = (aums[1] * _fsGlpAmount) / totalSupply;
        return (wbtcAum, wethAum);
    }

    function getPrice(address _token, bool _maximise) public view returns (uint256) {
        return _maximise ? IGmxVault(gmxVault).getMaxPrice(_token) : IGmxVault(gmxVault).getMinPrice(_token);
    }

    function getPosition(
        address _account,
        address _indexToken
    ) public view returns (uint256, uint256, uint256, uint256, uint256, uint256, bool, uint256) {
        return IGmxVault(gmxVault).getPosition(_account, want, _indexToken, false);
    }

    function getFundingFee(address _account, address _indexToken) public view returns (uint256) {
        (uint256 size, , , uint256 entryFundingRate, , , , ) = getPosition(_account, _indexToken);
        return IGmxVault(gmxVault).getFundingFee(want, size, entryFundingRate);
    }

    function getFundingFeeWithRate(address _account, address _indexToken, uint256 _fundingRate) public view returns (uint256) {
        (uint256 size, , , , , , , ) = getPosition(_account, _indexToken);
        return IGmxVault(gmxVault).getFundingFee(want, size, _fundingRate);
    }

    function getLastFundingTime() public view returns (uint256) {
        return IGmxVault(gmxVault).lastFundingTimes(want);
    }

    function getCumulativeFundingRates(address _token) public view returns (uint256) {
        return IGmxVault(gmxVault).cumulativeFundingRates(_token);
    }

    function getLongValue(uint256 _glpAmount) public view returns (uint256) {
        uint256 totalSupply = IERC20(glp).totalSupply();
        uint256 aum = IGlpManager(glpManager).getAum(false);
        return aum * _glpAmount / totalSupply;
    }

    function getShortValue(address _account, address _indexToken) public view returns (uint256) {
        IGmxVault _gmxVault = IGmxVault(gmxVault);
        (uint256 size, uint256 collateral, uint256 avgPrice,,,,,) = getPosition(_account , _indexToken);
        if (size == 0) {
            return 0;
        } 
        (bool hasProfit, uint256 pnl) = _gmxVault.getDelta(_indexToken, size, avgPrice, false, 0);
        return hasProfit ? collateral + pnl : collateral - pnl;
    }

    function getMintBurnFeeBasisPoints(address _token, uint256 _usdgDelta, bool _increment) public view returns (uint256) {
        IGmxVault _gmxVault = IGmxVault(gmxVault);
        uint256 feeBasisPoints = _gmxVault.mintBurnFeeBasisPoints();
        uint256 taxBasisPoints = _gmxVault.taxBasisPoints();
        return IGmxVault(gmxVault).getFeeBasisPoints(_token, _usdgDelta, feeBasisPoints, taxBasisPoints, _increment);
    }

    function totalValue(address _account) public view returns (uint256) {
        uint256 longValue = getLongValue(IERC20(fsGlp).balanceOf(_account));
        uint256 wbtcShortValue = getShortValue(_account, wbtc);
        uint256 wethShortValue = getShortValue(_account, weth);

        return (longValue + wbtcShortValue + wethShortValue);
    }

    function getDelta(address _indexToken, uint256 _size, uint256 _avgPrice) public view returns (bool, uint256) {
        IGmxVault _gmxVault = IGmxVault(gmxVault);
        (bool hasProfit, uint256 pnl) = _gmxVault.getDelta(_indexToken, _size, _avgPrice, false, 0);
        return (hasProfit, pnl);
    }

    function getRedemptionAmount(address _token, uint256 _usdgAmount) public view returns (uint256) {
        return IGmxVault(gmxVault).getRedemptionAmount(_token, _usdgAmount);
    }

    function validateMaxGlobalShortSize(address _indexToken, uint256 _sizeDelta) public view returns (bool) {
        if (_sizeDelta == 0) {
            return true;
        }
        uint256 maxGlobalShortSize = IPositionRouter(positionRouter).maxGlobalShortSizes(_indexToken);
        uint256 globalShortSize = IGmxVault(gmxVault).globalShortSizes(_indexToken);
        return maxGlobalShortSize > (globalShortSize + _sizeDelta);
    }
}
