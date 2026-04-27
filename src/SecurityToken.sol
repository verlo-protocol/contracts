// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title SecurityToken
 * @author Verlo Platform
 * @notice This contract represents a real world asset (RWA) on Verlo.
 *         Example: a startup's equity, a fund share, or a property token.
 *
 *         Key rules:
 *         1. Only KYC-verified wallets can hold or transfer this token
 *         2. Only the Verlo admin can create new security tokens
 *         3. Every transfer is checked against the KYC registry
 *         4. Admin can pause trading if something goes wrong
 */

// ─────────────────────────────────────────────
// INTERFACE — talks to your KYCRegistry contract
// ─────────────────────────────────────────────

interface IKYCRegistry {
    function isVerified(address wallet) external view returns (bool);
}

contract SecurityToken {


    // --- Metadata ---


    /// @notice Name of this specific asset token
    /// Example: "Verlo: Acme Startup Equity Token"
    string public name;

    /// @notice Short ticker for this asset
    /// Example: "ACME"
    string public symbol;

    /// @notice Decimals — always 18 for ERC20 tokens
    uint8 public constant decimals = 18;

    /// @notice Total tokens in existence for this asset
    uint256 public totalSupply;



    // --- Balances ---


    /// @notice How many tokens each wallet holds
    mapping(address => uint256) public balanceOf;

    /// @notice Spending allowances (for DEX integrations later)
    mapping(address => mapping(address => uint256)) public allowance;



    // --- Platform state ---


    /// @notice Verlo admin wallet (you)
    address public admin;

    /// @notice Address of your KYCRegistry contract
    /// This is filled in when you deploy — paste KYCRegistry address here
    IKYCRegistry public immutable kycRegistry;

    /// @notice Whether trading is paused (emergency stop)
    bool public paused;

    /// @notice Asset details stored on chain
    string public assetDescription;
    string public assetType; // "equity" | "real_estate" | "fund" | "bond"
    uint256 public immutable issuedAt;

    /// @notice Price per token in USDC (6 decimals)
    /// Example: 1000000 = 1 USDC per token
    uint256 public pricePerToken;

    /// @notice Verlo platform fee in basis points
    /// 30 = 0.3% for normal users
    /// 20 = 0.2% for $VRL token holders
    uint256 public constant FEE_NORMAL = 30;
    uint256 public constant FEE_VRL_HOLDER = 20;

    /// @notice Wallet that collects platform fees (Verlo treasury)
    address public feeCollector;



    // --- Events ---


    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
    event TokensMinted(address indexed to, uint256 amount, uint256 timestamp);
    event TokensBurned(address indexed from, uint256 amount, uint256 timestamp);
    event TradingPaused(uint256 timestamp);
    event TradingResumed(uint256 timestamp);
    event PriceUpdated(uint256 oldPrice, uint256 newPrice);



    // --- Modifiers ---


    modifier onlyAdmin() {
        require(msg.sender == admin, "Verlo: caller is not admin");
        _;
    }

    modifier notPaused() {
        require(!paused, "Verlo: trading is paused");
        _;
    }

    modifier onlyVerified(address wallet) {
        require(
            kycRegistry.isVerified(wallet),
            "Verlo: wallet not KYC verified"
        );
        _;
    }



    // --- Constructor ---


    /**
     * @notice Called once when deploying a new asset token
     * @param _name Full name of the asset token
     * @param _symbol Short ticker for the asset
     * @param _kycRegistry Address of your deployed KYCRegistry contract
     * @param _assetDescription Description of the real world asset
     * @param _assetType Type: "equity" | "real_estate" | "fund" | "bond"
     * @param _pricePerToken Price in USDC (1 USDC = 1000000)
     * @param _feeCollector Verlo treasury wallet (can be your wallet for now)
     */
    constructor(
        string memory _name,
        string memory _symbol,
        address _kycRegistry,
        string memory _assetDescription,
        string memory _assetType,
        uint256 _pricePerToken,
        address _feeCollector
    ) {
        require(_feeCollector != address(0), "Verlo: fee collector cannot be zero address");
        admin           = msg.sender;
        name            = _name;
        symbol          = _symbol;
        kycRegistry     = IKYCRegistry(_kycRegistry);
        assetDescription = _assetDescription;
        assetType       = _assetType;
        pricePerToken   = _pricePerToken;
        feeCollector    = _feeCollector;
        issuedAt        = block.timestamp;
        paused          = false;
    }



    // --- Core transfers ---


    /**
     * @notice Transfer tokens to another wallet
     * @dev Both sender and receiver must be KYC verified
     * @param to Receiver wallet address
     * @param amount Amount of tokens to send
     */
    function transfer(address to, uint256 amount)
        external
        notPaused
        onlyVerified(msg.sender)
        onlyVerified(to)
        returns (bool)
    {
        require(to != address(0), "Verlo: transfer to zero address");
        require(balanceOf[msg.sender] >= amount, "Verlo: insufficient balance");

        balanceOf[msg.sender] -= amount;
        balanceOf[to]         += amount;

        emit Transfer(msg.sender, to, amount);
        return true;
    }

    /**
     * @notice Approve another address to spend your tokens
     * @param spender The address allowed to spend
     * @param amount How much they can spend
     */
    function approve(address spender, uint256 amount)
        external
        returns (bool)
    {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /**
     * @notice Transfer tokens on behalf of another wallet
     * @dev Used by the DvP settlement contract
     */
    function transferFrom(
        address from,
        address to,
        uint256 amount
    )
        external
        notPaused
        onlyVerified(from)
        onlyVerified(to)
        returns (bool)
    {
        require(to != address(0), "Verlo: transfer to zero address");
        require(balanceOf[from] >= amount, "Verlo: insufficient balance");
        require(allowance[from][msg.sender] >= amount, "Verlo: insufficient allowance");

        allowance[from][msg.sender] -= amount;
        balanceOf[from]             -= amount;
        balanceOf[to]               += amount;

        emit Transfer(from, to, amount);
        return true;
    }



    // --- Admin functions ---


    /**
     * @notice Create new tokens for an asset (called when someone invests)
     * @param to Investor's wallet address
     * @param amount Number of tokens to create
     */
    function mint(address to, uint256 amount)
        external
        onlyAdmin
        onlyVerified(to)
    {
        require(to != address(0), "Verlo: mint to zero address");
        require(amount > 0, "Verlo: amount must be greater than 0");

        balanceOf[to] += amount;
        totalSupply   += amount;

        emit TokensMinted(to, amount, block.timestamp);
        emit Transfer(address(0), to, amount);
    }

    /**
     * @notice Destroy tokens (called on redemption or exit)
     * @param from Wallet to burn tokens from
     * @param amount Number of tokens to destroy
     */
    function burn(address from, uint256 amount)
        external
        onlyAdmin
    {
        require(balanceOf[from] >= amount, "Verlo: insufficient balance to burn");

        balanceOf[from] -= amount;
        totalSupply     -= amount;

        emit TokensBurned(from, amount, block.timestamp);
        emit Transfer(from, address(0), amount);
    }

    /**
     * @notice Emergency stop — pause all trading
     */
    function pauseTrading() external onlyAdmin {
        paused = true;
        emit TradingPaused(block.timestamp);
    }

    /**
     * @notice Resume trading after pause
     */
    function resumeTrading() external onlyAdmin {
        paused = false;
        emit TradingResumed(block.timestamp);
    }

    /**
     * @notice Update the price per token
     * @param newPrice New price in USDC (1 USDC = 1000000)
     */
    function updatePrice(uint256 newPrice) external onlyAdmin {
        emit PriceUpdated(pricePerToken, newPrice);
        pricePerToken = newPrice;
    }

    /**
     * @notice Update the fee collector wallet
     * @param newCollector New treasury wallet
     */
    function updateFeeCollector(address newCollector) external onlyAdmin {
        require(newCollector != address(0), "Verlo: invalid address");
        feeCollector = newCollector;
    }



    // --- View functions ---


    /**
     * @notice Get full asset details in one call
     */
    function getAssetDetails() external view returns (
        string memory _name,
        string memory _symbol,
        string memory _description,
        string memory _type,
        uint256 _totalSupply,
        uint256 _pricePerToken,
        uint256 _issuedAt,
        bool _paused
    ) {
        return (
            name,
            symbol,
            assetDescription,
            assetType,
            totalSupply,
            pricePerToken,
            issuedAt,
            paused
        );
    }

    /**
     * @notice Calculate fee for a given trade amount
     * @param amount Trade amount in USDC
     * @param isVRLHolder Whether the user holds $VRL token
     * @return fee Amount in USDC to be paid as fee
     */
    function calculateFee(uint256 amount, bool isVRLHolder)
        external
        pure
        returns (uint256 fee)
    {
        uint256 bps = isVRLHolder ? FEE_VRL_HOLDER : FEE_NORMAL;
        fee = (amount * bps) / 10000;
    }
}
