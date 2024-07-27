// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IAPDAOTreasury {

    /// MUTATIVE FUNCTIONS ///

    /// @notice         Function that adds WETH to backing
    /// @param amount_  Amount of WETH to add to backing
    function addToBacking(uint256 amount_) external;

    /// @notice       Function that redeems item to treasury to receive backing
    /// @param id_    Item id to redeem
    function redeemItem(uint256 id_) external;

    /// @notice           Function that allows user to receive a loan on backing of `id_`
    /// @param id_        Array of items to use as collateral
    /// @param amount_    Amount of WETH to receive for loan
    /// @param duration_  Duration loan will be active
    function receiveLoan(uint256[] calldata id_, uint256 amount_, uint256 duration_) external;

    /// @notice         Function that adjusts backing if loan expired
    /// @param loanId_  Loan id that has expired
    function backingLoanExpired(uint256 loanId_) external;

    /// @notice         Function that pays `loanId_` back
    /// @param loanId_  Loan id to pay back for
    /// @param amount_  Amount paying back
    function payLoanBack(uint256 loanId_, uint256 amount_) external;

    /// EXTERNAL VIEW FUNCTIONS ///

    /// @notice         Function that returns RFV of items in collection
    /// @return value_  RFV of item in collection
    function realFloorValue() external view returns (uint256 value_);

    /// @notice         Function that returns float of collection
    /// @return float_  Number of supply not treasury owned
    function float() external view returns (uint256 float_);

    /// OWNER FUNCTIONS ///

    /// @notice  Function sends accumulated fees to owner and bera market treasury
    function withdrawFees() external;

    /// @notice            Set max term limit for loans
    /// @param termLimit_  Max term limit on a loan
    function setTermLimit(uint256 termLimit_) external;

    /// @notice       Set if redemtions open or closed
    /// @param open_  Bool if redemtions are open or not
    function setRedemtions(bool open_) external;
}
