// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

import {IERC20} from "@openzeppelin/contracts4/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts4/token/ERC20/ERC20.sol";
import {IERC721} from "@openzeppelin/contracts4/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts4/token/ERC721/IERC721Receiver.sol";
import {Manageable} from "./Manageable.sol";
import {BulletLoans, GRACE_PERIOD} from "./BulletLoans.sol";
import {BP, BPMath} from "./types/BP.sol";

interface IERC20WithDecimals is IERC20 {
    function decimals() external view returns (uint256);
}

contract ManagedPortfolio is IERC721Receiver, ERC20, Manageable {
    using BPMath for BP;

    enum LoanStatus {
        Active,
        Defaulted
    }

    IERC20WithDecimals public underlyingToken;
    BulletLoans public bulletLoans;
    uint256 public endDate;
    uint256 public maxSize;
    uint256 public totalDeposited;
    BP public managerFee;
    mapping(uint256 => LoanStatus) public loanStatus;

    event BulletLoanCreated(uint256 id);

    event ManagerFeeChanged(BP newManagerFee);

    event LoanStatusChanged(uint256 id, LoanStatus newStatus);

    constructor(
        IERC20WithDecimals _underlyingToken,
        BulletLoans _bulletLoans,
        uint256 _duration,
        uint256 _maxSize,
        BP _managerFee
    ) ERC20("ManagerPortfolio", "MPS") {
        underlyingToken = _underlyingToken;
        bulletLoans = _bulletLoans;
        endDate = block.timestamp + _duration;
        maxSize = _maxSize;
        managerFee = _managerFee;
    }

    function deposit(uint256 depositAmount) external {
        totalDeposited += depositAmount;
        require(totalDeposited <= maxSize, "ManagedPortfolio: Portfolio is full");
        require(block.timestamp < endDate, "ManagedPortfolio: Cannot deposit after portfolio end date");

        _mint(msg.sender, getAmountToMint(depositAmount));
        underlyingToken.transferFrom(msg.sender, address(this), depositAmount);
    }

    function setManagerFee(BP _managerFee) external onlyManager {
        managerFee = _managerFee;
        emit ManagerFeeChanged(_managerFee);
    }

    function getAmountToMint(uint256 amount) public view returns (uint256) {
        uint256 _totalSupply = totalSupply();
        if (_totalSupply == 0) {
            return (amount * 10**decimals()) / (10**underlyingToken.decimals());
        } else {
            return (amount * _totalSupply) / value();
        }
    }

    function value() public view returns (uint256) {
        return underlyingToken.balanceOf(address(this));
    }

    function withdraw(uint256 sharesAmount) external returns (uint256) {
        require(isClosed(), "ManagedPortfolio: Cannot withdraw when Portfolio is not closed");
        uint256 liquidFunds = underlyingToken.balanceOf(address(this));
        uint256 amountToWithdraw = (sharesAmount * liquidFunds) / totalSupply();
        _burn(msg.sender, sharesAmount);
        underlyingToken.transfer(msg.sender, amountToWithdraw);
        return amountToWithdraw;
    }

    function createBulletLoan(
        uint256 loanDuration,
        address borrower,
        uint256 principalAmount,
        uint256 // repaymentAmount
    ) public onlyManager {
        require(block.timestamp < endDate, "ManagedPortfolio: Portfolio end date is in the past");
        require(
            block.timestamp + loanDuration + GRACE_PERIOD <= endDate,
            "ManagedPortfolio: Loan end date is greater than Portfolio end date"
        );
        uint256 managersPart = managerFee.mul(principalAmount).normalize();
        underlyingToken.transfer(borrower, principalAmount);
        underlyingToken.transfer(manager, managersPart);
        uint256 loanId = bulletLoans.createLoan(underlyingToken);
        emit BulletLoanCreated(loanId);
    }

    function isClosed() public view returns (bool) {
        return block.timestamp > endDate;
    }

    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    function setMaxSize(uint256 _maxSize) external onlyManager {
        maxSize = _maxSize;
    }

    function markLoanAsDefaulted(uint256 id) public onlyManager {
        require(loanStatus[id] != LoanStatus.Defaulted, "ManagedPortfolio: Loan is already defaulted");
        _changeLoanStatus(id, LoanStatus.Defaulted);
    }

    function markLoanAsActive(uint256 id) public onlyManager {
        require(loanStatus[id] != LoanStatus.Active, "ManagedPortfolio: Loan is already active");
        _changeLoanStatus(id, LoanStatus.Active);
    }

    function _changeLoanStatus(uint256 id, LoanStatus status) private {
        loanStatus[id] = status;
        emit LoanStatusChanged(id, status);
    }
}
