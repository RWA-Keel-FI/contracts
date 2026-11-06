// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IRefPriceOracle} from "../interfaces/IRefPriceOracle.sol";
import {StockToken} from "./StockToken.sol";

/// @title StockIssuer
/// @notice TEST/MOCK primary market for tokenized stocks. NO real assets, NO custody of shares, NOT a
///         securities offering. It mints and redeems StockTokens against tUSDC at the oracle price.
/// @dev Mimics a real issuer's primary market: mint/redeem work only while the US session is open and
///      the oracle price is fresh. When the session is closed the secondary pools (Uniswap) keep
///      trading and this primary market does not, which is the situation the DeviationFee hook prices.
///
///      Units: usdc 6 decimals, tokens 18 decimals, price `priceE8` = USD per share x 1e8.
///        tokens = net_usdc * 1e20 / priceE8        (rounded down)
///        value  = tokens * priceE8 / 1e20          (rounded down)
///      A 10 bps fee is rounded UP on both sides and kept by the issuer (`feesAccrued`).
///
///      Reserves: each ticker has `reserves[feedId]` (net USDC from mints minus value paid on redeems).
///      The owner can add a shared `buffer` with `fundReserves`. Because a mock cannot hold real shares,
///      a rising price makes supply worth more than the USDC taken in; the buffer covers that gap.
contract StockIssuer is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant FEE_BPS = 10;
    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_PRICE_AGE = 900;
    /// @dev tokens (1e18) x priceE8 / PRICE_SCALE = usdc (1e6). 1e18 * 1e8 / 1e6 = 1e20.
    uint256 internal constant PRICE_SCALE = 1e20;

    IERC20 public immutable usdc;
    IRefPriceOracle public immutable oracle;

    mapping(bytes32 => StockToken) public tokenOf;
    mapping(address => bool) public tokenListed;
    mapping(bytes32 => uint256) public reserves;
    bytes32[] internal _feeds;

    /// @notice USDC the owner added with fundReserves, shared by all tickers
    uint256 public buffer;
    /// @notice USDC fees kept by the issuer (not counted as reserves)
    uint256 public feesAccrued;

    event TickerListed(bytes32 indexed feedId, address indexed token);
    event Minted(
        bytes32 indexed feedId, address indexed user, uint256 usdcIn, uint256 fee, uint256 tokensOut, uint64 priceE8
    );
    event Redeemed(
        bytes32 indexed feedId, address indexed user, uint256 tokensIn, uint256 fee, uint256 usdcOut, uint64 priceE8
    );
    event ReservesFunded(address indexed from, uint256 amount);
    event FeesWithdrawn(address indexed to, uint256 amount);

    error TickerNotListed(bytes32 feedId);
    error TickerAlreadyListed(bytes32 feedId);
    error TokenAlreadyListed(address token);
    error WrongIssuer(address token);
    error ZeroAmount();
    /// @dev session closed, no price yet, or price older than MAX_PRICE_AGE
    error PrimaryMarketClosed(bytes32 feedId, bool sessionOpen, uint64 asOf);
    error InsufficientReserves(uint256 needed, uint256 available);

    constructor(IERC20 usdc_, IRefPriceOracle oracle_, address owner_) Ownable(owner_) {
        usdc = usdc_;
        oracle = oracle_;
    }

    // ---------------------------------------------------------------- admin

    /// @notice register a ticker. The token must have been deployed with this issuer as its issuer.
    function listTicker(bytes32 feedId, StockToken token) external onlyOwner {
        if (address(tokenOf[feedId]) != address(0)) revert TickerAlreadyListed(feedId);
        if (tokenListed[address(token)]) revert TokenAlreadyListed(address(token));
        if (token.issuer() != address(this)) revert WrongIssuer(address(token));
        tokenOf[feedId] = token;
        tokenListed[address(token)] = true;
        _feeds.push(feedId);
        emit TickerListed(feedId, address(token));
    }

    /// @notice add USDC to the shared reserve buffer (anyone may fund; it cannot be withdrawn)
    function fundReserves(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        buffer += amount;
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        emit ReservesFunded(msg.sender, amount);
    }

    function withdrawFees(address to) external onlyOwner {
        uint256 amount = feesAccrued;
        feesAccrued = 0;
        usdc.safeTransfer(to, amount);
        emit FeesWithdrawn(to, amount);
    }

    // ---------------------------------------------------------------- primary market

    /// @notice pay `usdcIn` tUSDC, receive tokens at the oracle price. Needs prior USDC approval.
    function mint(bytes32 feedId, uint256 usdcIn) external nonReentrant returns (uint256 tokensOut) {
        StockToken token = _token(feedId);
        if (usdcIn == 0) revert ZeroAmount();
        uint64 price = _openPrice(feedId);

        uint256 fee = _feeUp(usdcIn);
        uint256 net = usdcIn - fee;
        tokensOut = net * PRICE_SCALE / price;
        if (tokensOut == 0) revert ZeroAmount();

        reserves[feedId] += net;
        feesAccrued += fee;

        usdc.safeTransferFrom(msg.sender, address(this), usdcIn);
        token.mint(msg.sender, tokensOut);
        emit Minted(feedId, msg.sender, usdcIn, fee, tokensOut, price);
    }

    /// @notice burn `tokensIn`, receive tUSDC at the oracle price minus the fee
    function redeem(bytes32 feedId, uint256 tokensIn) external nonReentrant returns (uint256 usdcOut) {
        StockToken token = _token(feedId);
        if (tokensIn == 0) revert ZeroAmount();
        uint64 price = _openPrice(feedId);

        uint256 value = tokensIn * price / PRICE_SCALE;
        uint256 fee = _feeUp(value);
        usdcOut = value - fee;
        if (usdcOut == 0) revert ZeroAmount();

        // pay `value` out of ticker reserves first, then the shared buffer
        uint256 fromTicker = reserves[feedId];
        if (fromTicker > value) fromTicker = value;
        uint256 fromBuffer = value - fromTicker;
        if (fromBuffer > buffer) revert InsufficientReserves(value, fromTicker + buffer);
        reserves[feedId] -= fromTicker;
        buffer -= fromBuffer;
        feesAccrued += fee;

        token.burn(msg.sender, tokensIn);
        usdc.safeTransfer(msg.sender, usdcOut);
        emit Redeemed(feedId, msg.sender, tokensIn, fee, usdcOut, price);
    }

    // ---------------------------------------------------------------- views

    /// @notice preview a mint. Returns (0, fee) as tokensOut when the amount is too small.
    function quoteMint(bytes32 feedId, uint256 usdcIn) external view returns (uint256 tokensOut, uint256 fee) {
        (uint64 price,, bool open) = _read(feedId);
        fee = _feeUp(usdcIn);
        if (!open || fee > usdcIn) return (0, fee);
        tokensOut = (usdcIn - fee) * PRICE_SCALE / price;
    }

    /// @notice preview a redeem. Returns (0, fee) when closed or too small.
    function quoteRedeem(bytes32 feedId, uint256 tokensIn) external view returns (uint256 usdcOut, uint256 fee) {
        (uint64 price,, bool open) = _read(feedId);
        if (!open) return (0, 0);
        uint256 value = tokensIn * price / PRICE_SCALE;
        fee = _feeUp(value);
        usdcOut = value - fee;
    }

    /// @notice true while mint/redeem work for this ticker (session open and price fresh)
    function primaryMarketOpen(bytes32 feedId) external view returns (bool open) {
        (,, open) = _read(feedId);
    }

    /// @return usdcReserves   ticker reserves plus the shared buffer (USDC, 6 decimals). The buffer is
    ///                        shared, so each ticker's number is optimistic when several are listed.
    /// @return supplyValueUsd totalSupply x current oracle price, in USDC units (6 decimals). 0 if no price.
    /// @return fullyBacked    usdcReserves >= supplyValueUsd
    function proofOfReserve(bytes32 feedId)
        external
        view
        returns (uint256 usdcReserves, uint256 supplyValueUsd, bool fullyBacked)
    {
        StockToken token = _token(feedId);
        (uint64 price,,) = oracle.priceOf(feedId);
        usdcReserves = reserves[feedId] + buffer;
        supplyValueUsd = token.totalSupply() * price / PRICE_SCALE;
        fullyBacked = usdcReserves >= supplyValueUsd;
    }

    /// @notice every ticker together: all reserves plus buffer against all supply value
    function isSolvent() external view returns (bool) {
        uint256 liabilities;
        uint256 assets = buffer;
        for (uint256 i; i < _feeds.length; ++i) {
            bytes32 feedId = _feeds[i];
            (uint64 price,,) = oracle.priceOf(feedId);
            liabilities += tokenOf[feedId].totalSupply() * price / PRICE_SCALE;
            assets += reserves[feedId];
        }
        return assets >= liabilities;
    }

    function feedCount() external view returns (uint256) {
        return _feeds.length;
    }

    function feedAt(uint256 i) external view returns (bytes32) {
        return _feeds[i];
    }

    // ---------------------------------------------------------------- internals

    function _token(bytes32 feedId) internal view returns (StockToken token) {
        token = tokenOf[feedId];
        if (address(token) == address(0)) revert TickerNotListed(feedId);
    }

    function _read(bytes32 feedId) internal view returns (uint64 price, uint64 asOf, bool open) {
        bool sessionOpen;
        (price, asOf, sessionOpen) = oracle.priceOf(feedId);
        open = sessionOpen && price != 0 && block.timestamp <= uint256(asOf) + MAX_PRICE_AGE;
    }

    function _openPrice(bytes32 feedId) internal view returns (uint64 price) {
        (uint64 p, uint64 asOf, bool open) = _read(feedId);
        if (!open) {
            (,, bool sessionOpen) = oracle.priceOf(feedId);
            revert PrimaryMarketClosed(feedId, sessionOpen, asOf);
        }
        price = p;
    }

    /// @dev ceil(amount x FEE_BPS / BPS): rounding favours the issuer on both mint and redeem
    function _feeUp(uint256 amount) internal pure returns (uint256) {
        return (amount * FEE_BPS + BPS - 1) / BPS;
    }
}
