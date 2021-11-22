/*
    Copyright 2021 Set Labs Inc.

    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.

    SPDX-License-Identifier: Apache License, Version 2.0
*/

pragma solidity 0.6.10;
pragma experimental ABIEncoderV2;

import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/SafeCast.sol";
import { SafeMath } from "@openzeppelin/contracts/math/SafeMath.sol";
import { SignedSafeMath } from "@openzeppelin/contracts/math/SignedSafeMath.sol";

import { BaseExtension } from "../lib/BaseExtension.sol";
import { IBaseManager } from "../interfaces/IBaseManager.sol";
import { IChainlinkAggregatorV3 } from "../interfaces/IChainlinkAggregatorV3.sol";
import { IPerpV2LeverageModule } from "../interfaces/IPerpV2LeverageModule.sol";
import { IAccountBalance } from "@setprotocol/set-protocol-v2/contracts/interfaces/external/perp-v2/IAccountBalance.sol";
import { IClearingHouse } from "@setprotocol/set-protocol-v2/contracts/interfaces/external/perp-v2/IClearingHouse.sol";
import { IClearingHouseConfig } from "../interfaces/perp-v2/IClearingHouseConfig.sol";

import { ISetToken } from "../interfaces/ISetToken.sol";
import { PreciseUnitMath } from "../lib/PreciseUnitMath.sol";
import { StringArrayUtils } from "../lib/StringArrayUtils.sol";


/**
 * @title PerpV2LeverageStrategyExtension
 * @author Set Protocol
 *
 * Smart contract that enables trustless leverage tokens with USDC as the base asset. This extension is paired with the PerpV2LeverageModule from Set protocol where module 
 * interactions are invoked via the IBaseManager contract. Any leveraged token can be constructed as long as the market is listed in Perp V2.
 * This extension contract also allows the operator to set an ETH reward to incentivize keepers calling the rebalance function at different
 * leverage thresholds.
 *
 */
contract PerpV2LeverageStrategyExtension is BaseExtension {
    using Address for address;
    using PreciseUnitMath for uint256;
    using PreciseUnitMath for int256;
    using SafeMath for uint256;
    using SignedSafeMath for int256;
    using SafeCast for int256;
    using SafeCast for uint256;
    using StringArrayUtils for string[];

    /* ============ Enums ============ */

    enum ShouldRebalance {
        NONE,                   // Indicates no rebalance action can be taken
        REBALANCE,              // Indicates rebalance() function can be successfully called
        ITERATE_REBALANCE,      // Indicates iterateRebalance() function can be successfully called
        RIPCORD                 // Indicates ripcord() function can be successfully called
    }

    /* ============ Structs ============ */

    struct ActionInfo {
        int256 baseBalance;                             // Balance of virtual base asset from Perp in precise units (10e18). E.g. vWBTC = 10e18
        int256 quoteBalance;                            // Balance of virtual quote asset from Perp in precise units (10e18)
        int256 baseValue;                               // Valuation in USD adjusted for decimals in precise units (10e18)
        int256 quoteValue;                              // Valuation in USD adjusted for decimals in precise units (10e18)
        int256 basePrice;                               // Price of collateral in precise units (10e18) from Chainlink
        int256 quotePrice;                              // Price of collateral in precise units (10e18) from Chainlink
        uint256 setTotalSupply;                         // Total supply of SetToken
    }

     struct LeverageInfo {
        ActionInfo action;
        int256 currentLeverageRatio;                    // Current leverage ratio of Set. For short tokens, this will be negative
        uint256 slippageTolerance;                      // Allowable percent trade slippage in preciseUnits (1% = 10^16)
        uint256 twapMaxTradeSize;                       // Max trade size in collateral units allowed for rebalance action
    }

    struct ContractSettings {
        ISetToken setToken;                             // Instance of leverage token
        IPerpV2LeverageModule perpV2LeverageModule;     // Instance of Perp V2 leverage module
        IAccountBalance perpV2AccountBalance;           // Instance of Perp V2 AccountBalance contract used to fetch position balances
        IChainlinkAggregatorV3 basePriceOracle;         // Chainlink oracle feed that returns prices in 8 decimals for collateral asset
        IChainlinkAggregatorV3 quotePriceOracle;        // Chainlink oracle feed that returns prices in 8 decimals for collateral asset
        address virtualBaseAddress;                     // Address of virtual base asset (e.g. vETH, vWBTC etc)
        address virtualQuoteAddress;                    // Address of virtual USDC quote asset. The Perp V2 system uses USDC for all markets
    }

    struct MethodologySettings {
        int256 targetLeverageRatio;                     // Long term target ratio in precise units (10e18). Short tokens are negative
        int256 minLeverageRatio;                        // For long tokens, if current leverage is lower, rebalance target is this ratio. For short
                                                        // tokens, if current leverage is higher, rebalance target is this ratio. In precise units (10e18)
        int256 maxLeverageRatio;                        // For long tokens, if current leverage is higher, rebalance target is this ratio. For short
                                                        // tokens, if current leverage is lower, rebalance target is this ratio. In precise units (10e18)
        uint256 recenteringSpeed;                       // % at which to rebalance back to target leverage in precise units (10e18). Always a positive number
        uint256 rebalanceInterval;                      // Period of time required since last rebalance timestamp in seconds
    }

    struct ExecutionSettings {
        uint256 unutilizedLeveragePercentage;            // Percent of max quote left unutilized in precise units (1% = 10e16)
        uint256 slippageTolerance;                       // % in precise units to price min token receive amount from trade quantities
        uint256 twapCooldownPeriod;                      // Cooldown period required since last trade timestamp in seconds
    }

    struct ExchangeSettings {
        uint256 twapMaxTradeSize;                        // Max trade size in collateral base units. Always a positive number
        uint256 incentivizedTwapMaxTradeSize;            // Max trade size for incentivized rebalances in collateral base units. Always a positive number
    }

    struct IncentiveSettings {
        uint256 etherReward;                             // ETH reward for incentivized rebalances
        int256 incentivizedLeverageRatio;                // Leverage ratio for incentivized rebalances. For long tokens, this is a positive number higher than
                                                         // maxLeverageRatio. For short tokens, this is a negative number lower than maxLeverageRatio
        uint256 incentivizedSlippageTolerance;           // Slippage tolerance percentage for incentivized rebalances
        uint256 incentivizedTwapCooldownPeriod;          // TWAP cooldown in seconds for incentivized rebalances
    }

    /* ============ Events ============ */

    event Engaged(int256 _currentLeverageRatio, int256 _newLeverageRatio, int256 _chunkRebalanceNotional, int256 _totalRebalanceNotional);
    event Rebalanced(
        int256 _currentLeverageRatio,
        int256 _newLeverageRatio,
        int256 _chunkRebalanceNotional,
        int256 _totalRebalanceNotional
    );
    event RebalanceIterated(
        int256 _currentLeverageRatio,
        int256 _newLeverageRatio,
        int256 _chunkRebalanceNotional,
        int256 _totalRebalanceNotional
    );
    event RipcordCalled(
        int256 _currentLeverageRatio,
        int256 _newLeverageRatio,
        int256 _rebalanceNotional,
        uint256 _etherIncentive
    );
    event Disengaged(int256 _currentLeverageRatio, int256 _newLeverageRatio, int256 _chunkRebalanceNotional, int256 _totalRebalanceNotional);
    event MethodologySettingsUpdated(
        int256 _targetLeverageRatio,
        int256 _minLeverageRatio,
        int256 _maxLeverageRatio,
        uint256 _recenteringSpeed,
        uint256 _rebalanceInterval
    );
    event ExecutionSettingsUpdated(
        uint256 _unutilizedLeveragePercentage,
        uint256 _twapCooldownPeriod,
        uint256 _slippageTolerance
    );
    event ExchangeSettingsUpdated(
        uint256 _twapMaxTradeSize,
        uint256 _incentivizedTwapMaxTradeSize
    );
    event IncentiveSettingsUpdated(
        uint256 _etherReward,
        int256 _incentivizedLeverageRatio,
        uint256 _incentivizedSlippageTolerance,
        uint256 _incentivizedTwapCooldownPeriod
    );

    /* ============ Modifiers ============ */

    /**
     * Throws if rebalance is currently in TWAP`
     */
    modifier noRebalanceInProgress() {
        require(twapLeverageRatio == 0, "Rebalance is currently in progress");
        _;
    }

    /* ============ State Variables ============ */

    ContractSettings internal strategy;                             // Struct of contracts used in the strategy (SetToken, price oracles, leverage module etc)
    MethodologySettings internal methodology;                       // Struct containing methodology parameters
    ExecutionSettings internal execution;                           // Struct containing execution parameters
    ExchangeSettings internal exchange;                             // Struct containing exchange settings
    IncentiveSettings internal incentive;                           // Struct containing incentive parameters for ripcord
    int256 public twapLeverageRatio;                               // Stored leverage ratio to keep track of target between TWAP rebalances
    uint256 public lastTradeTimestamp;                        // Last rebalance timestamp. Current timestamp must be greater than this variable + rebalance interval to rebalance

    /* ============ Constructor ============ */

    /**
     * Instantiate addresses, methodology parameters, execution parameters, exchange parameters and incentive parameters.
     *
     * @param _manager                  Address of IBaseManager contract
     * @param _strategy                 Struct of contract addresses
     * @param _methodology              Struct containing methodology parameters
     * @param _execution                Struct containing execution parameters
     * @param _incentive                Struct containing incentive parameters for ripcord
     * @param _exchange         List of structs containing exchange parameters for the initial exchanges
     */
    constructor(
        IBaseManager _manager,
        ContractSettings memory _strategy,
        MethodologySettings memory _methodology,
        ExecutionSettings memory _execution,
        IncentiveSettings memory _incentive,
        ExchangeSettings memory _exchange
    )
        public
        BaseExtension(_manager)
    {
        strategy = _strategy;
        methodology = _methodology;
        execution = _execution;
        incentive = _incentive;
        exchange = _exchange;

        _validateExchangeSettings(_exchange);
        _validateNonExchangeSettings(methodology, execution, incentive);
    }

    /* ============ External Functions ============ */

    /**
     * OPERATOR ONLY: Engage to target leverage ratio for the first time. SetToken will swap virtual quote asset (USDC) for base token. If target
     * leverage ratio is above max trade size, then TWAP is kicked off. To complete engage if TWAP, any valid caller must call iterateRebalance until target
     * is met.
     */
    function engage() external onlyOperator {
        ActionInfo memory engageInfo = _createActionInfo();

        require(engageInfo.setTotalSupply > 0, "SetToken must have > 0 supply");
        // TBD
        // require(engageInfo.baseBalance > 0, "Collateral balance must be > 0");
        // require(engageInfo.quoteBalance == 0, "Debt must be 0");

        LeverageInfo memory leverageInfo = LeverageInfo({
            action: engageInfo,
            currentLeverageRatio: 0, // 0 position leverage due 100% of value in quote asset
            slippageTolerance: execution.slippageTolerance,
            twapMaxTradeSize: exchange.twapMaxTradeSize
        });

        // Calculate total rebalance units and kick off TWAP if above max quote or max trade size
        (
            int256 chunkRebalanceNotional,
            int256 totalRebalanceNotional
        ) = _calculateChunkRebalanceNotional(leverageInfo, methodology.targetLeverageRatio);

        _trade(leverageInfo, chunkRebalanceNotional);

        _updateRebalanceState(
            chunkRebalanceNotional,
            totalRebalanceNotional,
            methodology.targetLeverageRatio
        );

        emit Engaged(
            leverageInfo.currentLeverageRatio,
            methodology.targetLeverageRatio,
            chunkRebalanceNotional,
            totalRebalanceNotional
        );
    }

    /**
     * ONLY EOA AND ALLOWED CALLER: Rebalance product. If current leverage ratio is between the max and min bounds, then rebalance 
     * can only be called once the rebalance interval has elapsed since last timestamp. If outside the max and min, rebalance can be called anytime to bring leverage
     * ratio back to the max or min bounds. The methodology will determine whether to delever or lever.
     *
     * Note: If the calculated current leverage ratio is above the incentivized leverage ratio or in TWAP then rebalance cannot be called. Instead, you must call
     * ripcord() which is incentivized with a reward in Ether or iterateRebalance().
     */
     function rebalance() external onlyEOA onlyAllowedCaller(msg.sender) {
        LeverageInfo memory leverageInfo = _getAndValidateLeveragedInfo(
            execution.slippageTolerance,
            exchange.twapMaxTradeSize
        );

        // use lastTradeTimestamps to prevent multiple rebalances being called with different exchanges during the epoch rebalance
        _validateNormalRebalance(leverageInfo, methodology.rebalanceInterval, lastTradeTimestamp);
        _validateNonTWAP();

        int256 newLeverageRatio = _calculateNewLeverageRatio(leverageInfo.currentLeverageRatio);

        (
            int256 chunkRebalanceNotional,
            int256 totalRebalanceNotional
        ) = _handleRebalance(leverageInfo, newLeverageRatio);

        _updateRebalanceState(chunkRebalanceNotional, totalRebalanceNotional, newLeverageRatio);

        emit Rebalanced(
            leverageInfo.currentLeverageRatio,
            newLeverageRatio,
            chunkRebalanceNotional,
            totalRebalanceNotional
        );
    }

    /**
     * ONLY EOA AND ALLOWED CALLER: Iterate a rebalance when in TWAP. TWAP cooldown period must have elapsed. If price moves advantageously, then exit without rebalancing
     * and clear TWAP state. This function can only be called when below incentivized leverage ratio and in TWAP state.
     */
    function iterateRebalance() external onlyEOA onlyAllowedCaller(msg.sender) {
        LeverageInfo memory leverageInfo = _getAndValidateLeveragedInfo(
            execution.slippageTolerance,
            exchange.twapMaxTradeSize
        );

        // Use the lastTradeTimestamp since cooldown periods are measured on a per-exchange basis, allowing it to rebalance multiple time in quick
        // succession with different exchanges
        _validateNormalRebalance(leverageInfo, execution.twapCooldownPeriod, lastTradeTimestamp);
        _validateTWAP();

        int256 chunkRebalanceNotional;
        int256 totalRebalanceNotional;
        if (!_isAdvantageousTWAP(leverageInfo.currentLeverageRatio)) {
            (chunkRebalanceNotional, totalRebalanceNotional) = _handleRebalance(leverageInfo, twapLeverageRatio);
        }

        // If not advantageous, then rebalance is skipped and chunk and total rebalance notional are both 0, which means TWAP state is
        // cleared
        _updateIterateState(chunkRebalanceNotional, totalRebalanceNotional);

        emit RebalanceIterated(
            leverageInfo.currentLeverageRatio,
            twapLeverageRatio,
            chunkRebalanceNotional,
            totalRebalanceNotional
        );
    }

    /**
     * ONLY EOA: In case the current leverage ratio exceeds the incentivized leverage threshold, the ripcord function can be called by anyone to return leverage ratio
     * back to the max leverage ratio. This function typically would only be called during times of high downside volatility and / or normal keeper malfunctions. The caller
     * of ripcord() will receive a reward in Ether. The ripcord function uses it's own TWAP cooldown period, slippage tolerance and TWAP max trade size which are typically
     * looser than in regular rebalances.
     */
    function ripcord() external onlyEOA {
        LeverageInfo memory leverageInfo = _getAndValidateLeveragedInfo(
            incentive.incentivizedSlippageTolerance,
            exchange.incentivizedTwapMaxTradeSize
        );

        // Use the lastTradeTimestamp so it can ripcord quickly with multiple exchanges
        _validateRipcord(leverageInfo, lastTradeTimestamp);

        ( int256 chunkRebalanceNotional, ) = _calculateChunkRebalanceNotional(leverageInfo, methodology.maxLeverageRatio);

        _trade(leverageInfo, chunkRebalanceNotional);

        _updateRipcordState();

        uint256 etherTransferred = _transferEtherRewardToCaller(incentive.etherReward);

        emit RipcordCalled(
            leverageInfo.currentLeverageRatio,
            methodology.maxLeverageRatio,
            chunkRebalanceNotional,
            etherTransferred
        );
    }

    /**
     * OPERATOR ONLY: Return leverage ratio to 1x and delever to repay loan. This can be used for upgrading or shutting down the strategy. SetToken will redeem
     * collateral position and trade for debt position to repay Aave. If the chunk rebalance size is less than the total notional size, then this function will
     * delever and repay entire quote balance on Aave. If chunk rebalance size is above max quote or max trade size, then operator must
     * continue to call this function to complete repayment of loan. The function iterateRebalance will not work.
     *
     * Note: Delever to 0 will likely result in additional units of the quote asset added as equity on the SetToken due to oracle price / market price mismatch
     *
     */
    function disengage() external onlyOperator {
        LeverageInfo memory leverageInfo = _getAndValidateLeveragedInfo(
            execution.slippageTolerance,
            exchange.twapMaxTradeSize
        );

        // Reduce leverage to 0
        int256 newLeverageRatio = 0;

        (
            int256 chunkRebalanceNotional,
            int256 totalRebalanceNotional
        ) = _calculateChunkRebalanceNotional(leverageInfo, newLeverageRatio);

        _trade(leverageInfo, chunkRebalanceNotional);

        emit Disengaged(
            leverageInfo.currentLeverageRatio,
            newLeverageRatio,
            chunkRebalanceNotional,
            totalRebalanceNotional
        );
    }

    /**
     * OPERATOR ONLY: Set methodology settings and check new settings are valid. Note: Need to pass in existing parameters if only changing a few settings. Must not be
     * in a rebalance.
     *
     * @param _newMethodologySettings          Struct containing methodology parameters
     */
    function setMethodologySettings(MethodologySettings memory _newMethodologySettings) external onlyOperator noRebalanceInProgress {
        methodology = _newMethodologySettings;

        _validateNonExchangeSettings(methodology, execution, incentive);

        emit MethodologySettingsUpdated(
            methodology.targetLeverageRatio,
            methodology.minLeverageRatio,
            methodology.maxLeverageRatio,
            methodology.recenteringSpeed,
            methodology.rebalanceInterval
        );
    }

    /**
     * OPERATOR ONLY: Set execution settings and check new settings are valid. Note: Need to pass in existing parameters if only changing a few settings. Must not be
     * in a rebalance.
     *
     * @param _newExecutionSettings          Struct containing execution parameters
     */
    function setExecutionSettings(ExecutionSettings memory _newExecutionSettings) external onlyOperator noRebalanceInProgress {
        execution = _newExecutionSettings;

        _validateNonExchangeSettings(methodology, execution, incentive);

        emit ExecutionSettingsUpdated(
            execution.unutilizedLeveragePercentage,
            execution.twapCooldownPeriod,
            execution.slippageTolerance
        );
    }

    /**
     * OPERATOR ONLY: Set incentive settings and check new settings are valid. Note: Need to pass in existing parameters if only changing a few settings. Must not be
     * in a rebalance.
     *
     * @param _newIncentiveSettings          Struct containing incentive parameters
     */
    function setIncentiveSettings(IncentiveSettings memory _newIncentiveSettings) external onlyOperator noRebalanceInProgress {
        incentive = _newIncentiveSettings;

        _validateNonExchangeSettings(methodology, execution, incentive);

        emit IncentiveSettingsUpdated(
            incentive.etherReward,
            incentive.incentivizedLeverageRatio,
            incentive.incentivizedSlippageTolerance,
            incentive.incentivizedTwapCooldownPeriod
        );
    }

    /**
     * OPERATOR ONLY: Updates the settings of an exchange. Reverts if exchange is not already added. When updating an exchange, lastTradeTimestamp
     * is preserved. Updating exchanges during rebalances is allowed, as it is not possible to enter an unexpected state while doing so. Note: Need to
     * pass in all existing parameters even if only changing a few settings.
     *
     * @param _newExchangeSettings     Struct containing exchange parameters
     */
    function setExchangeSettings(ExchangeSettings memory _newExchangeSettings)
        external
        onlyOperator
    {
        exchange = _newExchangeSettings;
        _validateExchangeSettings(_newExchangeSettings);

        exchange.twapMaxTradeSize = _newExchangeSettings.twapMaxTradeSize;
        exchange.incentivizedTwapMaxTradeSize = _newExchangeSettings.incentivizedTwapMaxTradeSize;

        emit ExchangeSettingsUpdated(
            _newExchangeSettings.twapMaxTradeSize,
            _newExchangeSettings.incentivizedTwapMaxTradeSize
        );
    }

    /**
     * OPERATOR ONLY: Withdraw entire balance of ETH in this contract to operator. Rebalance must not be in progress
     */
    function withdrawEtherBalance() external onlyOperator noRebalanceInProgress {
        msg.sender.transfer(address(this).balance);
    }

    receive() external payable {}

    /* ============ External Getter Functions ============ */

    /**
     * Get current leverage ratio. Current leverage ratio is defined as the USD value of the collateral divided by the USD value of the SetToken. Prices for collateral
     * and quote asset are retrieved from the Chainlink Price Oracle.
     *
     * return currentLeverageRatio         Current leverage ratio in precise units (10e18)
     */
    function getCurrentLeverageRatio() public view returns(int256) {
        ActionInfo memory currentLeverageInfo = _createActionInfo();

        return _calculateCurrentLeverageRatio(currentLeverageInfo.baseValue, currentLeverageInfo.quoteValue);
    }

    /**
     * Calculates the chunk rebalance size. This can be used by external contracts and keeper bots to calculate the optimal exchange to rebalance with.
     * Note: this function does not take into account timestamps, so it may return a nonzero value even when shouldRebalance would return ShouldRebalance.NONE for
     * all exchanges (since minimum delays have not elapsed)
     *
     * @return size             Array of total notional chunk size. Measured in the asset that would be sold
     * @return sellAsset        Asset that would be sold during a rebalance
     * @return buyAsset         Asset that would be purchased during a rebalance
     */
    function getChunkRebalanceNotional()
        external
        view
        returns(int256 size, address sellAsset, address buyAsset)
    {

        int256 newLeverageRatio;
        int256 currentLeverageRatio = getCurrentLeverageRatio();
        bool isRipcord = false;

        // if over incentivized leverage ratio, always ripcord
        if (_absUint256(currentLeverageRatio) > _absUint256(incentive.incentivizedLeverageRatio)) {
            newLeverageRatio = methodology.maxLeverageRatio;
            isRipcord = true;
        // if we are in an ongoing twap, use the cached twapLeverageRatio as our target leverage
        } else if (twapLeverageRatio != 0) {
            newLeverageRatio = twapLeverageRatio;
        // if all else is false, then we would just use the normal rebalance new leverage ratio calculation
        } else {
            newLeverageRatio = _calculateNewLeverageRatio(currentLeverageRatio);
        }

        ActionInfo memory actionInfo = _createActionInfo();

        LeverageInfo memory leverageInfo = LeverageInfo({
            action: actionInfo,
            currentLeverageRatio: currentLeverageRatio,
            slippageTolerance: isRipcord ? incentive.incentivizedSlippageTolerance : execution.slippageTolerance,
            twapMaxTradeSize: isRipcord ?
                exchange.incentivizedTwapMaxTradeSize :
                exchange.twapMaxTradeSize
        });

        (size, ) = _calculateChunkRebalanceNotional(leverageInfo, newLeverageRatio);

        bool increaseLeverage = _absUint256(newLeverageRatio) > _absUint256(currentLeverageRatio);
        sellAsset = increaseLeverage ? strategy.virtualQuoteAddress : strategy.virtualBaseAddress;
        buyAsset = increaseLeverage ? strategy.virtualBaseAddress : strategy.virtualQuoteAddress;
    }

    /**
     * Get current Ether incentive for when current leverage ratio exceeds incentivized leverage ratio and ripcord can be called. If ETH balance on the contract is
     * below the etherReward, then return the balance of ETH instead.
     *
     * return etherReward               Quantity of ETH reward in base units (10e18)
     */
    function getCurrentEtherIncentive() external view returns(uint256) {
        int256 currentLeverageRatio = getCurrentLeverageRatio();

        if (currentLeverageRatio >= incentive.incentivizedLeverageRatio) {
            // If ETH reward is below the balance on this contract, then return ETH balance on contract instead
            return incentive.etherReward < address(this).balance ? incentive.etherReward : address(this).balance;
        } else {
            return 0;
        }
    }

    /**
     * Helper that checks if conditions are met for rebalance or ripcord. Returns an enum with 0 = no rebalance, 1 = call rebalance(), 2 = call iterateRebalance()
     * 3 = call ripcord()
     *
     * @return ShouldRebalance      Enum representing whether should rebalance
     */
    function shouldRebalance() external view returns(ShouldRebalance) {
        int256 currentLeverageRatio = getCurrentLeverageRatio();

        return _shouldRebalance(currentLeverageRatio, methodology.minLeverageRatio, methodology.maxLeverageRatio);
    }

    /**
     * Helper that checks if conditions are met for rebalance or ripcord with custom max and min bounds specified by caller. This function simplifies the
     * logic for off-chain keeper bots to determine what threshold to call rebalance when leverage exceeds max or drops below min. Returns an enum with
     * 0 = no rebalance, 1 = call rebalance(), 2 = call iterateRebalance(), 3 = call ripcord()
     *
     * @param _customMinLeverageRatio          Min leverage ratio passed in by caller
     * @param _customMaxLeverageRatio          Max leverage ratio passed in by caller
     *
     * @return (string[] memory, ShouldRebalance[] memory)      List of exchange names and a list of enums representing whether that exchange should rebalance
     */
    function shouldRebalanceWithBounds(
        int256 _customMinLeverageRatio,
        int256 _customMaxLeverageRatio
    )
        external
        view
        returns(ShouldRebalance)
    {
        require (
            _customMinLeverageRatio <= methodology.minLeverageRatio && _customMaxLeverageRatio >= methodology.maxLeverageRatio,
            "Custom bounds must be valid"
        );

        int256 currentLeverageRatio = getCurrentLeverageRatio();

        return _shouldRebalance(currentLeverageRatio, _customMinLeverageRatio, _customMaxLeverageRatio);
    }

    /**
     * Explicit getter functions for parameter structs are defined as workaround to issues fetching structs that have dynamic types.
     */
    function getStrategy() external view returns (ContractSettings memory) { return strategy; }
    function getMethodology() external view returns (MethodologySettings memory) { return methodology; }
    function getExecution() external view returns (ExecutionSettings memory) { return execution; }
    function getIncentive() external view returns (IncentiveSettings memory) { return incentive; }
    function getExchangeSettings() external view returns (ExchangeSettings memory) { return exchange; }

    /* ============ Internal Functions ============ */

    /**
     * Calculate notional rebalance quantity, whether to chunk rebalance based on max trade size and max quote and invoke lever on AaveLeverageModule
     *
     */
     function _trade(
        LeverageInfo memory _leverageInfo,
        int256 _chunkRebalanceNotional
    )
        internal
    {
        int256 collateralRebalanceUnits = _chunkRebalanceNotional.preciseDiv(_leverageInfo.action.setTotalSupply.toInt256());

        int256 minReceiveBorrowUnits = _calculateMinBorrowReceiveUnits(collateralRebalanceUnits, _leverageInfo.action, _leverageInfo.slippageTolerance);

        bytes memory tradeCallData = abi.encodeWithSignature(
            "trade(address,address,int256,int256)",
            address(strategy.setToken),
            strategy.virtualBaseAddress,
            collateralRebalanceUnits,
            minReceiveBorrowUnits
        );

        invokeManager(address(strategy.perpV2LeverageModule), tradeCallData);
    }

    /**
     * Check whether to delever or lever based on the current vs new leverage ratios. Used in the rebalance() and iterateRebalance() functions
     *
     * return uint256           Calculated notional to trade
     * return uint256           Total notional to rebalance over TWAP
     */
    function _handleRebalance(LeverageInfo memory _leverageInfo, int256 _newLeverageRatio) internal returns(int256, int256) {
        (
            int256 chunkRebalanceNotional,
            int256 totalRebalanceNotional
        ) = _calculateChunkRebalanceNotional(_leverageInfo, _newLeverageRatio);

        _trade(_leverageInfo, chunkRebalanceNotional);

        return (chunkRebalanceNotional, totalRebalanceNotional);
    }

    /**
     * Create the leverage info struct to be used in internal functions
     *
     * return LeverageInfo                Struct containing ActionInfo and other data
     */
    function _getAndValidateLeveragedInfo(uint256 _slippageTolerance, uint256 _maxTradeSize) internal view returns(LeverageInfo memory) {
        ActionInfo memory actionInfo = _createActionInfo();

        require(actionInfo.setTotalSupply > 0, "SetToken must have > 0 supply");
        // TBD
        // require(actionInfo.baseBalance > 0, "Collateral balance must be > 0");
        // require(actionInfo.quoteBalance > 0, "Borrow balance must exist");

        // Get current leverage ratio
        int256 currentLeverageRatio = _calculateCurrentLeverageRatio(
            actionInfo.baseValue,
            actionInfo.quoteValue
        );

        return LeverageInfo({
            action: actionInfo,
            currentLeverageRatio: currentLeverageRatio,
            slippageTolerance: _slippageTolerance,
            twapMaxTradeSize: _maxTradeSize
        });
    }

    /**
     * Create the action info struct to be used in internal functions
     *
     * return ActionInfo                Struct containing data used by internal lever and delever functions
     */
    function _createActionInfo() internal view returns(ActionInfo memory) {
        ActionInfo memory rebalanceInfo;

        // Calculate prices from chainlink. Chainlink returns prices with 8 decimal places, so we need to adjust by 10 ** 10.
        // In Perp v2, virtual tokens all have 18 decimals, therefore we do not need to make further adjustments to determine
        // base and quote valuation
        int256 rawCollateralPrice = strategy.basePriceOracle.latestAnswer();
        int256 rawBorrowPrice = strategy.quotePriceOracle.latestAnswer();
        rebalanceInfo.basePrice = rawCollateralPrice.mul(10 ** 10);
        rebalanceInfo.quotePrice = rawBorrowPrice.mul(10 ** 10);

        rebalanceInfo.baseBalance = strategy.perpV2AccountBalance.getBase(address(strategy.setToken), strategy.virtualBaseAddress);
        rebalanceInfo.quoteBalance = strategy.perpV2AccountBalance.getQuote(address(strategy.setToken), strategy.virtualBaseAddress);

        rebalanceInfo.baseValue = rebalanceInfo.basePrice.preciseMul(rebalanceInfo.baseBalance);
        rebalanceInfo.quoteValue = rebalanceInfo.quotePrice.preciseMul(rebalanceInfo.quoteBalance);

        rebalanceInfo.setTotalSupply = strategy.setToken.totalSupply();

        return rebalanceInfo;
    }

    /**
     * Validate non-exchange settings in constructor and setters when updating.
     */
    function _validateNonExchangeSettings(
        MethodologySettings memory _methodology,
        ExecutionSettings memory _execution,
        IncentiveSettings memory _incentive
    )
        internal
        pure
    {
        uint256 minLeverageRatioAbs = _absUint256(_methodology.minLeverageRatio);
        uint256 targetLeverageRatioAbs = _absUint256(_methodology.targetLeverageRatio);
        uint256 maxLeverageRatioAbs = _absUint256(_methodology.maxLeverageRatio);
        uint256 incentivizedLeverageRatioAbs = _absUint256(_incentive.incentivizedLeverageRatio);

        require (
            minLeverageRatioAbs <= targetLeverageRatioAbs && minLeverageRatioAbs > 0,
            "Must be valid min leverage"
        );
        require (
            maxLeverageRatioAbs >= targetLeverageRatioAbs,
            "Must be valid max leverage"
        );
        require (
            _methodology.recenteringSpeed <= PreciseUnitMath.preciseUnit() && _methodology.recenteringSpeed > 0,
            "Must be valid recentering speed"
        );
        require (
            _execution.unutilizedLeveragePercentage <= PreciseUnitMath.preciseUnit(),
            "Unutilized leverage must be <100%"
        );
        require (
            _execution.slippageTolerance <= PreciseUnitMath.preciseUnit(),
            "Slippage tolerance must be <100%"
        );
        require (
            _incentive.incentivizedSlippageTolerance <= PreciseUnitMath.preciseUnit(),
            "Incentivized slippage tolerance must be <100%"
        );
        require (
            incentivizedLeverageRatioAbs >= maxLeverageRatioAbs,
            "Incentivized leverage ratio must be > max leverage ratio"
        );
        require (
            _methodology.rebalanceInterval >= _execution.twapCooldownPeriod,
            "Rebalance interval must be greater than TWAP cooldown period"
        );
        require (
            _execution.twapCooldownPeriod >= _incentive.incentivizedTwapCooldownPeriod,
            "TWAP cooldown must be greater than incentivized TWAP cooldown"
        );
    }

    /**
     * Validate an ExchangeSettings struct when adding or updating an exchange. Does not validate that twapMaxTradeSize < incentivizedMaxTradeSize since
     * it may be useful to disable exchanges for ripcord by setting incentivizedMaxTradeSize to 0.
     */
     function _validateExchangeSettings(ExchangeSettings memory _settings) internal pure {
         require(_settings.twapMaxTradeSize != 0, "Max TWAP trade size must not be 0");
     }

    /**
     * Validate that current leverage is below incentivized leverage ratio and cooldown / rebalance period has elapsed or outsize max/min bounds. Used
     * in rebalance() and iterateRebalance() functions
     */
    function _validateNormalRebalance(LeverageInfo memory _leverageInfo, uint256 _coolDown, uint256 _lastTradeTimestamp) internal view {
        uint256 currentLeverageRatioAbs = _absUint256(_leverageInfo.currentLeverageRatio);
        require(currentLeverageRatioAbs < _absUint256(incentive.incentivizedLeverageRatio), "Must be below incentivized leverage ratio");
        require(
            block.timestamp.sub(_lastTradeTimestamp) > _coolDown
            || currentLeverageRatioAbs > _absUint256(methodology.maxLeverageRatio)
            || currentLeverageRatioAbs < _absUint256(methodology.minLeverageRatio),
            "Cooldown not elapsed or not valid leverage ratio"
        );
    }

    /**
     * Validate that current leverage is above incentivized leverage ratio and incentivized cooldown period has elapsed in ripcord()
     */
    function _validateRipcord(LeverageInfo memory _leverageInfo, uint256 _lastTradeTimestamp) internal view {
        require(_absUint256(_leverageInfo.currentLeverageRatio) >= _absUint256(incentive.incentivizedLeverageRatio), "Must be above incentivized leverage ratio");
        // If currently in the midst of a TWAP rebalance, ensure that the cooldown period has elapsed
        require(_lastTradeTimestamp.add(incentive.incentivizedTwapCooldownPeriod) < block.timestamp, "TWAP cooldown must have elapsed");
    }

    /**
     * Validate TWAP in the iterateRebalance() function
     */
    function _validateTWAP() internal view {
        require(twapLeverageRatio != 0, "Not in TWAP state");
    }

    /**
     * Validate not TWAP in the rebalance() function
     */
    function _validateNonTWAP() internal view {
        require(twapLeverageRatio == 0, "Must call iterate");
    }

    /**
     * Check if price has moved advantageously while in the midst of the TWAP rebalance. This means the current leverage ratio has moved over/under
     * the stored TWAP leverage ratio on lever/delever so there is no need to execute a rebalance. Used in iterateRebalance()
     */
    function _isAdvantageousTWAP(int256 _currentLeverageRatio) internal view returns (bool) {
        uint256 twapLeverageRatioAbs = _absUint256(twapLeverageRatio);
        uint256 targetLeverageRatioAbs = _absUint256(methodology.targetLeverageRatio);
        uint256 currentLeverageRatioAbs = _absUint256(_currentLeverageRatio);

        return (
            (twapLeverageRatioAbs < targetLeverageRatioAbs && currentLeverageRatioAbs >= twapLeverageRatioAbs)
            || (twapLeverageRatioAbs > targetLeverageRatioAbs && currentLeverageRatioAbs <= twapLeverageRatioAbs)
        );
    }

    /**
     * Calculate the current leverage ratio given a valuation of the collateral and quote asset, which is calculated as collateral USD valuation / SetToken USD valuation
     *
     * return int256            Current leverage ratio
     */
    function _calculateCurrentLeverageRatio(
        int256 _baseValue,
        int256 _quoteValue
    )
        internal
        pure
        returns(int256)
    {
        // Either collateral or debt will be negative so we can simply added those 2 values together
        return _baseValue.preciseDiv(_baseValue.add(_quoteValue));
    }

    /**
     * Convert int256 variables to absolute uint256 values
     *
     * return uint256          Absolute value in uint256
     */
    function _absUint256(int256 _int256Value) internal pure returns(uint256) {
        return _int256Value > 0 ? _int256Value.toUint256() : _int256Value.mul(-1).toUint256();
    }

    /**
     * Calculate the new leverage ratio. The methodology reduces the size of each rebalance by weighting
     * the current leverage ratio against the target leverage ratio by the recentering speed percentage. The lower the recentering speed, the slower
     * the leverage token will move towards the target leverage each rebalance.
     *
     * return int256          New leverage ratio
     */
    function _calculateNewLeverageRatio(int256 _currentLeverageRatio) internal view returns(int256) {
        // Convert int256 variables to uint256 prior to passing through methodology
        uint256 currentLeverageRatioAbs = _absUint256(_currentLeverageRatio);
        uint256 targetLeverageRatioAbs = _absUint256(methodology.targetLeverageRatio);
        uint256 maxLeverageRatioAbs = _absUint256(methodology.maxLeverageRatio);
        uint256 minLeverageRatioAbs = _absUint256(methodology.minLeverageRatio);

        // CLRt+1 = max(MINLR, min(MAXLR, CLRt * (1 - RS) + TLR * RS))
        // a: TLR * RS
        // b: (1- RS) * CLRt
        // c: (1- RS) * CLRt + TLR * RS
        // d: min(MAXLR, CLRt * (1 - RS) + TLR * RS)
        uint256 a = targetLeverageRatioAbs.preciseMul(methodology.recenteringSpeed);
        uint256 b = PreciseUnitMath.preciseUnit().sub(methodology.recenteringSpeed).preciseMul(currentLeverageRatioAbs);
        uint256 c = a.add(b);
        uint256 d = Math.min(c, maxLeverageRatioAbs);
        uint256 newLeverageRatio = Math.max(minLeverageRatioAbs, d);

        return _currentLeverageRatio > 0 ? newLeverageRatio.toInt256() : newLeverageRatio.toInt256().mul(-1);
    }

    /**
     * Calculate total notional rebalance quantity and chunked rebalance quantity in collateral units.
     *
     * return int256          Chunked rebalance notional in collateral units
     * return int256          Total rebalance notional in collateral units
     */
    function _calculateChunkRebalanceNotional(
        LeverageInfo memory _leverageInfo,
        int256 _newLeverageRatio
    )
        internal
        pure
        returns (int256, int256)
    {
        // Calculate difference between new and current leverage ratio
        int256 leverageRatioDifference = _newLeverageRatio.sub(_leverageInfo.currentLeverageRatio);

        int256 totalRebalanceNotional = leverageRatioDifference.preciseDiv(_leverageInfo.currentLeverageRatio).preciseMul(_leverageInfo.action.baseBalance);

        uint256 chunkRebalanceNotionalAbs = Math.min(_absUint256(totalRebalanceNotional), _leverageInfo.twapMaxTradeSize);

        return (
            // Return int256 chunkRebalanceNotional
            totalRebalanceNotional >= 0 ? chunkRebalanceNotionalAbs.toInt256() : chunkRebalanceNotionalAbs.toInt256().mul(-1),
            totalRebalanceNotional
        );
    }

    /**
     * Derive the quote token units for slippage tolerance. The units are calculated by the base token units multiplied by collateral asset price divided by quote asset price.
     * Output is measured to quote unit decimals.
     *
     * return int256           Position units to quote
     */
    function _calculateMinBorrowReceiveUnits(int256 _collateralRebalanceUnits, ActionInfo memory _actionInfo, uint256 _slippageTolerance) internal pure returns (int256) {
        return _collateralRebalanceUnits
            .preciseMul(_actionInfo.basePrice)
            .preciseDiv(_actionInfo.quotePrice)
            .preciseMul(PreciseUnitMath.preciseUnit().sub(_slippageTolerance).toInt256());
    }

    /**
     * Update last trade timestamp and if chunk rebalance size is less than total rebalance notional, store new leverage ratio to kick off TWAP. Used in
     * the engage() and rebalance() functions
     */
    function _updateRebalanceState(
        int256 _chunkRebalanceNotional,
        int256 _totalRebalanceNotional,
        int256 _newLeverageRatio
    )
        internal
    {
        _updateLastTradeTimestamp();

        if (_absUint256(_chunkRebalanceNotional) < _absUint256(_totalRebalanceNotional)) {
            twapLeverageRatio = _newLeverageRatio;
        }
    }

    /**
     * Update last trade timestamp and if chunk rebalance size is equal to the total rebalance notional, end TWAP by clearing state. This function is used
     * in iterateRebalance()
     */
    function _updateIterateState(int256 _chunkRebalanceNotional, int256 _totalRebalanceNotional) internal {

        _updateLastTradeTimestamp();

        // If the chunk size is equal to the total notional meaning that rebalances are not chunked, then clear TWAP state.
        if (_chunkRebalanceNotional == _totalRebalanceNotional) {
            delete twapLeverageRatio;
        }
    }

    /**
     * Update last trade timestamp and if currently in a TWAP, delete the TWAP state. Used in the ripcord() function.
     */
    function _updateRipcordState() internal {

        _updateLastTradeTimestamp();

        // If TWAP leverage ratio is stored, then clear state. This may happen if we are currently in a TWAP rebalance, and the leverage ratio moves above the
        // incentivized threshold for ripcord.
        if (twapLeverageRatio != 0) {
            delete twapLeverageRatio;
        }
    }

    /**
     * Update lastTradeTimestamp and lastTradeTimestamp values. This function updates both the exchange-specific and global timestamp so that the
     * epoch rebalance can use the global timestamp (since the global timestamp is always  equal to the most recently used exchange timestamp). This allows for
     * multiple rebalances to occur simultaneously since only the exchange-specific timestamp is checked for non-epoch rebalances.
     */
     function _updateLastTradeTimestamp() internal {
        lastTradeTimestamp = block.timestamp;
     }

    /**
     * Transfer ETH reward to caller of the ripcord function. If the ETH balance on this contract is less than required
     * incentive quantity, then transfer contract balance instead to prevent reverts.
     *
     * return uint256           Amount of ETH transferred to caller
     */
    function _transferEtherRewardToCaller(uint256 _etherReward) internal returns(uint256) {
        uint256 etherToTransfer = _etherReward < address(this).balance ? _etherReward : address(this).balance;

        msg.sender.transfer(etherToTransfer);

        return etherToTransfer;
    }

    /**
     * Internal function returning the ShouldRebalance enum used in shouldRebalance and shouldRebalanceWithBounds external getter functions
     *
     * return ShouldRebalance         Enum detailing whether to rebalance, iterateRebalance, ripcord or no action
     */
    function _shouldRebalance(
        int256 _currentLeverageRatio,
        int256 _minLeverageRatio,
        int256 _maxLeverageRatio
    )
        internal
        view
        returns(ShouldRebalance)
    {
        // If none of the below conditions are satisfied, then should not rebalance
        ShouldRebalance shouldRebalanceEnum = ShouldRebalance.NONE;

        // Get absolute value of current leverage ratio
        uint256 currentLeverageRatioAbs = _absUint256(_currentLeverageRatio);

        // If above ripcord threshold, then check if incentivized cooldown period has elapsed
        if (currentLeverageRatioAbs >= _absUint256(incentive.incentivizedLeverageRatio)) {
            if (lastTradeTimestamp.add(incentive.incentivizedTwapCooldownPeriod) < block.timestamp) {
                shouldRebalanceEnum = ShouldRebalance.RIPCORD;
            }
        } else {
            // If TWAP, then check if the cooldown period has elapsed
            if (twapLeverageRatio != 0) {
                if (lastTradeTimestamp.add(execution.twapCooldownPeriod) < block.timestamp) {
                    shouldRebalanceEnum = ShouldRebalance.ITERATE_REBALANCE;
                }
            } else {
                // If not TWAP, then check if the rebalance interval has elapsed OR current leverage is above max leverage OR current leverage is below
                // min leverage
                if (
                    block.timestamp.sub(lastTradeTimestamp) > methodology.rebalanceInterval
                    || currentLeverageRatioAbs > _absUint256(_maxLeverageRatio)
                    || currentLeverageRatioAbs < _absUint256(_minLeverageRatio)
                ) {
                    shouldRebalanceEnum = ShouldRebalance.REBALANCE;
                }
            }
        }

        return shouldRebalanceEnum;
    }
}